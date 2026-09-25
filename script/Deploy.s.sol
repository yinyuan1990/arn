// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SimpleDescriptor} from "../src/periphery/SimpleDescriptor.sol";
import {Treasury} from "../src/Treasury.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {ReferralHub} from "../src/ReferralHub.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";

/// Deploys the Arm contracts. On Arc mainnet pass UNI_FACTORY + UNI_NFPM (the official Uniswap V3 deployment,
/// which wallets / aggregators index); our own SwapRouter / QuoterV2 (v1 ABI) are deployed against it.
///   USDC         — native USDC ERC-20 interface on Arc: 0x3600000000000000000000000000000000000000
///   OWNER        — admin of Treasury / FeeLocker / ReferralHub / LaunchFactory (defaults to the deployer)
///   KEEPER       — may settle referral pools (defaults to the deployer; rotatable on the hub)
///   ECO_FUND     — reserve, IMMUTABLE: 16/22 of protocol revenue (0.16% of every trade)
///   BUYBACK_FUND — buyback fund, IMMUTABLE: 5/22 (0.05% of every trade)
///   DEV_FUND     — technical team, IMMUTABLE: 1/22 (0.01% of every trade)
contract Deploy is Script {
    address internal constant RESERVE = 0x32710934A037A32055EeC1986f481be52B103F3B;
    address internal constant BUYBACK = 0x85F38d7a46917F1bb45C7B0B8617afB8eEbea8AB;
    address internal constant DEV_TEAM = 0x2E5673220eBCcc5c30ef7E0755199B4303dB626f;

    struct Cfg {
        address deployer;
        address usdc;
        address owner;
        address keeper;
        address ecoFund;
        address buybackFund;
        address devFund;
        address uniFactory;
        address nfpm;
    }

    struct Out {
        address uniFactory;
        address nfpm;
        address router;
        address quoter;
        address treasury;
        address locker;
        address hub;
        address factory;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Cfg memory c;
        c.deployer = vm.addr(pk);
        c.usdc = vm.envOr("USDC", address(0x3600000000000000000000000000000000000000));
        c.owner = vm.envOr("OWNER", c.deployer);
        c.keeper = vm.envOr("KEEPER", c.deployer);
        c.ecoFund = vm.envOr("ECO_FUND", RESERVE);
        c.buybackFund = vm.envOr("BUYBACK_FUND", BUYBACK);
        c.devFund = vm.envOr("DEV_FUND", DEV_TEAM);
        c.uniFactory = vm.envOr("UNI_FACTORY", address(0));
        c.nfpm = vm.envOr("UNI_NFPM", address(0));
        require((c.uniFactory == address(0)) == (c.nfpm == address(0)), "UNI_FACTORY and UNI_NFPM go together");
        require(c.owner == c.deployer, "one-time wiring (setFactory) needs OWNER = deployer; hand over afterwards");

        vm.startBroadcast(pk);
        Out memory o = _deploy(c);
        vm.stopBroadcast();

        string memory defaultOut = block.chainid == 5042 ? "deployments/arc-mainnet.json" : "deployments/arc-testnet.json";
        _write(c, o, vm.envOr("OUT_FILE", defaultOut));
    }

    function _deploy(Cfg memory c) internal returns (Out memory o) {
        if (c.uniFactory != address(0)) {
            o.uniFactory = c.uniFactory;
            o.nfpm = c.nfpm;
        } else {
            o.uniFactory = deployCode("vendor/uniswap-v3/UniswapV3Factory.json");
            address descriptor = address(new SimpleDescriptor());
            o.nfpm = deployCode(
                "vendor/uniswap-v3/NonfungiblePositionManager.json", abi.encode(o.uniFactory, c.usdc, descriptor)
            );
        }
        o.router = deployCode("vendor/uniswap-v3/SwapRouter.json", abi.encode(o.uniFactory, c.usdc));
        o.quoter = deployCode("vendor/uniswap-v3/QuoterV2.json", abi.encode(o.uniFactory, c.usdc));

        o.treasury = address(new Treasury(c.usdc, o.router, c.ecoFund, c.buybackFund, c.devFund, c.owner));
        FeeLocker locker = new FeeLocker(o.nfpm, o.router, o.treasury, c.owner);
        o.locker = address(locker);
        ReferralHub hub = new ReferralHub(c.usdc, o.locker, c.keeper, c.owner);
        o.hub = address(hub);
        o.factory = address(
            new LaunchFactory(o.uniFactory, o.nfpm, o.router, c.usdc, o.locker, o.treasury, o.hub, c.owner)
        );
        locker.setFactory(o.factory);
        hub.setFactory(o.factory);
    }

    function _write(Cfg memory c, Out memory o, string memory outFile) internal {
        string memory j = "d";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeAddress(j, "deployer", c.deployer);
        vm.serializeAddress(j, "owner", c.owner);
        vm.serializeAddress(j, "keeper", c.keeper);
        vm.serializeAddress(j, "ecoFund", c.ecoFund);
        vm.serializeAddress(j, "buybackFund", c.buybackFund);
        vm.serializeAddress(j, "devFund", c.devFund);
        vm.serializeAddress(j, "usdc", c.usdc);
        vm.serializeAddress(j, "uniswapV3Factory", o.uniFactory);
        vm.serializeAddress(j, "positionManager", o.nfpm);
        vm.serializeAddress(j, "swapRouter", o.router);
        vm.serializeAddress(j, "quoterV2", o.quoter);
        vm.serializeAddress(j, "treasury", o.treasury);
        vm.serializeAddress(j, "feeLocker", o.locker);
        vm.serializeAddress(j, "referralHub", o.hub);
        vm.serializeUint(j, "deployBlock", block.number);
        string memory out = vm.serializeAddress(j, "launchFactory", o.factory);
        vm.writeJson(out, outFile);

        console2.log("UniswapV3Factory ", o.uniFactory);
        console2.log("PositionManager  ", o.nfpm);
        console2.log("SwapRouter       ", o.router);
        console2.log("QuoterV2         ", o.quoter);
        console2.log("Treasury         ", o.treasury);
        console2.log("FeeLocker        ", o.locker);
        console2.log("ReferralHub      ", o.hub);
        console2.log("LaunchFactory    ", o.factory);
        console2.log("reserve (immutable)", c.ecoFund);
        console2.log("buyback (immutable)", c.buybackFund);
        console2.log("dev team (immutable)", c.devFund);
        console2.log("keeper", c.keeper);
    }
}
