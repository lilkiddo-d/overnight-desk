// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {MarketClock} from "../src/core/MarketClock.sol";
import {TermRegistry} from "../src/core/TermRegistry.sol";
import {RepoNote} from "../src/core/RepoNote.sol";
import {RepoLocker} from "../src/core/RepoLocker.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {Liquidator} from "../src/core/Liquidator.sol";
import {AuctionHouse} from "../src/core/AuctionHouse.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {FeeCollector} from "../src/periphery/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/periphery/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../src/periphery/ComplianceRegistry.sol";
import {NoteMarket} from "../src/periphery/NoteMarket.sol";
import {OvernightTimelock} from "../src/periphery/OvernightTimelock.sol";
import {ITermRegistry} from "../src/interfaces/ITermRegistry.sol";
import {IMarketClock} from "../src/interfaces/IMarketClock.sol";
import {IRepoLocker} from "../src/interfaces/IRepoLocker.sol";
import {IRepoNote} from "../src/interfaces/IRepoNote.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {IOracleAdapter} from "../src/interfaces/IOracleAdapter.sol";
import {ILiquidator} from "../src/interfaces/ILiquidator.sol";
import {IProjectTokenHooks} from "../src/interfaces/IProjectTokenHooks.sol";
import {IComplianceRegistry} from "../src/interfaces/IComplianceRegistry.sol";

/// @notice Shared deployment + wiring logic used by script/Deploy.s.sol AND the test suite, so tests exercise
///         exactly the production wiring.
abstract contract ProtocolDeployer {
    struct CoreConfig {
        address deployer; // temporary admin during wiring; renounced at hand-off
        address guardian; // pause/unpause + compliance list manager
        address treasury;
        address stablecoin;
        ITermRegistry.Params params;
        uint64 genesis;
        uint64 interval;
        uint64 commitWindow;
        uint64 revealWindow;
        uint64 clearWindow;
        uint256 timelockDelay;
        address[] proposers;
        address[] executors;
        string noteUri;
    }

    struct Deployment {
        MarketClock clock;
        TermRegistry registry;
        RepoNote note;
        RepoLocker locker;
        OracleAdapter oracle;
        MarginEngine engine;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        Liquidator liquidator;
        ComplianceRegistry compliance;
        AuctionHouse auctionHouse;
        NoteMarket noteMarket;
        OvernightTimelock timelock;
    }

    function _deployProtocol(CoreConfig memory c) internal returns (Deployment memory d) {
        address a = c.deployer;
        d.clock = new MarketClock(a, c.genesis, c.interval, c.commitWindow, c.revealWindow, c.clearWindow);
        d.registry = new TermRegistry(a, c.stablecoin, c.params);
        d.note = new RepoNote(a, c.noteUri);
        d.locker = new RepoLocker(a, ITermRegistry(address(d.registry)), IRepoNote(address(d.note)));
        d.oracle = new OracleAdapter(a, IMarketClock(address(d.clock)));
        d.engine = new MarginEngine(
            a,
            ITermRegistry(address(d.registry)),
            IRepoLocker(address(d.locker)),
            IMarketClock(address(d.clock)),
            IOracleAdapter(address(d.oracle))
        );
        d.feeCollector = new FeeCollector(a, IERC20(c.stablecoin), c.treasury);
        d.hooks = new ProjectTokenHooks(a, IERC20(c.stablecoin));
        d.liquidator = new Liquidator(
            a,
            ITermRegistry(address(d.registry)),
            IRepoLocker(address(d.locker)),
            IOracleAdapter(address(d.oracle)),
            address(d.feeCollector)
        );
        d.compliance = new ComplianceRegistry(a);
        d.auctionHouse = new AuctionHouse(
            a,
            ITermRegistry(address(d.registry)),
            IMarketClock(address(d.clock)),
            IRepoLocker(address(d.locker)),
            IRepoNote(address(d.note)),
            IMarginEngine(address(d.engine)),
            address(d.feeCollector)
        );
        d.noteMarket = new NoteMarket(a, IRepoNote(address(d.note)), IERC20(c.stablecoin), address(d.feeCollector));
        d.timelock = new OvernightTimelock(c.timelockDelay, c.proposers, c.executors);

        _wire(d, c);
    }

    function _wire(Deployment memory d, CoreConfig memory c) internal {
        d.note.grantRole(d.note.MINTER_ROLE(), address(d.auctionHouse));
        d.note.grantRole(d.note.BURNER_ROLE(), address(d.locker));

        d.locker.grantRole(d.locker.AUCTION_ROLE(), address(d.auctionHouse));
        d.locker.grantRole(d.locker.MARGIN_ROLE(), address(d.engine));
        d.locker.grantRole(d.locker.LIQUIDATOR_ROLE(), address(d.liquidator));
        d.locker.setMarginEngine(IMarginEngine(address(d.engine)));

        d.engine.setLiquidator(ILiquidator(address(d.liquidator)));
        d.liquidator.grantRole(d.liquidator.ENGINE_ROLE(), address(d.engine));

        d.hooks.grantRole(d.hooks.FEE_COLLECTOR_ROLE(), address(d.feeCollector));
        d.feeCollector.setHooks(IProjectTokenHooks(address(d.hooks)));
        d.auctionHouse.setHooks(IProjectTokenHooks(address(d.hooks)));
        d.auctionHouse.setCompliance(IComplianceRegistry(address(d.compliance)));
        d.noteMarket.setCompliance(IComplianceRegistry(address(d.compliance)));
        d.compliance.grantRole(d.compliance.COMPLIANCE_ROLE(), c.guardian);

        _grantGuardian(d, c.guardian);
    }

    function _grantGuardian(Deployment memory d, address g) internal {
        bytes32 role = d.clock.GUARDIAN_ROLE();
        d.clock.grantRole(role, g);
        d.registry.grantRole(role, g);
        d.locker.grantRole(role, g);
        d.oracle.grantRole(role, g);
        d.engine.grantRole(role, g);
        d.feeCollector.grantRole(role, g);
        d.hooks.grantRole(role, g);
        d.liquidator.grantRole(role, g);
        d.auctionHouse.grantRole(role, g);
        d.noteMarket.grantRole(role, g);
    }

    /// @notice Make the Timelock the sole admin of every contract and renounce the deployer's admin role.
    function _handoff(Deployment memory d, address deployer) internal {
        address t = address(d.timelock);
        AccessControl[12] memory all = [
            AccessControl(address(d.clock)),
            AccessControl(address(d.registry)),
            AccessControl(address(d.note)),
            AccessControl(address(d.locker)),
            AccessControl(address(d.oracle)),
            AccessControl(address(d.engine)),
            AccessControl(address(d.feeCollector)),
            AccessControl(address(d.hooks)),
            AccessControl(address(d.liquidator)),
            AccessControl(address(d.compliance)),
            AccessControl(address(d.auctionHouse)),
            AccessControl(address(d.noteMarket))
        ];
        bytes32 admin = 0x00;
        for (uint256 i; i < all.length; ++i) {
            all[i].grantRole(admin, t);
            all[i].renounceRole(admin, deployer);
        }
    }
}
