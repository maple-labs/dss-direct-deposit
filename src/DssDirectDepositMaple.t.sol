// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import "../lib/dss-interfaces/src/Interfaces.sol";  // TODO: Remove

import { DSTest }  from "../lib/ds-test/src/test.sol";
// import { DSValue } from "../lib/ds-value/src/value.sol";

import { PoolDelegate } from "./accounts/PoolDelegate.sol";

import { DssDirectDepositMaple } from "./DssDirectDepositMaple.sol";

import { BPoolLike, BPoolFactoryLike, ERC20Like, Hevm, MapleGlobalsLike, PoolLike } from "./interfaces/Interfaces.sol";

contract DssDirectDepositMapleTest is DSTest {

    Hevm hevm;

    bytes32 constant ilk = "DD-DAI-B";

    uint256 constant WAD = 10 ** 18;

    address vow;
    address pauseProxy;

    ChainlogAbstract chainlog;
    VatAbstract      vat;
    EndAbstract      end;
    DaiJoinAbstract  daiJoin;
    SpotAbstract     spot;
    DSTokenAbstract  weth;

    PoolDelegate poolDelegate;

    address constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant MPL  = 0x33349B282065b0284d756F0577FB39c158F935e6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant BPOOL_FACTORY      = 0x9424B1412450D0f8Fc2255FAf6046b98213B76Bd;
    address constant USDC_BALANCER_POOL = 0xc1b10e536CD611aCFf7a7c32A9E29cE6A02Ef6ef;

    /***********************************/
    /*** Deployed Protocol Contracts ***/
    /***********************************/

    address constant GOVERNOR      = 0xd6d4Bcde6c816F17889f1Dd3000aF0261B03a196;
    address constant MAPLE_GLOBALS = 0xC234c62c8C09687DFf0d9047e40042cd166F3600;
    address constant POOL_FACTORY  = 0x2Cd79F7f8b38B9c0D80EA6B230441841A31537eC;
    address constant LOAN_FACTORY  = 0x908cC851Bc757248514E060aD8Bd0a03908308ee;
    address constant DL_FACTORY    = 0x2a7705594899Db6c3924A872676E54f041d1f9D8;
    address constant LL_FACTORY    = 0x966528BB1C44f96b3AA8Fbf411ee896116b068C9;
    address constant SL_FACTORY    = 0x53a597A4730Eb02095dD798B203Dcc306348B8d6;
    address constant USD_ORACLE    = 0x5DC5E14be1280E747cD036c089C96744EBF064E7;

    ERC20Like dai = ERC20Like(DAI);
    ERC20Like mpl = ERC20Like(MPL);

    function setUp() public {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

        _setUpMaplePool();
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

    function _setUpMaplePool() internal {
        
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

        emit log_named_uint("daiAmount      ", daiAmount);
        emit log_named_uint("mplAmount      ", mplAmount);

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
        PoolLike pool = PoolLike(poolDelegate.createPool(POOL_FACTORY, DAI, address(bPool), SL_FACTORY, LL_FACTORY, 500, 100, 5_000_000 ether));

        // Stake BPT for insurance and finalize pool
        poolDelegate.approve(address(bPool), pool.stakeLocker(), type(uint256).max);
        poolDelegate.stake(pool.stakeLocker(), bPool.balanceOf(address(poolDelegate)));
        poolDelegate.finalize(address(pool));
    }

    // function _setUpMaker() internal {
    //     vow        = 0xA950524441892A31ebddF91d3cEEFa04Bf454466;
    //     pauseProxy = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;

    //     chainlog = ChainlogAbstract(0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F);
    //     vat      = VatAbstract(     0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B);
    //     dai      = DaiAbstract(     0x6B175474E89094C44Da98b954EedeAC495271d0F);
    //     daiJoin  = DaiJoinAbstract( 0x9759A6Ac90977b93B58547b4A71c78317f391A28);
    //     spot     = SpotAbstract(    0x65C79fcB50Ca1594B025960e539eD7A9a6D434A3);
    //     weth     = DSTokenAbstract( 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    //     // Force give admin access to these contracts via hevm magic
    //     hevm.store(address(vat),  keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));
    //     hevm.store(address(end),  keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));
    //     hevm.store(address(spot), keccak256(abi.encode(address(this), 0)), bytes32(uint256(1)));
    // }

    function test_sii() external { 
        assertTrue(false); 
    }
}

