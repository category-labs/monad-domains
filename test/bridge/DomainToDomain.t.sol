// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {L1Bridge} from "../../src/bridge/L1Bridge.sol";
import {DomainBridge} from "../../src/bridge/DomainBridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

/// @notice Atomically completes a domain A -> L1 withdrawal and re-bridges the released
/// tokens into domain B, collapsing the L1 leg into a single transaction. The withdrawal
/// from domain A must name this router as its recipient so the released tokens land here.
contract CrossDomainRouter {
    using SafeERC20 for IERC20;

    function relay(
        L1Bridge fromBridge,
        L1Bridge toBridge,
        MessageLib.DomainMessage calldata message,
        bytes32 anchor,
        bytes32[] calldata proof,
        address recipientOnB
    ) external {
        require(message.to == address(fromBridge), "Router: wrong source bridge");
        // A successful hub relay can mean queued on another domain. This operation
        // requires an actual L1 withdrawal before spending any router-held collateral.
        require(message.destinationChainId == block.chainid, "Router: withdrawal must target L1");
        require(message.sourceChainId == fromBridge.DOMAIN_CHAIN_ID(), "Router: wrong source domain");
        require(fromBridge.HUB().relayDomainMessage(message, anchor, proof), "Router: withdrawal delivery failed");
        (, address token, uint256 amount) = MessageLib.decodeTransfer(message.data);
        IERC20(token).forceApprove(address(toBridge), amount);
        toBridge.bridgeToDomain(recipientOnB, token, amount);
    }
}

/// @notice Tokens are native to the L1 and only ever locked there; each domain mints its
/// own bridged representation. So "domain A -> domain B" is not a direct hop: the value
/// must travel A -> L1 (burn on A, unlock on L1) and then L1 -> B (lock on L1, mint on B).
///
/// The L1 leg can be split two ways, both covered here:
///   - two L1 transactions: the user withdraws to their own L1 address, then deposits into B;
///   - one L1 transaction: a router finalizes the withdrawal and re-deposits in the same call.
///
/// A single L1 hub serves both domains; each domain has its own spoke, L1Bridge
/// (isolated collateral), and DomainBridge. One validator (quorum 1) serves both domains
/// and attests the domain -> L1 batches on the checkpoint schedule.
contract DomainToDomainTest is DomainTestBase {
    uint64 internal constant CHAIN_A = 7777;
    uint64 internal constant CHAIN_B = 8888;
    uint256 internal constant AMOUNT = 100 ether;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    DomainHub internal hub;
    DomainSpoke internal spokeA;
    DomainSpoke internal spokeB;
    L1Bridge internal l1BridgeA;
    L1Bridge internal l1BridgeB;
    DomainBridge internal domainBridgeA;
    DomainBridge internal domainBridgeB;
    TestERC20 internal token;
    CrossDomainRouter internal router;

    address internal alice = makeAddr("alice");
    address internal bobOnB = makeAddr("bobOnB");

    /// @dev Mirrors domain A's spoke nonce counter so reconstructed withdrawal messages
    /// match recorded ones.
    uint256 internal _domainANonce;

    function setUp() public {
        // Protocol: one L1 hub, one spoke per domain, both registered with the same validator.
        hub = new DomainHub();
        _registerDomain(hub, CHAIN_A, VALIDATOR_KEY);
        _registerDomain(hub, CHAIN_B, VALIDATOR_KEY);
        spokeA = new DomainSpoke(CHAIN_A, block.chainid, address(hub));
        spokeB = new DomainSpoke(CHAIN_B, block.chainid, address(hub));

        // Application: an independent bridge pair per domain, sharing the L1 token.
        l1BridgeA = new L1Bridge(hub, CHAIN_A);
        l1BridgeB = new L1Bridge(hub, CHAIN_B);
        domainBridgeA = new DomainBridge(spokeA, address(l1BridgeA));
        domainBridgeB = new DomainBridge(spokeB, address(l1BridgeB));
        l1BridgeA.registerDomainBridge(address(domainBridgeA));
        l1BridgeB.registerDomainBridge(address(domainBridgeB));

        token = new TestERC20();
        l1BridgeA.setTokenAllowed(address(token), true);
        l1BridgeB.setTokenAllowed(address(token), true);

        router = new CrossDomainRouter();

        // Give alice a domain-A balance to bridge: deposit AMOUNT L1 -> domain A.
        // This locks AMOUNT in l1BridgeA, the collateral that later travels to B.
        token.mint(alice, AMOUNT);
        _depositToDomainA(alice, alice, AMOUNT);
        assertEq(domainBridgeA.bridgedTokens(address(token)).balanceOf(alice), AMOUNT);
    }

    /// @notice Two L1 transactions: alice withdraws domain-A tokens to her own L1 address,
    /// then separately deposits them into domain B.
    function test_domainAToB_twoL1Transactions() public {
        // Domain A -> L1: burn on A, validator anchors, recipient is alice herself.
        (MessageLib.DomainMessage memory wMsg, bytes32 wAnchor) = _initiateWithdrawFromA(alice, alice, AMOUNT);

        // L1 tx 1: finalize the withdrawal - alice receives the real L1 token.
        assertTrue(hub.relayDomainMessage(wMsg, wAnchor, _emptyProof()));
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.balanceOf(address(l1BridgeA)), 0);

        // L1 tx 2: alice deposits the same token into domain B's bridge.
        _depositToDomainB(alice, bobOnB, AMOUNT);

        _assertLandedOnB(bobOnB, AMOUNT);
    }

    /// @notice One L1 transaction: the withdrawal names the router as recipient, and the
    /// router finalizes it and re-deposits into domain B atomically.
    function test_domainAToB_singleL1Transaction() public {
        // Domain A -> L1: recipient is the router, so the unlocked tokens land there.
        (MessageLib.DomainMessage memory wMsg, bytes32 wAnchor) = _initiateWithdrawFromA(alice, address(router), AMOUNT);

        // Single L1 tx: finalize withdrawal on A and re-deposit into B in one call.
        router.relay(l1BridgeA, l1BridgeB, wMsg, wAnchor, _emptyProof(), bobOnB);
        assertEq(token.balanceOf(address(l1BridgeA)), 0);
        assertEq(token.balanceOf(address(router)), 0); // router forwarded everything

        // Deliver the deposit the router initiated onto domain B.
        _deliverDeposit(spokeB, l1BridgeB, domainBridgeB, bobOnB, AMOUNT);

        _assertLandedOnB(bobOnB, AMOUNT);
    }

    function test_router_rollsBackHubConsumptionIfDepositFails() public {
        (MessageLib.DomainMessage memory message, bytes32 anchor) =
            _initiateWithdrawFromA(alice, address(router), AMOUNT);
        l1BridgeB.setTokenAllowed(address(token), false);
        vm.expectRevert("L1Bridge: token not allowed");
        router.relay(l1BridgeA, l1BridgeB, message, anchor, _emptyProof(), bobOnB);
        assertFalse(hub.relayedDomainMessages(CHAIN_A, _hash(message)));
        assertEq(token.balanceOf(address(l1BridgeA)), AMOUNT);
        assertEq(token.balanceOf(address(router)), 0);
        l1BridgeB.setTokenAllowed(address(token), true);
        router.relay(l1BridgeA, l1BridgeB, message, anchor, _emptyProof(), bobOnB);
        _deliverDeposit(spokeB, l1BridgeB, domainBridgeB, bobOnB, AMOUNT);
        _assertLandedOnB(bobOnB, AMOUNT);
    }

    function test_router_revertsIfHubDeliveryFails() public {
        (MessageLib.DomainMessage memory message,) = _initiateWithdrawFromA(alice, address(router), AMOUNT);
        message.from = address(0xBAD);
        // A forged single-leaf anchor, attested at the next checkpoint as if it were genuine.
        bytes32 anchor = _hash(message);
        _attestNext(hub, CHAIN_A, bytes32(0), anchor, _keys(VALIDATOR_KEY));
        // Even prefunded tokens must not be used after a failed withdrawal callback.
        token.mint(address(router), AMOUNT);
        vm.expectRevert("Router: withdrawal delivery failed");
        router.relay(l1BridgeA, l1BridgeB, message, anchor, _emptyProof(), bobOnB);
        assertFalse(hub.relayedDomainMessages(CHAIN_A, anchor));
        assertFalse(hub.failedDomainMessages(CHAIN_A, anchor));
        assertEq(token.balanceOf(address(router)), AMOUNT);
        assertEq(token.balanceOf(address(l1BridgeB)), 0);
    }

    function test_router_rejectsForwardingInsteadOfL1Withdrawal() public {
        (MessageLib.DomainMessage memory message, bytes32 anchor) =
            _initiateWithdrawFromA(alice, address(router), AMOUNT);
        token.mint(address(router), AMOUNT);
        message.destinationChainId = CHAIN_B;
        vm.expectRevert("Router: withdrawal must target L1");
        router.relay(l1BridgeA, l1BridgeB, message, anchor, _emptyProof(), bobOnB);
        assertEq(token.balanceOf(address(router)), AMOUNT);
        assertEq(token.balanceOf(address(l1BridgeA)), AMOUNT);
        assertEq(token.balanceOf(address(l1BridgeB)), 0);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Locks `amount` on l1BridgeA for `depositor` and delivers the mint to `recipient`.
    function _depositToDomainA(address depositor, address recipient, uint256 amount) internal {
        vm.startPrank(depositor);
        token.approve(address(l1BridgeA), amount);
        l1BridgeA.bridgeToDomain(recipient, address(token), amount);
        vm.stopPrank();

        _deliverDeposit(spokeA, l1BridgeA, domainBridgeA, recipient, amount);
    }

    /// @dev Locks `amount` on l1BridgeB for `depositor` and delivers the mint to `recipient`.
    function _depositToDomainB(address depositor, address recipient, uint256 amount) internal {
        vm.startPrank(depositor);
        token.approve(address(l1BridgeB), amount);
        l1BridgeB.bridgeToDomain(recipient, address(token), amount);
        vm.stopPrank();

        _deliverDeposit(spokeB, l1BridgeB, domainBridgeB, recipient, amount);
    }

    /// @dev Delivers the deposit just recorded on the hub onto the spoke.
    function _deliverDeposit(
        DomainSpoke spoke,
        L1Bridge fromBridge,
        DomainBridge toBridge,
        address recipient,
        uint256 amount
    ) internal {
        uint256 nonce = spoke.nextL1Nonce();
        bytes memory data = MessageLib.encodeTransfer(recipient, address(token), amount);
        vm.prank(spoke.SYSTEM_RELAYER());
        spoke.relayL1Message(uint64(block.chainid), address(fromBridge), address(toBridge), data, nonce);
        assertFalse(
            spoke.failedL1Messages(
                MessageLib.hashMessage(
                    MessageLib.Message(uint64(block.chainid), address(fromBridge), address(toBridge), data, nonce)
                )
            ),
            "deposit delivery failed"
        );
    }

    /// @dev Burns `amount` of the bridged token on domain A and has the validator attest the
    /// resulting batch (with the new state root) onto the hub. Returns the withdrawal message
    /// + anchor the L1 leg finalizes against.
    function _initiateWithdrawFromA(address sender, address recipient, uint256 amount)
        internal
        returns (MessageLib.DomainMessage memory message, bytes32 anchor)
    {
        vm.prank(sender);
        domainBridgeA.bridgeToL1(recipient, address(token), amount);

        uint256 nonce = _domainANonce++;
        anchor = _attestBatch(hub, spokeA, VALIDATOR_KEY);
        message = MessageLib.DomainMessage({
            sourceChainId: CHAIN_A,
            destinationChainId: uint64(block.chainid),
            from: address(domainBridgeA),
            to: address(l1BridgeA),
            data: MessageLib.encodeTransfer(recipient, address(token), amount),
            sourceNonce: nonce
        });
    }

    /// @dev The value ended up as bridged supply on B, collateral moved from A to B, and
    /// nothing is left stranded on A or in transit.
    function _assertLandedOnB(address recipient, uint256 amount) internal view {
        BridgedERC20 bridgedB = domainBridgeB.bridgedTokens(address(token));
        assertEq(bridgedB.balanceOf(recipient), amount, "recipient minted on B");
        assertEq(bridgedB.totalSupply(), amount, "B supply");
        assertEq(token.balanceOf(address(l1BridgeB)), amount, "collateral locked on B");
        assertEq(token.balanceOf(address(l1BridgeA)), 0, "collateral released from A");
        assertEq(domainBridgeA.bridgedTokens(address(token)).totalSupply(), 0, "A supply burned");
        assertEq(token.balanceOf(alice), 0, "no L1 token stranded with alice");
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _hash(MessageLib.DomainMessage memory message) internal view returns (bytes32) {
        return MessageLib.hashDomainMessage(message, block.chainid, address(hub));
    }
}
