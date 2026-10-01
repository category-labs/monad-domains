// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {L1Bridge} from "../../src/bridge/L1Bridge.sol";
import {DomainBridge} from "../../src/bridge/DomainBridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {MerkleTreeLib} from "../../src/libraries/MerkleTreeLib.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

/// @notice Full deposit and withdrawal flows through the hub, spoke, and bridge pair.
contract DepositEndToEndTest is Test {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    DomainHub internal hub;
    DomainSpoke internal spoke;
    L1Bridge internal l1Bridge;
    DomainBridge internal domainBridge;
    TestERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        // Protocol: hub on the L1, spoke for the domain, domain registered.
        hub = new DomainHub();
        spoke = new DomainSpoke(CHAIN_ID, address(this));
        hub.registerDomain(CHAIN_ID, 0, _validatorSet(), 1);

        // Application: bridge pair wired to each other.
        l1Bridge = new L1Bridge(hub, CHAIN_ID);
        domainBridge = new DomainBridge(spoke, address(l1Bridge));
        l1Bridge.registerDomainBridge(address(domainBridge));

        token = new TestERC20();
        l1Bridge.setTokenAllowed(address(token), true);
        token.mint(alice, 1000 ether);
        vm.prank(alice);
        token.approve(address(l1Bridge), type(uint256).max);
    }

    /// @dev Delivers the recorded deposit message onto the spoke.
    function _deliverDeposit(address recipient, uint256 amount) internal {
        uint256 nonce = spoke.nextL1Nonce();
        bytes memory data = MessageLib.encodeTransfer(recipient, address(token), amount);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(address(l1Bridge), address(domainBridge), data, nonce);
        assertFalse(
            spoke.failedL1Messages(
                MessageLib.hashMessage(MessageLib.Message(address(l1Bridge), address(domainBridge), data, nonce))
            ),
            "deposit delivery failed"
        );
    }

    /// @dev Protocol step: the operator finalizes the pending domain -> L1 batch on the spoke
    /// and the sole validator (quorum 1) advances the state, recording the anchor on the hub.
    function _postDomainAnchor() internal returns (bytes32 anchor) {
        anchor = spoke.finalizeDomainMessages();
        uint64 blockNumber = hub.domainBlockNumbers(CHAIN_ID) + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(VALIDATOR_KEY, hub.stateTransitionDigest(CHAIN_ID, blockNumber, bytes32(0), anchor));
        hub.submitStateSignature(CHAIN_ID, blockNumber, bytes32(0), anchor, abi.encodePacked(r, s, v));
    }

    /// @dev Single validator (quorum 1) approving state transitions in this suite.
    function _validatorSet() internal view returns (address[] memory vs) {
        vs = new address[](1);
        vs[0] = vm.addr(VALIDATOR_KEY);
    }

    function test_singleDeposit() public {
        // 1. Alice locks 100 tokens on the L1 for bob on the domain.
        vm.prank(alice);
        l1Bridge.bridgeToDomain(bob, address(token), 100 ether);
        assertEq(token.balanceOf(address(l1Bridge)), 100 ether);
        assertEq(hub.l1MessageCounts(CHAIN_ID), 1);

        // 2. Delivery mints the bridged token to bob.
        _deliverDeposit(bob, 100 ether);

        assertEq(domainBridge.bridgedTokens(address(token)).balanceOf(bob), 100 ether);
    }

    function test_multipleDepositsInOneBlock() public {
        vm.startPrank(alice);
        l1Bridge.bridgeToDomain(bob, address(token), 100 ether);
        l1Bridge.bridgeToDomain(carol, address(token), 25 ether);
        l1Bridge.bridgeToDomain(bob, address(token), 5 ether);
        vm.stopPrank();

        _deliverDeposit(bob, 100 ether);
        _deliverDeposit(carol, 25 ether);
        _deliverDeposit(bob, 5 ether);

        BridgedERC20 bridged = domainBridge.bridgedTokens(address(token));
        assertEq(bridged.balanceOf(bob), 105 ether);
        assertEq(bridged.balanceOf(carol), 25 ether);
        assertEq(bridged.totalSupply(), 130 ether);
        assertEq(token.balanceOf(address(l1Bridge)), 130 ether);
        assertEq(spoke.nextL1Nonce(), 3);
    }

    // ---------------------------------------------------------------------
    // Domain -> L1 (withdrawals)
    // ---------------------------------------------------------------------

    /// @dev Deposits `amount` for `recipient` on the L1 and delivers it.
    function _finalizedDeposit(address recipient, uint256 amount) internal {
        vm.prank(alice);
        l1Bridge.bridgeToDomain(recipient, address(token), amount);
        _deliverDeposit(recipient, amount);
    }

    function test_roundTrip() public {
        // 1. Deposit: alice locks 100 on the L1, minted to bob.
        _finalizedDeposit(bob, 100 ether);

        // 2. Withdrawal: bob burns 40, sending them to carol on the L1.
        vm.prank(bob);
        domainBridge.bridgeToL1(carol, address(token), 40 ether);

        // 3. Protocol posts the domain state root update: anchor recorded on the L1.
        bytes32[] memory leaves = spoke.getPendingDomainMessages();
        bytes32 anchor = _postDomainAnchor();

        // 4. Anyone finalizes the withdrawal on the L1 with preimage + proof.
        MessageLib.Message memory message = MessageLib.Message({
            from: address(domainBridge),
            to: address(l1Bridge),
            data: MessageLib.encodeTransfer(carol, address(token), 40 ether),
            nonce: 0
        });
        assertTrue(hub.relayDomainMessage(CHAIN_ID, message, anchor, MerkleTreeLib.getProof(leaves, 0)));

        // Collateral and supply stay matched: 60 locked backing 60 bridged.
        assertEq(token.balanceOf(carol), 40 ether);
        assertEq(token.balanceOf(address(l1Bridge)), 60 ether);
        assertEq(domainBridge.bridgedTokens(address(token)).balanceOf(bob), 60 ether);
        assertEq(domainBridge.bridgedTokens(address(token)).totalSupply(), 60 ether);
    }

    function test_multipleWithdrawalsInOneAnchor() public {
        _finalizedDeposit(bob, 100 ether);

        // Three withdrawals land in the same state root update (odd leaf count).
        vm.startPrank(bob);
        domainBridge.bridgeToL1(bob, address(token), 10 ether);
        domainBridge.bridgeToL1(carol, address(token), 20 ether);
        domainBridge.bridgeToL1(bob, address(token), 30 ether);
        vm.stopPrank();

        bytes32[] memory leaves = spoke.getPendingDomainMessages();
        bytes32 anchor = _postDomainAnchor();

        address[3] memory recipients = [bob, carol, bob];
        uint256[3] memory amounts = [uint256(10 ether), 20 ether, 30 ether];
        for (uint256 i = 0; i < 3; i++) {
            MessageLib.Message memory message = MessageLib.Message({
                from: address(domainBridge),
                to: address(l1Bridge),
                data: MessageLib.encodeTransfer(recipients[i], address(token), amounts[i]),
                nonce: i
            });
            assertTrue(hub.relayDomainMessage(CHAIN_ID, message, anchor, MerkleTreeLib.getProof(leaves, i)));
        }

        assertEq(token.balanceOf(bob), 40 ether);
        assertEq(token.balanceOf(carol), 20 ether);
        assertEq(token.balanceOf(address(l1Bridge)), 40 ether);
        assertEq(domainBridge.bridgedTokens(address(token)).totalSupply(), 40 ether);
    }
}
