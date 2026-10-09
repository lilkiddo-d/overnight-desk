// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ProtocolDeployer} from "./ProtocolDeployer.sol";
import {ITermRegistry} from "../src/interfaces/ITermRegistry.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";

/// @title Deploy
/// @notice One-shot deployment: deploys + wires every contract, configures terms / collateral / oracle feeds /
///         books from config/deploy.<chainId>.json, hands DEFAULT_ADMIN_ROLE to the 48h Timelock (deployer
///         renounces), and writes deployments/<chainId>.json plus the frontend config.
///
///         Signing is done ONLY by the Foundry keystore passed on the command line
///         (`--account overnightdesk-deployer`). This script never reads, derives or prints a private key.
///
///         Env (all optional):
///           GUARDIAN           pause key + compliance list manager      (default: deployer)
///           TREASURY           fee recipient                            (default: deployer)
///           TIMELOCK_PROPOSER  proposer/canceller AND executor (multisig) (default: deployer)
///           DEPLOY_CONFIG      config chain id to load                  (default: block.chainid)
///           NOTE_URI           ERC-1155 metadata URI
contract Deploy is Script, ProtocolDeployer {
    /// @dev Fields in alphabetical order to match vm.parseJson's decoding.
    struct AssetCfg {
        address feed;
        uint256 initialHaircutBps;
        uint256 liquidationPenaltyBps;
        uint256 maintenanceHaircutBps;
        uint256 maxCollateralPerAuction;
        uint256 maxStaleness;
        uint256 maxStalenessClosed;
        string symbol;
        address token;
    }

    struct TermCfg {
        uint256 duration;
        string label;
    }

    address internal constant FOUNDRY_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function run() external returns (Deployment memory d) {
        address deployer = msg.sender;
        require(deployer != FOUNDRY_DEFAULT_SENDER, "pass --sender <overnightdesk-deployer address>");

        uint256 cfgId = vm.envOr("DEPLOY_CONFIG", block.chainid);
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/config/deploy.", vm.toString(cfgId), ".json"));

        CoreConfig memory c = _coreConfig(json, deployer);
        TermCfg[] memory terms = abi.decode(vm.parseJson(json, ".terms"), (TermCfg[]));
        AssetCfg[] memory assets = abi.decode(vm.parseJson(json, ".assets"), (AssetCfg[]));

        _preflight(c.stablecoin, assets);

        vm.startBroadcast(deployer);
        d = _deployProtocol(c);
        d.clock
            .setMarketHours(
                uint32(vm.parseJsonUint(json, ".marketHours.open")),
                uint32(vm.parseJsonUint(json, ".marketHours.close")),
                uint8(vm.parseJsonUint(json, ".marketHours.daysMask")),
                vm.parseJsonBool(json, ".marketHours.enforced")
            );
        for (uint256 i; i < terms.length; ++i) {
            d.registry.addTerm(uint32(terms[i].duration), terms[i].label);
        }
        for (uint256 j; j < assets.length; ++j) {
            AssetCfg memory a = assets[j];
            d.registry
                .configureCollateral(
                    a.token,
                    ITermRegistry.CollateralConfig({
                        enabled: true,
                        decimals: 0,
                        initialHaircutBps: uint16(a.initialHaircutBps),
                        maintenanceHaircutBps: uint16(a.maintenanceHaircutBps),
                        liquidationPenaltyBps: uint16(a.liquidationPenaltyBps),
                        maxCollateralPerAuction: uint128(a.maxCollateralPerAuction)
                    })
                );
            d.oracle
                .setFeed(
                    a.token,
                    OracleAdapter.FeedConfig({
                        primary: a.feed,
                        secondary: address(0),
                        maxStaleness: uint32(a.maxStaleness),
                        maxStalenessClosed: uint32(a.maxStalenessClosed),
                        maxDeviationBps: 0
                    })
                );
            for (uint256 i; i < terms.length; ++i) {
                d.registry.addBook(uint16(i), a.token);
            }
        }
        _handoff(d, deployer);
        vm.stopBroadcast();

        _postflight(d, deployer);
        _write(d, c, assets, terms.length);
    }

    function _coreConfig(string memory json, address deployer) internal view returns (CoreConfig memory c) {
        address guardian = vm.envOr("GUARDIAN", deployer);
        address proposer = vm.envOr("TIMELOCK_PROPOSER", deployer);
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        uint256 hour = vm.parseJsonUint(json, ".clock.genesisHourUtc");
        uint256 genesis = (block.timestamp / 1 days) * 1 days + hour * 1 hours;
        if (genesis > block.timestamp) genesis -= 1 days;

        c.deployer = deployer;
        c.guardian = guardian;
        c.treasury = vm.envOr("TREASURY", deployer);
        c.stablecoin = vm.parseJsonAddress(json, ".stablecoin");
        c.params = ITermRegistry.Params({
            minOrderSize: uint128(vm.parseJsonUint(json, ".params.minOrderSize")),
            maxRateBps: uint32(vm.parseJsonUint(json, ".params.maxRateBps")),
            auctionFeeBpsPerYear: uint16(vm.parseJsonUint(json, ".params.auctionFeeBpsPerYear")),
            noRevealPenaltyBps: uint16(vm.parseJsonUint(json, ".params.noRevealPenaltyBps")),
            maxOrdersPerSide: uint16(vm.parseJsonUint(json, ".params.maxOrdersPerSide")),
            marginCallGracePeriod: uint32(vm.parseJsonUint(json, ".params.marginCallGracePeriod")),
            maturityGracePeriod: uint32(vm.parseJsonUint(json, ".params.maturityGracePeriod"))
        });
        c.genesis = uint64(genesis);
        c.interval = uint64(vm.parseJsonUint(json, ".clock.interval"));
        c.commitWindow = uint64(vm.parseJsonUint(json, ".clock.commitWindow"));
        c.revealWindow = uint64(vm.parseJsonUint(json, ".clock.revealWindow"));
        c.clearWindow = uint64(vm.parseJsonUint(json, ".clock.clearWindow"));
        c.timelockDelay = 48 hours;
        c.proposers = proposers;
        c.executors = proposers;
        c.noteUri = vm.envOr("NOTE_URI", string("https://overnightdesk.app/api/notes/{id}.json"));
    }

    /// @dev Fail fast (before broadcasting anything) if an address in the config has no code or a feed is dead.
    function _preflight(address stable, AssetCfg[] memory assets) internal view {
        require(stable.code.length > 0, "stablecoin has no code on this chain");
        for (uint256 i; i < assets.length; ++i) {
            require(assets[i].token.code.length > 0, string.concat(assets[i].symbol, ": token has no code"));
            require(assets[i].feed.code.length > 0, string.concat(assets[i].symbol, ": feed has no code"));
            (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(assets[i].feed).latestRoundData();
            require(answer > 0 && updatedAt > 0, string.concat(assets[i].symbol, ": feed returned no price"));
        }
    }

    function _postflight(Deployment memory d, address deployer) internal view {
        bytes32 admin = 0x00;
        require(d.auctionHouse.hasRole(admin, address(d.timelock)), "timelock not admin");
        require(!d.auctionHouse.hasRole(admin, deployer), "deployer still admin");
        require(!d.registry.hasRole(admin, deployer), "deployer still admin");
        require(d.timelock.getMinDelay() >= 48 hours, "timelock delay");
        require(address(d.hooks.projectToken()) == address(0), "project token must start unset");
        console2.log("AuctionHouse", address(d.auctionHouse));
        console2.log("Timelock    ", address(d.timelock));
        console2.log("Books       ", d.registry.bookCount());
    }

    function _write(Deployment memory d, CoreConfig memory c, AssetCfg[] memory assets, uint256 nTerms) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAt", block.timestamp);
        vm.serializeUint(k, "genesis", c.genesis);
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "treasury", c.treasury);
        vm.serializeAddress(k, "stablecoin", c.stablecoin);
        vm.serializeAddress(k, "MarketClock", address(d.clock));
        vm.serializeAddress(k, "TermRegistry", address(d.registry));
        vm.serializeAddress(k, "RepoNote", address(d.note));
        vm.serializeAddress(k, "RepoLocker", address(d.locker));
        vm.serializeAddress(k, "OracleAdapter", address(d.oracle));
        vm.serializeAddress(k, "MarginEngine", address(d.engine));
        vm.serializeAddress(k, "FeeCollector", address(d.feeCollector));
        vm.serializeAddress(k, "ProjectTokenHooks", address(d.hooks));
        vm.serializeAddress(k, "Liquidator", address(d.liquidator));
        vm.serializeAddress(k, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(k, "NoteMarket", address(d.noteMarket));
        vm.serializeAddress(k, "Timelock", address(d.timelock));
        vm.serializeUint(k, "termCount", nTerms);
        string memory out = vm.serializeAddress(k, "AuctionHouse", address(d.auctionHouse));

        string memory assetsKey = "assets";
        string memory assetsJson;
        for (uint256 i; i < assets.length; ++i) {
            assetsJson = vm.serializeAddress(assetsKey, assets[i].symbol, assets[i].token);
        }
        out = vm.serializeString(k, "collateral", assetsJson);

        bool broadcasting = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory suffix = broadcasting ? ".json" : ".dryrun.json";
        string memory name = string.concat(vm.toString(block.chainid), suffix);
        vm.writeJson(out, string.concat(vm.projectRoot(), "/../deployments/", name));
        vm.writeJson(out, string.concat(vm.projectRoot(), "/../app/public/deployments/", name));
        console2.log("wrote deployments/", name);
    }
}
