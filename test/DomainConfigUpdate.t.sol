// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDomainHub} from "../src/interfaces/IDomain.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainTestBase} from "./helpers/DomainTestBase.sol";

/// @notice Config updates on the hub: who must sign, the checks on the new values, how an
/// update drops checkpoint votes cast before it, and the typed digest. CHAIN_ID has three
/// validators with quorum 2 and a viewing key.
contract DomainConfigUpdateTest is DomainTestBase {
    uint64 internal constant CHAIN_ID = 7777;
    uint256 internal constant K1 = 0xA11CE;
    uint256 internal constant K2 = 0xB0B;
    uint256 internal constant K3 = 0xC0DE;
    uint256 internal constant K4 = 0xD00D;
    uint256 internal constant K5 = 0xE11E;
    uint256 internal constant STRANGER_KEY = 0xBEEF;

    bytes internal constant VIEWING_KEY =
        hex"04d31f49ed035afc6c7045c4dd33b6485466fcf6021eb3e01a54a95cbc0b3e5399de67354267cc3cf62b8e933b932af6dfc19ce8e6be68d707c59873e6fb184a50";
    bytes internal constant NEW_VIEWING_KEY =
        hex"04aa1f49ed035afc6c7045c4dd33b6485466fcf6021eb3e01a54a95cbc0b3e5399de67354267cc3cf62b8e933b932af6dfc19ce8e6be68d707c59873e6fb184a50";

    DomainHub internal hub;

    function setUp() public {
        hub = new DomainHub();
        hub.registerDomain(CHAIN_ID, _addresses(_keys(K1, K2, K3)), 2, address(this), VIEWING_KEY, CHECKPOINT_INTERVAL);
        // Scheduled heights 10, 20, ... 90 are in the past from here on.
        vm.roll(100);
    }

    /// @dev Signatures over `digest` by `keys`, ordered by ascending signer address.
    function _sigs(bytes32 digest, uint256[] memory keys) internal pure returns (bytes[] memory sigs) {
        for (uint256 i = 0; i < keys.length; i++) {
            for (uint256 j = i + 1; j < keys.length; j++) {
                if (vm.addr(keys[j]) < vm.addr(keys[i])) (keys[i], keys[j]) = (keys[j], keys[i]);
            }
        }
        sigs = new bytes[](keys.length);
        for (uint256 i = 0; i < keys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }
    }

    /// @dev Updates CHAIN_ID with signatures from `currentKeys` and `newKeys`.
    function _update(
        address[] memory validators,
        uint256 quorum,
        bytes memory viewingKey,
        uint256[] memory currentKeys,
        uint256[] memory newKeys
    ) internal {
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, quorum, viewingKey);
        hub.updateDomainConfig(
            CHAIN_ID, validators, quorum, viewingKey, _sigs(digest, currentKeys), _sigs(digest, newKeys)
        );
    }

    /// @dev Expects `_update` to revert with `selector`, signed by K1 and K2 and by the new set.
    function _expectUpdateRevert(
        address[] memory validators,
        uint256 quorum,
        bytes memory viewingKey,
        uint256[] memory newKeys,
        bytes4 selector
    ) internal {
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, quorum, viewingKey);
        bytes[] memory currentSigs = _sigs(digest, _keys(K1, K2));
        bytes[] memory newSigs = _sigs(digest, newKeys);
        vm.expectRevert(selector);
        hub.updateDomainConfig(CHAIN_ID, validators, quorum, viewingKey, currentSigs, newSigs);
    }

    function _submit(uint64 blockNumber, bytes32 root, uint256 key) internal {
        hub.submitStateSignature(
            CHAIN_ID, blockNumber, root, bytes32(0), _signTransition(hub, CHAIN_ID, blockNumber, root, bytes32(0), key)
        );
    }

    // ---------------------------------------------------------------------
    // Signatures
    // ---------------------------------------------------------------------

    function test_rejectsUnregisteredDomain() public {
        address[] memory validators = _addresses(_keys(K1));
        bytes[] memory none = new bytes[](0);
        vm.expectRevert(DomainHub.DomainNotRegistered.selector);
        hub.updateDomainConfig(9999, validators, 1, VIEWING_KEY, none, none);
    }

    function test_rejectsFewerCurrentSignaturesThanQuorum() public {
        address[] memory validators = _addresses(_keys(K4, K5));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, VIEWING_KEY);
        bytes[] memory currentSigs = _sigs(digest, _keys(K1));
        bytes[] memory newSigs = _sigs(digest, _keys(K4, K5));
        vm.expectRevert(DomainHub.NotEnoughSignatures.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, VIEWING_KEY, currentSigs, newSigs);
    }

    function test_rejectsFewerNewSignaturesThanNewQuorum() public {
        _expectUpdateRevert(
            _addresses(_keys(K4, K5)), 2, VIEWING_KEY, _keys(K4), DomainHub.NotEnoughSignatures.selector
        );
    }

    function test_rejectsCurrentSignatureFromNonValidator() public {
        address[] memory validators = _addresses(_keys(K4, K5));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, VIEWING_KEY);
        bytes[] memory currentSigs = _sigs(digest, _keys(K1, STRANGER_KEY));
        bytes[] memory newSigs = _sigs(digest, _keys(K4, K5));
        vm.expectRevert(DomainHub.NotValidator.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, VIEWING_KEY, currentSigs, newSigs);
    }

    function test_rejectsNewSignaturesFromOutsideTheNewSet() public {
        // The current validators cannot sign for a new set they are not part of.
        _expectUpdateRevert(_addresses(_keys(K4, K5)), 2, VIEWING_KEY, _keys(K1, K2), DomainHub.NotValidator.selector);
    }

    function test_rejectsRepeatedSigner() public {
        address[] memory validators = _addresses(_keys(K4, K5));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, VIEWING_KEY);
        bytes[] memory one = _sigs(digest, _keys(K1));
        bytes[] memory repeated = new bytes[](2);
        repeated[0] = one[0];
        repeated[1] = one[0];
        bytes[] memory newSigs = _sigs(digest, _keys(K4, K5));
        vm.expectRevert(DomainHub.SignersNotAscending.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, VIEWING_KEY, repeated, newSigs);
    }

    function test_rejectsSignersOutOfOrder() public {
        address[] memory validators = _addresses(_keys(K4, K5));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, VIEWING_KEY);
        bytes[] memory sorted = _sigs(digest, _keys(K1, K2));
        bytes[] memory reversed = new bytes[](2);
        reversed[0] = sorted[1];
        reversed[1] = sorted[0];
        bytes[] memory newSigs = _sigs(digest, _keys(K4, K5));
        vm.expectRevert(DomainHub.SignersNotAscending.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, VIEWING_KEY, reversed, newSigs);
    }

    function test_signaturesDoNotReplayAfterUpdate() public {
        address[] memory validators = _addresses(_keys(K1, K2, K3));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, NEW_VIEWING_KEY);
        bytes[] memory sigs = _sigs(digest, _keys(K1, K2));
        hub.updateDomainConfig(CHAIN_ID, validators, 2, NEW_VIEWING_KEY, sigs, sigs);

        // The nonce moved, so the same signatures now recover to other addresses.
        vm.expectRevert(DomainHub.NotValidator.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, NEW_VIEWING_KEY, sigs, sigs);
    }

    function test_signaturesExpireWhenACheckpointLandsFirst() public {
        address[] memory validators = _addresses(_keys(K1, K2, K3));
        bytes32 digest = hub.configUpdateDigest(CHAIN_ID, validators, 2, NEW_VIEWING_KEY);
        bytes[] memory sigs = _sigs(digest, _keys(K1, K2));
        _attest(hub, CHAIN_ID, 10, keccak256("root"), bytes32(0), _keys(K1, K2));

        vm.expectRevert(DomainHub.NotValidator.selector);
        hub.updateDomainConfig(CHAIN_ID, validators, 2, NEW_VIEWING_KEY, sigs, sigs);
    }

    // ---------------------------------------------------------------------
    // New values
    // ---------------------------------------------------------------------

    function test_rejectsZeroQuorum() public {
        _expectUpdateRevert(_addresses(_keys(K4, K5)), 0, VIEWING_KEY, _keys(K4, K5), DomainHub.ZeroQuorum.selector);
    }

    function test_rejectsQuorumAboveValidatorCount() public {
        _expectUpdateRevert(
            _addresses(_keys(K4, K5)), 3, VIEWING_KEY, _keys(K4, K5), DomainHub.QuorumExceedsValidators.selector
        );
    }

    function test_rejectsZeroValidator() public {
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(K4);
        _expectUpdateRevert(validators, 1, VIEWING_KEY, _keys(K4), DomainHub.ZeroValidator.selector);
    }

    function test_rejectsDuplicateValidator() public {
        address[] memory validators = new address[](2);
        validators[0] = vm.addr(K4);
        validators[1] = vm.addr(K4);
        _expectUpdateRevert(validators, 1, VIEWING_KEY, _keys(K4), DomainHub.DuplicateValidator.selector);
    }

    function test_rejectsMalformedViewingKey() public {
        address[] memory validators = _addresses(_keys(K1, K2, K3));
        _expectUpdateRevert(validators, 2, hex"04c0ffee", _keys(K1, K2), DomainHub.InvalidViewingKey.selector);
    }

    function test_rejectsRemovingViewingKey() public {
        // Senders send plaintext when the hub publishes no key.
        address[] memory validators = _addresses(_keys(K1, K2, K3));
        _expectUpdateRevert(validators, 2, "", _keys(K1, K2), DomainHub.ViewingKeyRemoved.selector);
    }

    function test_domainWithoutViewingKeyMayKeepOrAddOne() public {
        uint64 plain = 4444;
        hub.registerDomain(plain, _addresses(_keys(K1, K2)), 2, address(this), "", CHECKPOINT_INTERVAL);
        address[] memory validators = _addresses(_keys(K1, K2));

        bytes32 digest = hub.configUpdateDigest(plain, validators, 1, "");
        bytes[] memory sigs = _sigs(digest, _keys(K1, K2));
        hub.updateDomainConfig(plain, validators, 1, "", sigs, sigs);
        assertEq(hub.viewingKeys(plain), "");

        digest = hub.configUpdateDigest(plain, validators, 1, VIEWING_KEY);
        sigs = _sigs(digest, _keys(K1));
        hub.updateDomainConfig(plain, validators, 1, VIEWING_KEY, sigs, sigs);
        assertEq(hub.viewingKeys(plain), VIEWING_KEY);
    }

    // ---------------------------------------------------------------------
    // Effect
    // ---------------------------------------------------------------------

    function test_replacesValidatorsQuorumAndViewingKey() public {
        address[] memory validators = _addresses(_keys(K3, K4, K5));
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.DomainConfigUpdated(CHAIN_ID, 0, validators, 3);
        vm.expectEmit(true, false, false, true, address(hub));
        emit IDomainHub.ViewingKeyRegistered(CHAIN_ID, NEW_VIEWING_KEY);
        _update(validators, 3, NEW_VIEWING_KEY, _keys(K1, K2), _keys(K3, K4, K5));

        assertEq(hub.getValidators(CHAIN_ID), validators);
        assertEq(hub.quorums(CHAIN_ID), 3);
        assertEq(hub.viewingKeys(CHAIN_ID), NEW_VIEWING_KEY);
        assertEq(hub.stateNonces(CHAIN_ID), 1);
        // Registration-only values are unchanged.
        assertEq(hub.feeRecipients(CHAIN_ID), address(this));
        assertEq(hub.checkpointIntervals(CHAIN_ID), CHECKPOINT_INTERVAL);
    }

    function test_onlyTheNewSetCanAttest() public {
        _update(_addresses(_keys(K3, K4)), 2, VIEWING_KEY, _keys(K1, K2), _keys(K3, K4));
        bytes32 root = keccak256("root");

        bytes memory removed = _signTransition(hub, CHAIN_ID, 10, root, bytes32(0), K1);
        vm.expectRevert(DomainHub.NotValidator.selector);
        hub.submitStateSignature(CHAIN_ID, 10, root, bytes32(0), removed);

        _submit(10, root, K3);
        _submit(10, root, K4);
        assertEq(hub.stateRoots(CHAIN_ID), root);
    }

    function test_dropsCheckpointVotesCastBeforeUpdate() public {
        bytes32 root = keccak256("root");
        _submit(10, root, K1);
        // Same set and quorum; only the key changes.
        _update(_addresses(_keys(K1, K2, K3)), 2, NEW_VIEWING_KEY, _keys(K2, K3), _keys(K2, K3));

        // K1's earlier vote does not count, so K2 alone is not a quorum.
        _submit(10, root, K2);
        assertEq(hub.stateRoots(CHAIN_ID), bytes32(0));
        // K1 signs again under the new nonce.
        _submit(10, root, K1);
        assertEq(hub.stateRoots(CHAIN_ID), root);
        assertEq(hub.stateNonces(CHAIN_ID), 2);
    }

    // ---------------------------------------------------------------------
    // Digest
    // ---------------------------------------------------------------------

    function test_digestIsEip712TypedHashBoundToHubAndChain() public view {
        address[] memory validators = _addresses(_keys(K4, K5));
        assertEq(
            hub.CONFIG_UPDATE_TYPEHASH(),
            keccak256(
                "ConfigUpdate(uint64 domainChainId,uint256 stateNonce,address[] validators,uint256 quorum,bytes viewingKey)"
            )
        );
        bytes32 separator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MonadDomainHub"),
                keccak256("1"),
                block.chainid,
                address(hub)
            )
        );
        // EIP-712 encodes an array as the hash of its elements' 32-byte encodings, and bytes as their hash.
        bytes32 structHash = keccak256(
            abi.encode(
                hub.CONFIG_UPDATE_TYPEHASH(),
                CHAIN_ID,
                hub.stateNonces(CHAIN_ID),
                keccak256(abi.encode(validators[0], validators[1])),
                uint256(2),
                keccak256(NEW_VIEWING_KEY)
            )
        );
        assertEq(
            hub.configUpdateDigest(CHAIN_ID, validators, 2, NEW_VIEWING_KEY),
            keccak256(abi.encodePacked("\x19\x01", separator, structHash))
        );
    }
}
