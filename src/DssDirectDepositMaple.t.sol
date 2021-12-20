// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ChainlogAbstract, VatAbstract, EndAbstract, DaiJoinAbstract, SpotAbstract } from "../lib/dss-interfaces/src/Interfaces.sol";

import { DSTest }  from "../lib/ds-test/src/test.sol";
import { DSValue } from "../lib/ds-value/src/value.sol";

import { Borrower }     from "./accounts/Borrower.sol";
import { PoolDelegate } from "./accounts/PoolDelegate.sol";

import { BPoolLike, BPoolFactoryLike, ERC20Like, Hevm, LoanLike, MapleGlobalsLike, PoolLike } from "./interfaces/Interfaces.sol";

import { AddressRegistry }       from "./AddressRegistry.sol";
import { DirectDepositMom }      from "./DirectDepositMom.sol";
import { DssDirectDepositMaple } from "./DssDirectDepositMaple.sol";

contract DssDirectDepositMapleTest is AddressRegistry, DSTest {

    Hevm hevm;

    bytes32 constant ilk = "DD-DAI-B";

    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    address[3] calcs;

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

    uint256 start;

    function setUp() public {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

        start = block.timestamp;

        calcs = [REPAYMENT_CALC, LATEFEE_CALC, PREMIUM_CALC];

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

    function test_basic_deposit() external { 
        uint256 daiTotalSupply = dai.totalSupply();

        ( uint256 ink, uint256 art ) = vat.urns(ilk, address(deposit));
        ( uint256 Art,,,, )          = vat.ilks(ilk);

        uint256 gem    = vat.gem(ilk, address(deposit));
        uint256 vatDai = vat.dai(address(deposit));

        assertEq(ink,    0);
        assertEq(art,    0);
        assertEq(Art,    0);
        assertEq(gem,    0);
        assertEq(vatDai, 0);

        assertEq(dai.balanceOf(address(pool.liquidityLocker())), 0);
        assertEq(pool.balanceOf(address(deposit)),               0);

        deposit.exec();

        ( ink, art ) = vat.urns(ilk, address(deposit));
        ( Art,,,, )  = vat.ilks(ilk);

        gem    = vat.gem(ilk, address(deposit));
        vatDai = vat.dai(address(deposit));

        assertEq(ink,    5_000_000 * WAD);
        assertEq(art,    5_000_000 * WAD);
        assertEq(Art,    5_000_000 * WAD);
        assertEq(gem,    0);  // TODO: Follow up on why gem doesn't change
        assertEq(vatDai, 0);

        assertEq(dai.totalSupply(), daiTotalSupply + 5_000_000 * WAD);

        assertEq(dai.balanceOf(address(pool.liquidityLocker())), 5_000_000 * WAD);
        assertEq(pool.balanceOf(address(deposit)),               5_000_000 * WAD);
    }

    function test_claim_interest() external { 

        deposit.exec();  // D3M deposits

        /***********************************************/
        /*** Set up Loans and Make Interest Payments ***/
        /***********************************************/

        Borrower borrower1 = new Borrower();
        Borrower borrower2 = new Borrower();

        // Loan 1: 10% APR, 180 day term, 30 day payment interval, 1m USD, 20% collateralized with WBTC
        // Loan 2: 10% APR, 180 day term, 30 day payment interval, 4m USD, 0% collateralized

        LoanLike loan1 = LoanLike(_createLoan(borrower1, [1000, 180, 30, uint256(1_000_000 * WAD), 2000]));
        LoanLike loan2 = LoanLike(_createLoan(borrower2, [1000, 180, 30, uint256(4_000_000 * WAD), 0]));

        _fundLoanAndDrawdown(borrower1, address(loan1), 1_000_000 * WAD);
        _fundLoanAndDrawdown(borrower2, address(loan2), 4_000_000 * WAD);

        hevm.warp(start + 30 days);

        _makePayment(address(loan1), address(borrower1));
        _makePayment(address(loan2), address(borrower2));

        /********************************/
        /*** Claim Interest into Pool ***/
        /********************************/

        assertEq(dai.balanceOf(pool.liquidityLocker()),      0);  // Cash balance of pool
        assertEq(pool.withdrawableFundsOf(address(deposit)), 0);  // Claimable interest of D3M

        poolDelegate.claim(address(pool), address(loan1), DL_FACTORY);
        poolDelegate.claim(address(pool), address(loan2), DL_FACTORY);

        uint256 pool_claimedInterest = 32_876_712328767123287670;  // 80% net interest
        uint256 d3m_claimedInterest  = 32_876_712328767123287669;  // FDT rounding

        assertEq(dai.balanceOf(pool.liquidityLocker()),      pool_claimedInterest); // Cash balance of pool
        assertEq(pool.withdrawableFundsOf(address(deposit)), d3m_claimedInterest);  // Claimable interest of D3M

        /*******************************/
        /*** Claim Interest into Vow ***/
        /*******************************/

        uint256 dai_totalSupply = dai.totalSupply();
        uint256 vat_dai_vow     = vat.dai(VOW);

        assertEq(dai_totalSupply, 8_917_709_696_588987632222332732);
        assertEq(vat_dai_vow,       234_393_574_218836631387411018108387992280731891223013718);

        deposit.reap();

        assertEq(dai.balanceOf(pool.liquidityLocker()),      1);  // Cash balance of pool (dust)
        assertEq(pool.withdrawableFundsOf(address(deposit)), 0);  // Claimable interest of D3M

        assertEq(dai.totalSupply(), dai_totalSupply - d3m_claimedInterest);
        assertEq(vat.dai(VOW),      vat_dai_vow     + d3m_claimedInterest * RAY);  // Convert to RAD
    }

    function test_withdraw_full_liquidity() external {

        deposit.exec();  // D3M deposits

        /******************************************/
        /*** Set up Loans and Make All Payments ***/
        /******************************************/

        Borrower borrower1 = new Borrower();
        Borrower borrower2 = new Borrower();

        // Loan 1: 10% APR, 180 day term, 30 day payment interval, 1m USD, 20% collateralized with WBTC
        // Loan 2: 10% APR, 180 day term, 30 day payment interval, 4m USD, 0% collateralized

        LoanLike loan1 = LoanLike(_createLoan(borrower1, [1000, 180, 30, uint256(1_000_000 * WAD), 2000]));
        LoanLike loan2 = LoanLike(_createLoan(borrower2, [1000, 180, 30, uint256(4_000_000 * WAD), 0]));

        _fundLoanAndDrawdown(borrower1, address(loan1), 1_000_000 * WAD);
        _fundLoanAndDrawdown(borrower2, address(loan2), 4_000_000 * WAD);

        for (uint256 i; i < 6; ++i) {
            hevm.warp(start + (30 days * (i + 1)));

            _makePayment(address(loan1), address(borrower1));
            _makePayment(address(loan2), address(borrower2));
        }

        /********************************************/
        /*** Claim Principal + Interest into Pool ***/
        /********************************************/

        assertEq(dai.balanceOf(pool.liquidityLocker()),      0);  // Cash balance of pool
        assertEq(pool.withdrawableFundsOf(address(deposit)), 0);  // Claimable interest of D3M

        poolDelegate.claim(address(pool), address(loan1), DL_FACTORY);
        poolDelegate.claim(address(pool), address(loan2), DL_FACTORY);

        uint256 netInterestPaid = 197_260_273972602739726020;

        assertEq(dai.balanceOf(pool.liquidityLocker()),      5_000_000 * WAD + netInterestPaid);  // Cash balance of pool
        assertEq(pool.withdrawableFundsOf(address(deposit)), netInterestPaid + 1);                // Claimable interest of D3M (8% APY) (FDT rounding error)

        /*************************************************************************************/
        /*** Call `exec()` without triggering cooldown (no change except claimed interest) ***/
        /*************************************************************************************/

        ( uint256 pre_ink, uint256 pre_art ) = vat.urns(ilk, address(deposit));
        ( uint256 pre_Art,,,, )              = vat.ilks(ilk);

        uint256 pre_daiTotalSupply = dai.totalSupply();
        uint256 pre_vat_dai_vow    = vat.dai(VOW);
        uint256 pre_vatDai         = vat.dai(address(deposit));
        uint256 pre_gem            = vat.gem(ilk, address(deposit));

        deposit.exec();

        ( uint256 post_ink, uint256 post_art ) = vat.urns(ilk, address(deposit));
        ( uint256 post_Art,,,, )               = vat.ilks(ilk);

        assertEq(post_ink, pre_ink);
        assertEq(post_art, pre_art);
        assertEq(post_Art, pre_Art);

        assertEq(vat.gem(ilk, address(deposit)), pre_gem);
        assertEq(vat.dai(address(deposit)),      pre_vatDai);

        assertEq(dai.totalSupply(), pre_daiTotalSupply - (netInterestPaid + 1));
        assertEq(vat.dai(VOW),      pre_vat_dai_vow    + (netInterestPaid + 1) * RAY);

        /******************************************************************/
        /*** Call `exec()` after triggering cooldown (perform withdraw) ***/
        /******************************************************************/

        // Update "post" state to "pre" state
        pre_daiTotalSupply = dai.totalSupply();
        pre_vat_dai_vow    = vat.dai(VOW);
        pre_vatDai         = vat.dai(address(deposit));
        pre_gem            = vat.gem(ilk, address(deposit));
        pre_ink            = post_ink;
        pre_art            = post_art;
        pre_Art            = post_Art;

        // Trigger cooldown
        uint256 cooldownTimestamp = block.timestamp;
        assertEq(pool.withdrawCooldown(address(deposit)), 0);
        deposit.triggerCooldown();
        assertEq(pool.withdrawCooldown(address(deposit)), cooldownTimestamp);

        // Warp to one second before cooldown is finished
        hevm.warp(cooldownTimestamp + 10 days - 1 seconds);
        deposit.exec();
        assertEq(dai.totalSupply(), pre_daiTotalSupply);  // Demonstrate withdraw was not successful

        // Warp to one second after withdraw window is finished
        hevm.warp(cooldownTimestamp + 10 days + 48 hours + 1 seconds);
        deposit.exec();
        assertEq(dai.totalSupply(), pre_daiTotalSupply);  // Demonstrate withdraw was not successful

        // Warp to the moment the cooldown is over and do `exec()`
        hevm.warp(cooldownTimestamp + 10 days);
        deposit.exec();

        ( post_ink, post_art ) = vat.urns(ilk, address(deposit));
        ( post_Art,,,, )       = vat.ilks(ilk);

        assertEq(post_ink, 4_999_999_999999999999999999);  // TODO: Look into how to handle rounding issue
        assertEq(post_art, 4_999_999_999999999999999999);
        assertEq(post_Art, 4_999_999_999999999999999999);

        assertEq(vat.gem(ilk, address(deposit)), 0);
        assertEq(vat.dai(address(deposit)),      0);

        assertEq(dai.totalSupply(), pre_daiTotalSupply - 1);  // TODO: Investigate rounding
        assertEq(vat.dai(VOW),      pre_vat_dai_vow);
    }

    /************************/
    /*** Helper Functions ***/
    /************************/

    function _mintTokens(address token, address account, uint256 amount) internal {
        uint256 slot;

        if      (token == DAI)  slot = 2;
        else if (token == MPL)  slot = 0;
        else if (token == WBTC) slot = 0;

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
        pool = PoolLike(poolDelegate.createPool(POOL_FACTORY, DAI, address(bPool), SL_FACTORY, LL_FACTORY, 1000, 1000, 5_000_000 ether));

        // Stake BPT for insurance and finalize pool
        poolDelegate.approve(address(bPool), pool.stakeLocker(), type(uint256).max);
        poolDelegate.stake(pool.stakeLocker(), bPool.balanceOf(address(poolDelegate)));
        poolDelegate.finalize(address(pool));
    }

    function _createLoan(Borrower borrower, uint256[5] memory specs) internal returns (address loan) {
        return borrower.createLoan(LOAN_FACTORY, DAI, WBTC, FL_FACTORY, CL_FACTORY, specs, calcs);
    }

    function _fundLoanAndDrawdown(Borrower borrower, address loan, uint256 fundAmount) internal {
        poolDelegate.fundLoan(address(pool), loan, DL_FACTORY, fundAmount);

        uint256 collateralRequired = LoanLike(loan).collateralRequiredForDrawdown(fundAmount);

        if (collateralRequired > 0) {
            _mintTokens(WBTC, address(borrower), collateralRequired);
            borrower.approve(WBTC, loan, collateralRequired);
        }
        
        borrower.drawdown(loan, fundAmount);
    }

    function _makePayment(address loan, address borrower) internal {
        ( uint256 paymentAmount, , ) = LoanLike(loan).getNextPayment();
        _mintTokens(DAI, borrower, paymentAmount);
        Borrower(borrower).approve(DAI, loan, paymentAmount);
        Borrower(borrower).makePayment(loan);
    }

}

