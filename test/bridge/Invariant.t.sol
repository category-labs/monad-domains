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
import {DomainTestBase} from "../helpers/DomainTestBase.sol";

/// @notice Performs random deposits, withdrawals, and finalizations across a set of
/// actors, keeping ghost accounting of value in flight between the two chains. Deposits
/// are delivered strictly in nonce order; withdrawals are anchored as they are sent
/// (single-leaf anchor, empty proof) and finalized in random order. Multi-leaf proof
/// verification is covered by the unit and end-to-end suites; this suite targets the
/// accounting.
///
/// The handler deploys and owns the whole stack and holds the sole validator key, so it
/// can attest each domain -> L1 batch on the checkpoint schedule as soon as it is sent.
contract BridgeHandler is DomainTestBase {
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

    struct Withdrawal {
        MessageLib.DomainMessage message;
        bytes32 messageHash;
        uint256 amount;
        bool finalized;
    }
    Withdrawal[] internal _withdrawals;

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
        // Protocol + application stack, all deployed by this handler, which holds the
        // single validator key (quorum 1) and is the fee recipient.
        HUB = new DomainHub();
        _registerDomain(HUB, CHAIN_ID, VALIDATOR_KEY);
        SPOKE = new DomainSpoke(CHAIN_ID, block.chainid, address(HUB));

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
        vm.deal(actor, DELIVERY_FEE);
        vm.startPrank(actor);
        TOKEN.approve(address(L1_BRIDGE), amount);
        L1_BRIDGE.bridgeToDomain{value: DELIVERY_FEE}(recipient, address(TOKEN), amount);
        vm.stopPrank();

        // Reconstruct the recorded message (the handler mirrors the hub's per-domain
        // nonce counter; the require cross-checks that mirror against the hub).
        MessageLib.Message memory message = MessageLib.Message({
            sourceChainId: uint64(block.chainid),
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
        SPOKE.relayL1Message(
            uint64(block.chainid),
            transfer.message.from,
            transfer.message.to,
            transfer.message.data,
            transfer.message.nonce
        );
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
        // counter) and attest its single-message batch as the validator at the next
        // checkpoint. The require cross-checks the reconstruction against the anchor.
        MessageLib.DomainMessage memory message = MessageLib.DomainMessage({
            sourceChainId: CHAIN_ID,
            destinationChainId: uint64(block.chainid),
            from: address(DOMAIN_BRIDGE),
            to: address(L1_BRIDGE),
            data: MessageLib.encodeTransfer(recipient, address(TOKEN), amount),
            sourceNonce: _domainNonce++
        });
        bytes32 anchor = _attestBatch(HUB, SPOKE, VALIDATOR_KEY);
        require(
            anchor == MessageLib.hashDomainMessage(message, block.chainid, address(HUB)),
            "handler: message reconstruction desync"
        );

        _withdrawals.push(Withdrawal({message: message, messageHash: anchor, amount: amount, finalized: false}));
        ghost_inFlightWithdrawals += amount;
    }

    function finalizeWithdrawal(uint256 seed) external {
        uint256 index = _pickUnfinalized(_withdrawals, seed);
        if (index == type(uint256).max) return;
        Withdrawal storage transfer = _withdrawals[index];
        transfer.finalized = true;
        ghost_inFlightWithdrawals -= transfer.amount;
        require(
            HUB.relayDomainMessage(transfer.message, transfer.messageHash, new bytes32[](0)),
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

    function _pickActor(uint256 seed) internal view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _pickUnfinalized(Withdrawal[] storage list, uint256 seed) internal view returns (uint256) {
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
