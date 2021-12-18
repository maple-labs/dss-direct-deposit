// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ChainlogAbstract, VatAbstract, EndAbstract, DaiJoinAbstract, SpotAbstract } from "../lib/dss-interfaces/src/Interfaces.sol";

import { DSTest }  from "../lib/ds-test/src/test.sol";
import { DSValue } from "../lib/ds-value/src/value.sol";

import { PoolDelegate } from "./accounts/PoolDelegate.sol";

import { BPoolLike, BPoolFactoryLike, ERC20Like, Hevm, MapleGlobalsLike, PoolLike } from "./interfaces/Interfaces.sol";

import { AddressRegistry }       from "./AddressRegistry.sol";
import { DirectDepositMom }      from "./DirectDepositMom.sol";
import { DssDirectDepositMaple } from "./DssDirectDepositMaple.sol";

contract DssDirectDepositMapleTest is AddressRegistry, DSTest {

    Hevm hevm;

    bytes32 constant ilk = "DD-DAI-B";

    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    ChainlogAbstract constant chainlog = ChainlogAbstract(CHAINLOG);
    VatAbstract      constant vat      = VatAbstract(VAT);
    EndAbstract      constant end      = EndAbstract(END);
    DaiJoinAbstract  constant daiJoin  = DaiJoinAbstract(DAI_JOIN);
    SpotAbstract     constant spot     = SpotAbstract(SPOT);

    ERC20Like constant dai = ERC20Like(DAI);
    ERC20Like constant mpl = ERC20Like(MPL);

    PoolDelegate poolDelegate;
    PoolLike     pool;

    DssDirectDepositMaple deposit;
    DirectDepositMom      directDepositMom;
    DSValue               pip;

    function setUp() public {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

        _setUpMapleDaiPool();

        // Force give admin access to these contracts via hevm magic
        hevm.store(address(vat),  keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));
        hevm.store(address(end),  keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));
        hevm.store(address(spot), keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));

        // Deploy Maple D3M module
        deposit = new DssDirectDepositMaple(address(chainlog), ilk, address(pool));
        deposit.file("tau", 7 days);
        directDepositMom = new DirectDepositMom();
        deposit.rely(address(directDepositMom));

        // Init as new collateral
        pip = new DSValue();
        pip.poke(bytes32(WAD));
        spot.file(ilk, "pip", address(pip));
        spot.file(ilk, "mat", RAY);
        spot.poke(ilk);

        vat.rely(address(deposit));
        vat.init(ilk);
        vat.file(ilk, "line", 5_000_000 * RAD);
        vat.file("Line", vat.Line() + 5_000_000 * RAD);

        // Add Maker D3M as sole lender in new Maple pool
        poolDelegate.setAllowList(address(pool), address(deposit), true);
    }

    function _mintTokens(address token, address account, uint256 amount) internal {
        uint256 slot;

        if      (token == DAI) slot = 2;
        else if (token == MPL) slot = 0;

        hevm.store(
            token,
            keccak256(abi.encode(account, slot)),
            bytes32(ERC20Like(token).balanceOf(address(account)) + amount)
        );
    }

    function _setUpMapleDaiPool() internal {
        
        /*********************/
        /*** Set up actors ***/
        /*********************/

        // Grant address(this) auth access to globals
        hevm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

        poolDelegate = new PoolDelegate();

        /************************************/
        /*** Set up MPL/DAI Balancer Pool ***/
        /************************************/

        BPoolLike usdcBPool = BPoolLike(USDC_BALANCER_POOL);

        uint256 daiAmount = 300_000 * WAD;
        uint256 mplAmount = daiAmount * WAD / (usdcBPool.getSpotPrice(USDC, MPL) * WAD / 10 ** 6);  // $100k of MPL

        _mintTokens(DAI, address(this), daiAmount);
        _mintTokens(MPL, address(this), mplAmount);

        // Initialize MPL/DAI Balancer Pool
        BPoolLike bPool = BPoolLike(BPoolFactoryLike(BPOOL_FACTORY).newBPool());
        dai.approve(address(bPool), type(uint256).max);
        mpl.approve(address(bPool), type(uint256).max);
        bPool.bind(DAI, daiAmount, 5 ether);
        bPool.bind(MPL, mplAmount, 5 ether);
        bPool.finalize();

        // Transfer all BPT to Pool Delegate for initial staking
        bPool.transfer(address(poolDelegate), 40 * WAD);  // Pool Delegate gets enought BPT to stake

        /*************************/
        /*** Configure Globals ***/
        /*************************/

        MapleGlobalsLike globals = MapleGlobalsLike(MAPLE_GLOBALS);

        globals.setLiquidityAsset(DAI, true);
        globals.setPoolDelegateAllowlist(address(poolDelegate), true);
        globals.setValidBalancerPool(address(bPool), true);
        globals.setPriceOracle(DAI, USD_ORACLE);

        /*******************************************************/
        /*** Set up new DAI liquidity pool, closed to public ***/
        /*******************************************************/

        // Create a DAI pool with a 5m liquidity cap
        pool = PoolLike(poolDelegate.createPool(POOL_FACTORY, DAI, address(bPool), SL_FACTORY, LL_FACTORY, 500, 100, 5_000_000 ether));

        // Stake BPT for insurance and finalize pool
        poolDelegate.approve(address(bPool), pool.stakeLocker(), type(uint256).max);
        poolDelegate.stake(pool.stakeLocker(), bPool.balanceOf(address(poolDelegate)));
        poolDelegate.finalize(address(pool));
    }

    function test_basic_deposit() external { 
        uint256 daiTotalSupply = dai.totalSupply();

        assertEq(dai.balanceOf(address(pool.liquidityLocker())), 0);
        assertEq(pool.balanceOf(address(deposit)),               0);

        deposit.exec();

        assertEq(dai.totalSupply(), daiTotalSupply + 5_000_000 * WAD);

        assertEq(dai.balanceOf(address(pool.liquidityLocker())), 5_000_000 * WAD);
        assertEq(pool.balanceOf(address(deposit)),               5_000_000 * WAD);
    }
}

