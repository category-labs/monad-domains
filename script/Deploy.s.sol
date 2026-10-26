// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IDomainHub, IDomainSpoke} from "../src/interfaces/IDomain.sol";
import {L1Bridge} from "../src/bridge/L1Bridge.sol";
import {DomainBridge} from "../src/bridge/DomainBridge.sol";
import {DomainHub} from "../src/DomainHub.sol";
import {DomainSpoke} from "../src/DomainSpoke.sol";

/// Production deployment spans two chains; the hub and spoke must be deployed too (the spoke
/// is intended to become a protocol predeploy — until then, deploy it like any contract).
/// L1 -> domain messages are delivered by the domain protocol as system transactions
/// derived from the hub's events, so the client must be scanning this hub deployment for
/// deposits to arrive. The full sequence (the pieces reference each other, so order matters):
///
///   1. On the L1:        DOMAIN_CHAIN_ID=<id> QUORUM=<n> VALIDATORS=<addr,addr,...> \
///                        [FEE_RECIPIENT=<addr>] [VIEWING_KEY=0x04...] [CHECKPOINT_INTERVAL=<blocks>] \
///        forge script script/Deploy.s.sol:DeployHub --rpc-url $L1_RPC --broadcast
///      Registers the validator set + quorum that must sign to advance the domain state, the
///      fee recipient (default: the broadcaster), the viewing public key senders encrypt to
///      (optional) and the checkpoint interval (default 5). Outputs the hub address.
///   2. On the domain: DOMAIN_CHAIN_ID=<id> L1_CHAIN_ID=<L1 id> HUB_ADDRESS=<step 1> \
///        forge script script/Deploy.s.sol:DeploySpoke --rpc-url $DOMAIN_RPC --broadcast
///   3. On the L1:        DOMAIN_CHAIN_ID=<id> HUB_ADDRESS=<step 1> \
///        forge script script/Deploy.s.sol:DeployL1Bridge --rpc-url $L1_RPC --broadcast
///   4. On the domain: SPOKE_ADDRESS=<step 2> L1_BRIDGE_ADDRESS=<step 3> \
///        forge script script/Deploy.s.sol:DeployDomainBridge --rpc-url $DOMAIN_RPC --broadcast
///   5. On the L1:        L1_BRIDGE_ADDRESS=<step 3> DOMAIN_BRIDGE_ADDRESS=<step 4> \
///        forge script script/Deploy.s.sol:RegisterCounterpart --rpc-url $L1_RPC --broadcast
///
/// Step 5 is one-shot and permanent. Before running it, independently verify that the
/// DomainBridge at DOMAIN_BRIDGE_ADDRESS has `L1_BRIDGE()` equal to your L1Bridge (it is
/// on the other chain, so this script cannot check it for you). If the pair is ever miswired,
/// deploy a fresh pair.
contract DeployHub is Script {
    function run() external returns (DomainHub hub) {
        uint64 domainChainId = uint64(vm.envUint("DOMAIN_CHAIN_ID"));
        require(domainChainId != 0, "Deploy: DOMAIN_CHAIN_ID not set");
        require(domainChainId != block.chainid, "Deploy: domain chain id equals current chain");
        address[] memory validators = vm.envAddress("VALIDATORS", ",");
        uint256 quorum = vm.envUint("QUORUM");
        address feeRecipient = vm.envOr("FEE_RECIPIENT", msg.sender);
        bytes memory viewingKey = vm.envOr("VIEWING_KEY", bytes(""));
        uint64 checkpointInterval = uint64(vm.envOr("CHECKPOINT_INTERVAL", uint256(5)));

        vm.startBroadcast();
        hub = new DomainHub();
        hub.registerDomain(domainChainId, validators, quorum, feeRecipient, viewingKey, checkpointInterval);
        vm.stopBroadcast();

        console.log("DomainHub deployed:", address(hub));
        console.log("  domain chain id:", domainChainId);
        console.log("  validators:", validators.length);
        console.log("  quorum:", quorum);
        console.log("  fee recipient:", feeRecipient);
        console.log("  checkpoint interval:", checkpointInterval);
        console.log("  viewing key bytes:", viewingKey.length);
    }
}

contract DeploySpoke is Script {
    function run() external returns (DomainSpoke spoke) {
        uint64 domainChainId = uint64(vm.envUint("DOMAIN_CHAIN_ID"));
        require(domainChainId == block.chainid, "Deploy: wrong domain chain");

        vm.startBroadcast();
        spoke = new DomainSpoke(domainChainId, vm.envUint("L1_CHAIN_ID"), vm.envAddress("HUB_ADDRESS"));
        vm.stopBroadcast();

        console.log("DomainSpoke deployed:", address(spoke));
        console.log("  hub:", spoke.HUB());
    }
}

contract DeployL1Bridge is Script {
    function run() external returns (L1Bridge l1Bridge) {
        uint64 domainChainId = uint64(vm.envUint("DOMAIN_CHAIN_ID"));
        require(domainChainId != 0, "Deploy: DOMAIN_CHAIN_ID not set");
        require(domainChainId != block.chainid, "Deploy: domain chain id equals current chain");
        address hub = vm.envAddress("HUB_ADDRESS");

        vm.startBroadcast();
        l1Bridge = new L1Bridge(IDomainHub(hub), domainChainId);
        vm.stopBroadcast();

        console.log("L1Bridge deployed:", address(l1Bridge));
        console.log("  domain chain id:", domainChainId);
        console.log("  owner:", l1Bridge.owner());
    }
}

contract DeployDomainBridge is Script {
    function run() external returns (DomainBridge domainBridge) {
        address spoke = vm.envAddress("SPOKE_ADDRESS");
        address l1Bridge = vm.envAddress("L1_BRIDGE_ADDRESS");

        vm.startBroadcast();
        domainBridge = new DomainBridge(IDomainSpoke(spoke), l1Bridge);
        vm.stopBroadcast();

        console.log("DomainBridge deployed:", address(domainBridge));
        console.log("  accepts messages from L1Bridge:", domainBridge.L1_BRIDGE());
    }
}

/// Allow (or disallow, with ALLOWED=false) a token for deposits:
///   L1_BRIDGE_ADDRESS=... TOKEN_ADDRESS=... \
///     forge script script/Deploy.s.sol:SetTokenAllowed --rpc-url $L1_RPC --broadcast
contract SetTokenAllowed is Script {
    function run() external {
        L1Bridge l1Bridge = L1Bridge(vm.envAddress("L1_BRIDGE_ADDRESS"));
        address token = vm.envAddress("TOKEN_ADDRESS");
        bool allowed = vm.envOr("ALLOWED", true);

        vm.startBroadcast();
        l1Bridge.setTokenAllowed(token, allowed);
        vm.stopBroadcast();

        console.log("Token", token, "allowed:", l1Bridge.allowedTokens(token));
    }
}

contract RegisterCounterpart is Script {
    function run() external {
        L1Bridge l1Bridge = L1Bridge(vm.envAddress("L1_BRIDGE_ADDRESS"));
        address domainBridge = vm.envAddress("DOMAIN_BRIDGE_ADDRESS");

        vm.startBroadcast();
        l1Bridge.registerDomainBridge(domainBridge);
        vm.stopBroadcast();

        require(l1Bridge.domainBridge() == domainBridge, "Deploy: wiring mismatch after registration");
        console.log("Registered counterpart on L1Bridge", address(l1Bridge));
        console.log("  domainBridge:", l1Bridge.domainBridge());
        console.log("Bridge pair is now permanently wired.");
    }
}
