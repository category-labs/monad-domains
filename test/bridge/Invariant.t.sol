// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BridgedERC20} from "../../src/bridge/BridgedERC20.sol";
import {L1Bridge} from "../../src/bridge/L1Bridge.sol";
import {DomainBridge} from "../../src/bridge/DomainBridge.sol";
import {MessageLib} from "../../src/libraries/MessageLib.sol";
import {DomainHub} from "../../src/DomainHub.sol";
import {DomainSpoke} from "../../src/DomainSpoke.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

/// @notice Performs random deposits, withdrawals, and finalizations across a set of
/// actors, keeping ghost accounting of value in flight between the two chains. Deposits
/// are delivered strictly in nonce order; withdrawals are anchored as they are sent
/// (single-leaf anchor, empty proof) and finalized in random order. Multi-leaf proof
/// verification is covered by the unit and end-to-end suites; this suite targets the
/// accounting.
///
/// The handler deploys and owns the whole stack so that it is the domain operator,
/// and can therefore finalize domain -> L1 batches.
contract BridgeHandler is Test {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant VALIDATOR_KEY = 0xA11CE;

    L1Bridge internal immutable L1_BRIDGE;
    DomainBridge internal immutable DOMAIN_BRIDGE;
    DomainHub internal immutable HUB;
    DomainSpoke internal immutable SPOKE;
    TestERC20 internal immutable TOKEN;

    struct Transfer {
        MessageLib.Message message;
        bytes32 messageHash;
        uint256 amount;
        bool finalized;
    }

    Transfer[] internal _deposits;
    Transfer[] internal _withdrawals;

    /// @notice Locked on the L1 but not yet minted on the domain.
    uint256 public ghost_inFlightDeposits;
    /// @notice Burned on the domain but not yet released on the L1.
    uint256 public ghost_inFlightWithdrawals;

    uint256 internal _l1Nonce;
    uint256 internal _domainNonce;

    /// @notice Index of the next deposit to deliver (strictly in nonce order).
    uint256 internal _nextDepositToDeliver;

    address[] internal _actors;

    constructor() {
        // Protocol + application stack, all deployed by (and operated by) this handler.
        HUB = new DomainHub();
        address[] memory validators = new address[](1);
        validators[0] = vm.addr(VALIDATOR_KEY);
        HUB.registerDomain(CHAIN_ID, 0, validators, 1); // handler is operator; one validator
        SPOKE = new DomainSpoke(CHAIN_ID, address(this)); // handler is the spoke operator

        L1_BRIDGE = new L1Bridge(HUB, CHAIN_ID);
        DOMAIN_BRIDGE = new DomainBridge(SPOKE, address(L1_BRIDGE));
        L1_BRIDGE.registerDomainBridge(address(DOMAIN_BRIDGE));

        TOKEN = new TestERC20();
        L1_BRIDGE.setTokenAllowed(address(TOKEN), true);

        for (uint256 i = 0; i < 3; i++) {
            _actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function deposit(uint256 actorSeed, uint256 recipientSeed, uint256 amount) external {
        address actor = _pickActor(actorSeed);
        address recipient = _pickActor(recipientSeed);
        amount = bound(amount, 1, 1e24);

        TOKEN.mint(actor, amount);
        vm.startPrank(actor);
        TOKEN.approve(address(L1_BRIDGE), amount);
        L1_BRIDGE.bridgeToDomain(recipient, address(TOKEN), amount);
        vm.stopPrank();

        // Reconstruct the recorded message (the handler mirrors the hub's per-domain
        // nonce counter; the require cross-checks that mirror against the hub).
        MessageLib.Message memory message = MessageLib.Message({
            from: address(L1_BRIDGE),
            to: address(DOMAIN_BRIDGE),
            data: MessageLib.encodeTransfer(recipient, address(TOKEN), amount),
            nonce: _l1Nonce++
        });
        require(_l1Nonce == HUB.l1MessageCounts(CHAIN_ID), "handler: nonce desync");

        _deposits.push(
            Transfer({message: message, messageHash: MessageLib.hashMessage(message), amount: amount, finalized: false})
        );
        ghost_inFlightDeposits += amount;
    }

    /// @notice Delivers the oldest undelivered deposit. Unlike withdrawals, delivery order
    /// is not a choice - the spoke enforces the hub's nonce sequence.
    function deliverDeposit(uint256) external {
        if (_nextDepositToDeliver >= _deposits.length) return;
        Transfer storage transfer = _deposits[_nextDepositToDeliver++];
        transfer.finalized = true;
        ghost_inFlightDeposits -= transfer.amount;

        vm.prank(SPOKE.SYSTEM_RELAYER());
        SPOKE.relayL1Message(transfer.message.from, transfer.message.to, transfer.message.data, transfer.message.nonce);
        require(!SPOKE.failedL1Messages(transfer.messageHash), "handler: deposit delivery failed");
    }

    function withdraw(uint256 actorSeed, uint256 recipientSeed, uint256 amount) external {
        BridgedERC20 bridged = DOMAIN_BRIDGE.bridgedTokens(address(TOKEN));
        if (address(bridged) == address(0)) return;
        address actor = _pickActor(actorSeed);
        uint256 balance = bridged.balanceOf(actor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        address recipient = _pickActor(recipientSeed);

        vm.prank(actor);
        DOMAIN_BRIDGE.bridgeToL1(recipient, address(TOKEN), amount);

        // Reconstruct the just-recorded message (the handler mirrors the spoke's nonce
        // counter), finalize its single-message batch, and advance the state as the
        // validator. The require cross-checks the reconstruction against the anchor.
        MessageLib.Message memory message = MessageLib.Message({
            from: address(DOMAIN_BRIDGE),
            to: address(L1_BRIDGE),
            data: MessageLib.encodeTransfer(recipient, address(TOKEN), amount),
            nonce: _domainNonce++
        });
        bytes32 anchor = SPOKE.finalizeDomainMessages();
        _advanceState(anchor);
        require(anchor == MessageLib.hashMessage(message), "handler: message reconstruction desync");

        _withdrawals.push(Transfer({message: message, messageHash: anchor, amount: amount, finalized: false}));
        ghost_inFlightWithdrawals += amount;
    }

    function finalizeWithdrawal(uint256 seed) external {
        uint256 index = _pickUnfinalized(_withdrawals, seed);
        if (index == type(uint256).max) return;
        Transfer storage transfer = _withdrawals[index];
        transfer.finalized = true;
        ghost_inFlightWithdrawals -= transfer.amount;
        require(
            HUB.relayDomainMessage(CHAIN_ID, transfer.message, transfer.messageHash, new bytes32[](0)),
            "handler: withdrawal delivery failed"
        );
    }

    function bridgedSupply() public view returns (uint256) {
        BridgedERC20 bridged = DOMAIN_BRIDGE.bridgedTokens(address(TOKEN));
        return address(bridged) == address(0) ? 0 : bridged.totalSupply();
    }

    function lockedCollateral() public view returns (uint256) {
        return TOKEN.balanceOf(address(L1_BRIDGE));
    }

    /// @dev The sole validator (quorum 1) signs the (dummy-root, anchor) transition and votes,
    /// advancing it in one call. Block numbers must strictly increase, so derive the next one
    /// from the committed block number.
    function _advanceState(bytes32 anchor) internal {
        uint64 blockNumber = HUB.domainBlockNumbers(CHAIN_ID) + 1;
        bytes32 digest = HUB.stateTransitionDigest(CHAIN_ID, blockNumber, bytes32(0), anchor);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(VALIDATOR_KEY, digest);
        HUB.submitStateSignature(CHAIN_ID, blockNumber, bytes32(0), anchor, abi.encodePacked(r, s, v));
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _pickUnfinalized(Transfer[] storage list, uint256 seed) internal view returns (uint256) {
        uint256 n = list.length;
        if (n == 0) return type(uint256).max;
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            uint256 index = (start + i) % n;
            if (!list[index].finalized) return index;
        }
        return type(uint256).max;
    }
}

contract BridgeInvariantTest is Test {
    BridgeHandler internal handler;

    function setUp() public {
        handler = new BridgeHandler();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BridgeHandler.deposit.selector;
        selectors[1] = BridgeHandler.deliverDeposit.selector;
        selectors[2] = BridgeHandler.withdraw.selector;
        selectors[3] = BridgeHandler.finalizeWithdrawal.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Solvency: the collateral locked in the L1Bridge always EXACTLY equals
    /// the bridged token supply plus value in flight between the chains (deposits not
    /// yet minted + withdrawals not yet released). Equality is stronger than `>=`:
    /// it also catches value getting stuck or double-counted, not just theft.
    function invariant_solvency() public view {
        assertEq(
            handler.lockedCollateral(),
            handler.bridgedSupply() + handler.ghost_inFlightDeposits() + handler.ghost_inFlightWithdrawals(),
            "locked collateral must equal bridged supply + in-flight value"
        );
    }
}
