// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.12;

import "ds-test/test.sol";
import "../tests/interfaces/interfaces.sol";

import { DssDirectDepositHub } from "../DssDirectDepositHub.sol";
import { D3MMom } from "../D3MMom.sol";
import { ValueStub } from "../tests/stubs/ValueStub.sol";

import { D3MAaveDaiPlan } from "../plans/D3MAaveDaiPlan.sol";
import { D3MAaveDaiPool } from "./D3MAaveDaiPool.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
    function load(address,bytes32) external view returns (bytes32);
}

interface LendingPoolLike {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external;
    function getReserveData(address asset) external view returns (
        uint256,    // Configuration
        uint128,    // the liquidity index. Expressed in ray
        uint128,    // variable borrow index. Expressed in ray
        uint128,    // the current supply rate. Expressed in ray
        uint128,    // the current variable borrow rate. Expressed in ray
        uint128,    // the current stable borrow rate. Expressed in ray
        uint40,
        address,    // address of the adai interest bearing token
        address,    // address of the stable debt token
        address,    // address of the variable debt token
        address,    // address of the interest rate strategy
        uint8
    );
}

interface InterestRateStrategyLike {
    function getMaxVariableBorrowRate() external view returns (uint256);
    function calculateInterestRates(
        address reserve,
        uint256 availableLiquidity,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 averageStableBorrowRate,
        uint256 reserveFactor
    ) external returns (
        uint256,
        uint256,
        uint256
    );
}

interface ATokenLike is TokenLike {
    function scaledBalanceOf(address) external view returns (uint256);
}

interface RewardsClaimerLike {
    function getRewardsBalance(address[] calldata assets, address user) external view returns (uint256);
}

contract D3MAaveDaiTest is DSTest {
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    Hevm hevm;

    VatLike vat;
    EndLike end;
    LendingPoolLike aavePool;
    InterestRateStrategyLike interestStrategy;
    RewardsClaimerLike rewardsClaimer;
    DaiLike dai;
    DaiJoinLike daiJoin;
    ATokenLike adai;
    TokenLike stkAave;
    SpotLike spot;
    TokenLike weth;
    address vow;
    address pauseProxy;

    bytes32 constant ilk = "DD-DAI-A";
    DssDirectDepositHub directDepositHub;
    D3MAaveDaiPool d3mAaveDaiPool;
    D3MAaveDaiPlan d3mAaveDaiPlan;
    D3MMom d3mMom;
    ValueStub pip;

    // Allow for a 1 BPS margin of error on interest rates
    uint256 constant INTEREST_RATE_TOLERANCE = RAY / 10000;
    uint256 constant EPSILON_TOLERANCE = 4;

    function setUp() public {
        hevm = Hevm(address(bytes20(uint160(uint256(keccak256('hevm cheat code'))))));

        vat = VatLike(0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B);
        end = EndLike(0xBB856d1742fD182a90239D7AE85706C2FE4e5922);
        aavePool = LendingPoolLike(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
        adai = ATokenLike(0x028171bCA77440897B824Ca71D1c56caC55b68A3);
        stkAave = TokenLike(0x4da27a545c0c5B758a6BA100e3a049001de870f5);
        dai = DaiLike(0x6B175474E89094C44Da98b954EedeAC495271d0F);
        daiJoin = DaiJoinLike(0x9759A6Ac90977b93B58547b4A71c78317f391A28);
        interestStrategy = InterestRateStrategyLike(0xfffE32106A68aA3eD39CcCE673B646423EEaB62a);
        rewardsClaimer = RewardsClaimerLike(0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5);
        spot = SpotLike(0x65C79fcB50Ca1594B025960e539eD7A9a6D434A3);
        weth = TokenLike(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        vow = 0xA950524441892A31ebddF91d3cEEFa04Bf454466;
        pauseProxy = 0xBE8E3e3618f7474F8cB1d074A26afFef007E98FB;

        // Force give admin access to these contracts via hevm magic
        _giveAuthAccess(address(vat), address(this));
        _giveAuthAccess(address(end), address(this));
        _giveAuthAccess(address(spot), address(this));

        directDepositHub = new DssDirectDepositHub(address(vat), address(daiJoin));
        d3mAaveDaiPool = new D3MAaveDaiPool(address(directDepositHub), address(dai), address(aavePool), address(rewardsClaimer));
        d3mAaveDaiPool.rely(address(directDepositHub));
        d3mAaveDaiPlan = new D3MAaveDaiPlan(address(dai), address(aavePool));

        directDepositHub.file(ilk, "pool", address(d3mAaveDaiPool));
        directDepositHub.file(ilk, "plan", address(d3mAaveDaiPlan));
        directDepositHub.file(ilk, "tau", 7 days);

        directDepositHub.file("vow", vow);
        directDepositHub.file("end", address(end));

        // d3mAaveDaiPool.rely(address(directDepositHub));

        d3mMom = new D3MMom();
        d3mAaveDaiPlan.rely(address(d3mMom));

        // Init new collateral
        pip = new ValueStub();
        pip.poke(bytes32(WAD));
        spot.file(ilk, "pip", address(pip));
        spot.file(ilk, "mat", RAY);
        spot.poke(ilk);

        vat.rely(address(directDepositHub));
        vat.init(ilk);
        vat.file(ilk, "line", 5_000_000_000 * RAD);
        vat.file("Line", vat.Line() + 5_000_000_000 * RAD);

        // Give us a bunch of WETH and deposit into Aave
        uint256 amt = 1_000_000 * WAD;
        _giveTokens(weth, amt);
        weth.approve(address(aavePool), uint256(-1));
        dai.approve(address(aavePool), uint256(-1));
        aavePool.deposit(address(weth), amt, address(this), 0);
    }

    // --- Math ---
    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }

    function _giveAuthAccess(address _base, address target) internal {
        AuthLike base = AuthLike(_base);

        // Edge case - ward is already set
        if (base.wards(target) == 1) return;

        for (int i = 0; i < 100; i++) {
            // Scan the storage for the ward storage slot
            bytes32 prevValue = hevm.load(
                address(base),
                keccak256(abi.encode(target, uint256(i)))
            );
            hevm.store(
                address(base),
                keccak256(abi.encode(target, uint256(i))),
                bytes32(uint256(1))
            );
            if (base.wards(target) == 1) {
                // Found it
                return;
            } else {
                // Keep going after restoring the original value
                hevm.store(
                    address(base),
                    keccak256(abi.encode(target, uint256(i))),
                    prevValue
                );
            }
        }

        // We have failed if we reach here
        assertTrue(false);
    }

    function _giveTokens(TokenLike token, uint256 amount) internal {
        // Edge case - balance is already set for some reason
        if (token.balanceOf(address(this)) == amount) return;

        for (int i = 0; i < 100; i++) {
            // Scan the storage for the balance storage slot
            bytes32 prevValue = hevm.load(
                address(token),
                keccak256(abi.encode(address(this), uint256(i)))
            );
            hevm.store(
                address(token),
                keccak256(abi.encode(address(this), uint256(i))),
                bytes32(amount)
            );
            if (token.balanceOf(address(this)) == amount) {
                // Found it
                return;
            } else {
                // Keep going after restoring the original value
                hevm.store(
                    address(token),
                    keccak256(abi.encode(address(this), uint256(i))),
                    prevValue
                );
            }
        }

        // We have failed if we reach here
        assertTrue(false);
    }

    function assertEqApprox(uint256 _a, uint256 _b, uint256 _tolerance) internal {
        uint256 a = _a;
        uint256 b = _b;
        if (a < b) {
            uint256 tmp = a;
            a = b;
            b = tmp;
        }
        if (a - b > _tolerance) {
            emit log_bytes32("Error: Wrong `uint' value");
            emit log_named_uint("  Expected", _b);
            emit log_named_uint("    Actual", _a);
            fail();
        }
    }

    function assertEqInterest(uint256 _a, uint256 _b) internal {
        uint256 a = _a;
        uint256 b = _b;
        if (a < b) {
            uint256 tmp = a;
            a = b;
            b = tmp;
        }
        if (a - b > INTEREST_RATE_TOLERANCE) {
            emit log_bytes32("Error: Wrong `uint' value");
            emit log_named_decimal_uint("  Expected", _b, 27);
            emit log_named_decimal_uint("    Actual", _a, 27);
            fail();
        }
    }

    // aTOKENs round against the depositor - we allow a rounding error of 1
    function assertEqRoundingAgainst(uint256 _a, uint256 _b) internal {
        uint256 a = _a;
        uint256 b = _b;
        if (a < b) {
            uint256 tmp = a;
            a = b;
            b = tmp;
        }
        if (a - b > 1) {
            emit log_bytes32("Error: Wrong `uint' value");
            emit log_named_decimal_uint("  Expected", _b, 27);
            emit log_named_decimal_uint("    Actual", _a, 27);
            fail();
        }
    }

    function getBorrowRate() public view returns (uint256 borrowRate) {
        (,,,, borrowRate,,,,,,,) = aavePool.getReserveData(address(dai));
    }

    // Set the borrow rate to a relative percent to what it currently is
    function _setRelBorrowTarget(uint256 deltaBPS) internal returns (uint256 targetBorrowRate) {
        targetBorrowRate = getBorrowRate() * deltaBPS / 10000;
        d3mAaveDaiPlan.file("bar", targetBorrowRate);
        directDepositHub.exec(ilk);
    }

    function test_target_decrease() public {
        uint256 targetBorrowRate = _setRelBorrowTarget(7500);
        directDepositHub.reap(ilk);     // Clear out interest to get rid of rounding errors
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        uint256 amountMinted = adai.balanceOf(address(d3mAaveDaiPool));
        assertTrue(amountMinted > 0);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEqRoundingAgainst(ink, amountMinted);    // We allow a rounding error of 1 because aTOKENs round against the user
        assertEqRoundingAgainst(art, amountMinted);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
        assertEq(vat.dai(address(directDepositHub)), 0);
    }

    function test_target_increase() public {
        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        // Raise by 25%
        targetBorrowRate = _setRelBorrowTarget(12500);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        uint256 amountMinted = adai.balanceOf(address(d3mAaveDaiPool));
        assertTrue(amountMinted > 0);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEqRoundingAgainst(ink, amountMinted);    // We allow a rounding error of 1 because aTOKENs round against the user
        assertEqRoundingAgainst(art, amountMinted);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
        assertEq(vat.dai(address(d3mAaveDaiPool)), 0);
    }

    function test_bar_zero() public {
        uint256 targetBorrowRate = _setRelBorrowTarget(7500);
        directDepositHub.reap(ilk);     // Clear out interest to get rid of rounding errors
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(ink, 0);
        assertGt(art, 0);

        // Temporarily disable the module
        d3mAaveDaiPlan.file("bar", 0);
        directDepositHub.exec(ilk);

        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
    }

    function test_target_increase_insufficient_liquidity() public {
        uint256 currBorrowRate = getBorrowRate();

        // Attempt to increase by 25% (you can't)
        _setRelBorrowTarget(12500);
        assertEqInterest(getBorrowRate(), currBorrowRate);  // Unchanged

        assertEq(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
        assertEq(vat.dai(address(directDepositHub)), 0);
    }

    function test_cage_temp_insufficient_liquidity() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // Cage the system and start unwinding
        currentLiquidity = dai.balanceOf(address(adai));
        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        directDepositHub.cage(ilk);
        directDepositHub.exec(ilk);

        // Should be no dai liquidity remaining as we attempt to fully unwind
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertTrue(ink > 0);
        assertTrue(art > 0);
        assertEq(pink - ink, currentLiquidity);
        assertEq(part - art, currentLiquidity);
        assertEq(dai.balanceOf(address(adai)), 0);
        assertEq(getBorrowRate(), interestStrategy.getMaxVariableBorrowRate());

        // Someone else repays some Dai so we can unwind the rest
        hevm.warp(block.timestamp + 1 days);
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));

        directDepositHub.exec(ilk);
        assertEq(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        assertTrue(dai.balanceOf(address(adai)) > 0);
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
    }

    function test_cage_perm_insufficient_liquidity() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // Cage the system and start unwinding
        currentLiquidity = dai.balanceOf(address(adai));
        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        directDepositHub.cage(ilk);
        directDepositHub.exec(ilk);

        // Should be no dai liquidity remaining as we attempt to fully unwind
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertTrue(ink > 0);
        assertTrue(art > 0);
        assertEq(pink - ink, currentLiquidity);
        assertEq(part - art, currentLiquidity);
        assertEq(dai.balanceOf(address(adai)), 0);
        assertEq(getBorrowRate(), interestStrategy.getMaxVariableBorrowRate());

        // In this case nobody deposits more DAI so we have to write off the bad debt
        hevm.warp(block.timestamp + 7 days);

        uint256 sin = vat.sin(vow);
        uint256 vowDai = vat.dai(vow);
        directDepositHub.cull(ilk);
        (uint256 ink2, uint256 art2) = vat.urns(ilk, address(d3mAaveDaiPool));
        (, , , uint256 culled, ) = directDepositHub.ilks(ilk);
        assertEq(culled, 1);
        assertEq(ink2, 0);
        assertEq(art2, 0);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), ink);
        assertEq(vat.sin(vow), sin + art * RAY);
        assertEq(vat.dai(vow), vowDai);

        // Some time later the pool gets some liquidity
        hevm.warp(block.timestamp + 180 days);
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));

        // Close out the remainder of the position
        uint256 adaiBalance = adai.balanceOf(address(d3mAaveDaiPool));
        assertTrue(adaiBalance >= art);
        directDepositHub.exec(ilk);
        assertEq(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        assertTrue(dai.balanceOf(address(adai)) > 0);
        assertEq(vat.sin(vow), sin + art * RAY);
        assertEq(vat.dai(vow), vowDai + adaiBalance * RAY);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
    }

    function test_hit_debt_ceiling() public {
        // Lower the debt ceiling to 100k
        uint256 debtCeiling = 100_000 * WAD;
        vat.file(ilk, "line", debtCeiling * RAY);

        uint256 currBorrowRate = getBorrowRate();

        // Set a super low target interest rate
        uint256 targetBorrowRate = _setRelBorrowTarget(1);
        directDepositHub.reap(ilk);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, debtCeiling);
        assertEq(art, debtCeiling);
        assertTrue(getBorrowRate() > targetBorrowRate && getBorrowRate() < currBorrowRate);
        assertEqRoundingAgainst(adai.balanceOf(address(d3mAaveDaiPool)), debtCeiling);    // We allow a rounding error of 1 because aTOKENs round against the user

        // Should be a no-op
        directDepositHub.exec(ilk);
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, debtCeiling);
        assertEq(art, debtCeiling);
        assertEqRoundingAgainst(adai.balanceOf(address(d3mAaveDaiPool)), debtCeiling);

        // Raise it by a bit
        currBorrowRate = getBorrowRate();
        debtCeiling = 125_000 * WAD;
        vat.file(ilk, "line", debtCeiling * RAY);
        directDepositHub.exec(ilk);
        directDepositHub.reap(ilk);
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, debtCeiling);
        assertEq(art, debtCeiling);
        assertTrue(getBorrowRate() > targetBorrowRate && getBorrowRate() < currBorrowRate);
        assertEqRoundingAgainst(adai.balanceOf(address(d3mAaveDaiPool)), debtCeiling);    // We allow a rounding error of 1 because aTOKENs round against the user
    }

    function test_collect_interest() public {
        _setRelBorrowTarget(7500);

        hevm.warp(block.timestamp + 1 days);     // Collect one day of interest

        uint256 vowDai = vat.dai(vow);
        directDepositHub.reap(ilk);

        log_named_decimal_uint("dai", vat.dai(vow) - vowDai, 18);

        assertGt(vat.dai(vow) - vowDai, 0);
    }

    function test_insufficient_liquidity_for_unwind_fees() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));
        uint256 vowDai = vat.dai(vow);

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        // Someone else borrows the exact amount previously available
        (uint256 amountSupplied,) = vat.urns(ilk, address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // Accumulate a bunch of interest
        hevm.warp(block.timestamp + 180 days);
        uint256 feesAccrued = adai.balanceOf(address(d3mAaveDaiPool)) - amountSupplied;
        currentLiquidity = dai.balanceOf(address(adai));
        assertGt(feesAccrued, 0);
        assertEq(amountSupplied, currentLiquidity);
        assertGt(amountSupplied + feesAccrued, currentLiquidity);

        // Cage the system to trigger only unwinds
        directDepositHub.cage(ilk);
        directDepositHub.exec(ilk);

        // The full debt should be paid off, but we are still owed fees
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertGt(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        assertEq(vat.dai(vow), vowDai);

        // Someone repays
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));
        directDepositHub.exec(ilk);

        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        assertEqApprox(vat.dai(vow), vowDai + feesAccrued * RAY, RAY);
    }

    function test_insufficient_liquidity_for_reap_fees() public {
        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        // Accumulate a bunch of interest
        hevm.warp(block.timestamp + 180 days);

        // Someone else borrows almost all the liquidity
        aavePool.borrow(address(dai), dai.balanceOf(address(adai)) - 100 * WAD, 2, 0, address(this));

        // Reap the partial fees
        uint256 vowDai = vat.dai(vow);
        directDepositHub.reap(ilk);
        assertEq(vat.dai(vow), vowDai + 100 * RAD);
    }

    function test_unwind_mcd_caged_not_skimmed() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(pink, 0);
        assertGt(part, 0);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // MCD shutdowns
        end.cage();
        end.cage(ilk);

        // CDP still has the position built
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(ink, 0);
        assertGt(art, 0);
        assertEq(vat.gem(ilk, address(end)), 0);

        uint256 prevSin = vat.sin(vow);
        uint256 prevDai = vat.dai(vow);
        assertEq(prevSin, 0);
        assertGt(prevDai, 0);

        // We try to unwind what is possible
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));

        // exec() moved the remaining urn debt to the end
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(vat.gem(ilk, address(end)), amountSupplied / 2); // Automatically skimmed when unwinding
        if (prevSin + (amountSupplied / 2) * RAY >= prevDai) {
            assertEqApprox(vat.sin(vow), prevSin + (amountSupplied / 2) * RAY - prevDai, RAY);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEqApprox(vat.dai(vow), prevDai - prevSin - (amountSupplied / 2) * RAY, RAY);
            assertEq(vat.sin(vow), 0);
        }

        // Some time later the pool gets some liquidity
        hevm.warp(block.timestamp + 180 days);
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));

        // Rest of the liquidity can be withdrawn
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));
        assertEq(vat.gem(ilk, address(end)), 0);
        assertEq(vat.sin(vow), 0);
        assertGe(vat.dai(vow), prevDai); // As also probably accrues interest from aDai
    }

    function test_unwind_mcd_caged_skimmed() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(pink, 0);
        assertGt(part, 0);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // MCD shutdowns
        end.cage();
        end.cage(ilk);

        // CDP still has the position built
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(ink, 0);
        assertGt(art, 0);
        assertEq(vat.gem(ilk, address(end)), 0);

        uint256 prevSin = vat.sin(vow);
        uint256 prevDai = vat.dai(vow);
        assertEq(prevSin, 0);
        assertGt(prevDai, 0);

        // Position is taken by the End module
        end.skim(ilk, address(d3mAaveDaiPool));
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(vat.gem(ilk, address(end)), pink);
        if (prevSin + amountSupplied * RAY >= prevDai) {
            assertEqApprox(vat.sin(vow), prevSin + amountSupplied * RAY - prevDai, RAY);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEqApprox(vat.dai(vow), prevDai - prevSin - amountSupplied * RAY, RAY);
            assertEq(vat.sin(vow), 0);
        }

        // We try to unwind what is possible
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));

        // Part can't be done yet
        assertEq(vat.gem(ilk, address(end)), amountSupplied / 2);
        if (prevSin + (amountSupplied / 2) * RAY >= prevDai) {
            assertEqApprox(vat.sin(vow), prevSin + (amountSupplied / 2) * RAY - prevDai, RAY);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEqApprox(vat.dai(vow), prevDai - prevSin - (amountSupplied / 2) * RAY, RAY);
            assertEq(vat.sin(vow), 0);
        }

        // Some time later the pool gets some liquidity
        hevm.warp(block.timestamp + 180 days);
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));

        // Rest of the liquidity can be withdrawn
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));
        assertEq(vat.gem(ilk, address(end)), 0);
        assertEq(vat.sin(vow), 0);
        assertGe(vat.dai(vow), prevDai); // As also probably accrues interest from aDai
    }

    function testFail_unwind_mcd_caged_wait_done() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(pink, 0);
        assertGt(part, 0);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        // MCD shutdowns
        end.cage();
        end.cage(ilk);

        hevm.warp(block.timestamp + end.wait());

        // Force remove all the dai from vow so it can call end.thaw()
        hevm.store(
            address(vat),
            keccak256(abi.encode(address(vow), uint256(5))),
            bytes32(0)
        );

        end.thaw();

        // Unwind via exec should fail with error "D3MAaveDai/end-debt-already-set"
        directDepositHub.exec(ilk);
    }

    function test_unwind_culled_then_mcd_caged() public {
        uint256 currentLiquidity = dai.balanceOf(address(adai));

        // Lower by 50%
        uint256 targetBorrowRate = _setRelBorrowTarget(5000);
        assertEqInterest(getBorrowRate(), targetBorrowRate);

        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(pink, 0);
        assertGt(part, 0);

        // Someone else borrows
        uint256 amountSupplied = adai.balanceOf(address(d3mAaveDaiPool));
        uint256 amountToBorrow = currentLiquidity + amountSupplied / 2;
        aavePool.borrow(address(dai), amountToBorrow, 2, 0, address(this));

        directDepositHub.cage(ilk);

        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);

        hevm.warp(block.timestamp + tau);

        uint256 daiEarned = adai.balanceOf(address(d3mAaveDaiPool)) - pink;

        VowLike(vow).heal(
            _min(
                vat.sin(vow) - VowLike(vow).Sin() - VowLike(vow).Ash(),
                vat.dai(vow)
            )
        );
        uint256 originalSin = vat.sin(vow);
        uint256 originalDai = vat.dai(vow);
        // If the whole Sin queue would be cleant by someone,
        // originalSin should be 0 as there is more profit than debt registered
        assertGt(originalDai, originalSin);
        assertGt(originalSin, 0);

        directDepositHub.cull(ilk);

        // After cull, the debt of the position is converted to bad debt
        assertEq(vat.sin(vow), originalSin + part * RAY);

        // CDP grabbed and ink moved as free collateral to the deposit contract
        (uint256 ink, uint256 art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), pink);
        assertGe(adai.balanceOf(address(d3mAaveDaiPool)), pink);

        // MCD shutdowns
        originalDai = originalDai + vat.dai(VowLike(vow).flapper());
        end.cage();
        end.cage(ilk);

        if (originalSin + part * RAY >= originalDai) {
            assertEq(vat.sin(vow), originalSin + part * RAY - originalDai);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEq(vat.dai(vow), originalDai - originalSin - part * RAY);
            assertEq(vat.sin(vow), 0);
        }

        directDepositHub.uncull(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));

        // So the position is restablished
        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, pink);
        assertEq(art, part);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
        assertGe(adai.balanceOf(address(d3mAaveDaiPool)), pink);
        assertEq(vat.sin(vow), 0);

        // Call skim manually (will be done through deposit anyway)
        // Position is again taken but this time the collateral goes to the End module
        end.skim(ilk, address(d3mAaveDaiPool));
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));

        (ink, art) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
        assertEq(art, 0);
        assertEq(vat.gem(ilk, address(d3mAaveDaiPool)), 0);
        assertEq(vat.gem(ilk, address(end)), pink);
        assertGe(adai.balanceOf(address(d3mAaveDaiPool)), pink);
        if (originalSin + part * RAY >= originalDai) {
            assertEqApprox(vat.sin(vow), originalSin + part * RAY - originalDai, RAY);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEqApprox(vat.dai(vow), originalDai - originalSin - part * RAY, RAY);
            assertEq(vat.sin(vow), 0);
        }

        // We try to unwind what is possible
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));

        // A part can't be unwind yet
        assertEq(vat.gem(ilk, address(end)), amountSupplied / 2);
        assertGt(adai.balanceOf(address(d3mAaveDaiPool)), amountSupplied / 2);
        if (originalSin + part * RAY >= originalDai + (amountSupplied / 2) * RAY) {
            assertEqApprox(vat.sin(vow), originalSin + part * RAY - originalDai - (amountSupplied / 2) * RAY, RAY);
            assertEq(vat.dai(vow), 0);
        } else {
            assertEqApprox(vat.dai(vow), originalDai + (amountSupplied / 2) * RAY - originalSin - part * RAY, RAY);
            assertEq(vat.sin(vow), 0);
        }

        // Then pool gets some liquidity
        aavePool.repay(address(dai), amountToBorrow, 2, address(this));

        // Rest of the liquidity can be withdrawn
        directDepositHub.exec(ilk);
        VowLike(vow).heal(_min(vat.sin(vow), vat.dai(vow)));
        assertEq(vat.gem(ilk, address(end)), 0);
        assertEq(adai.balanceOf(address(d3mAaveDaiPool)), 0);
        assertEq(vat.sin(vow), 0);
        assertEqApprox(vat.dai(vow), originalDai - originalSin + daiEarned * RAY, RAY);
    }

    function testFail_uncull_not_culled() public {
        // Lower by 50%
        _setRelBorrowTarget(5000);
        directDepositHub.cage(ilk);

        // MCD shutdowns
        end.cage();
        end.cage(ilk);

        // uncull should fail with error "D3MAaveDai/not-prev-culled"
        directDepositHub.uncull(ilk);
    }

    function testFail_uncull_not_shutdown() public {
        // Lower by 50%
        _setRelBorrowTarget(5000);
        directDepositHub.cage(ilk);

        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);
        hevm.warp(block.timestamp + tau);

        directDepositHub.cull(ilk);

        // uncull should fail with error "D3MAaveDai/no-uncull-normal-operation"
        directDepositHub.uncull(ilk);
    }

    function test_collect_stkaave() public {
        _setRelBorrowTarget(7500);

        hevm.warp(block.timestamp + 1 days);

        // Set the king
        d3mAaveDaiPool.file("king", address(pauseProxy));

        // Collect some stake rewards into the pause proxy
        address[] memory tokens = new address[](1);
        tokens[0] = address(adai);
        uint256 amountToClaim = rewardsClaimer.getRewardsBalance(tokens, address(directDepositHub));
        if (amountToClaim == 0) return;     // Rewards are turned off - this is still an acceptable state
        uint256 amountClaimed = d3mAaveDaiPool.collect();
        assertEq(amountClaimed, amountToClaim);
        assertEq(stkAave.balanceOf(address(pauseProxy)), amountClaimed);
        assertEq(rewardsClaimer.getRewardsBalance(tokens, address(directDepositHub)), 0);

        hevm.warp(block.timestamp + 1 days);

        // Collect some more rewards
        uint256 amountToClaim2 = rewardsClaimer.getRewardsBalance(tokens, address(directDepositHub));
        assertGt(amountToClaim2, 0);
        uint256 amountClaimed2 = d3mAaveDaiPool.collect();
        assertEq(amountClaimed2, amountToClaim2);
        assertEq(stkAave.balanceOf(address(pauseProxy)), amountClaimed + amountClaimed2);
        assertEq(rewardsClaimer.getRewardsBalance(tokens, address(directDepositHub)), 0);
    }

    function testFail_collect_stkaave_king_not_set() public {
        _setRelBorrowTarget(7500);

        hevm.warp(block.timestamp + 1 days);

        // Collect some stake rewards into the pause proxy
        address[] memory tokens = new address[](1);
        tokens[0] = address(adai);
        uint256 amountToClaim = rewardsClaimer.getRewardsBalance(tokens, address(d3mAaveDaiPool));
        assertGt(amountToClaim, 0);
        d3mAaveDaiPool.collect();
    }

    function test_cage_exit() public {
        _setRelBorrowTarget(7500);

        // Vat is caged for global settlement
        vat.cage();

        // Simulate DAI holder gets some gems from GS
        vat.grab(ilk, address(d3mAaveDaiPool), address(this), address(this), -int256(100 ether), -int256(0));

        // User can exit and get the aDAI
        directDepositHub.exit(ilk, address(this), 100 ether);
        assertEqApprox(adai.balanceOf(address(this)), 100 ether, 1);     // Slight rounding error may occur
    }


    function testFail_shutdown_cant_cull() public {
        _setRelBorrowTarget(7500);

        directDepositHub.cage(ilk);

        // Vat is caged for global settlement
        vat.cage();

        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);
        hevm.warp(block.timestamp + tau);

        directDepositHub.cull(ilk);
    }

    function test_quit_no_cull() public {
        _setRelBorrowTarget(7500);

        directDepositHub.cage(ilk);

        // Test that we can extract the whole position in emergency situations
        // aDAI should be sitting in the deposit contract, urn should be owned by deposit contract
        (uint256 pink, uint256 part) = vat.urns(ilk, address(d3mAaveDaiPool));
        uint256 pbal = adai.balanceOf(address(d3mAaveDaiPool));
        assertGt(pink, 0);
        assertGt(part, 0);
        assertGt(pbal, 0);

        vat.hope(address(directDepositHub));     // Need to approve urn transfer
        directDepositHub.quit(ilk, address(this));

        (uint256 nink, uint256 nart) = vat.urns(ilk, address(d3mAaveDaiPool));
        uint256 nbal = adai.balanceOf(address(d3mAaveDaiPool));
        assertEq(nink, 0);
        assertEq(nart, 0);
        assertEq(nbal, 0);

        (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
        uint256 bal = adai.balanceOf(address(this));
        assertEq(ink, pink);
        assertEq(art, part);
        assertEq(bal, pbal);
    }

    function test_quit_cull() public {
        _setRelBorrowTarget(7500);

        directDepositHub.cage(ilk);

        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);
        hevm.warp(block.timestamp + tau);

        directDepositHub.cull(ilk);

        // Test that we can extract the adai in emergency situations
        // aDAI should be sitting in the deposit contract, gems should be owned by deposit contract
        uint256 pgem = vat.gem(ilk, address(d3mAaveDaiPool));
        uint256 pbal = adai.balanceOf(address(d3mAaveDaiPool));
        assertGt(pgem, 0);
        assertGt(pbal, 0);

        directDepositHub.quit(ilk, address(this));

        uint256 ngem = vat.gem(ilk, address(d3mAaveDaiPool));
        uint256 nbal = adai.balanceOf(address(d3mAaveDaiPool));
        assertEq(ngem, 0);
        assertEq(nbal, 0);

        uint256 gem = vat.gem(ilk, address(this));
        uint256 bal = adai.balanceOf(address(this));
        assertEq(gem, 0);
        assertEq(bal, pbal);
    }

    function testFail_quit_mcd_caged() public {
        _setRelBorrowTarget(7500);

        vat.cage();

        directDepositHub.quit(ilk, address(this));
    }

    function testFail_reap_caged() public {
        _setRelBorrowTarget(7500);

        directDepositHub.cage(ilk);

        hevm.warp(block.timestamp + 1 days);    // Accrue some interest

        // reap should fail with error "D3MAaveDai/no-reap-during-cage"
        directDepositHub.reap(ilk);
    }

    function test_direct_deposit_mom() public {
        _setRelBorrowTarget(7500);

        (uint256 ink, ) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertGt(ink, 0);
        assertGt(d3mAaveDaiPlan.bar(), 0);

        // Something bad happens on Aave - we need to bypass gov delay
        d3mMom.disable(address(d3mAaveDaiPlan));

        assertEq(d3mAaveDaiPlan.bar(), 0);

        // Close out our position
        directDepositHub.exec(ilk);

        (ink, ) = vat.urns(ilk, address(d3mAaveDaiPool));
        assertEq(ink, 0);
    }

    function test_set_tau_not_caged() public {
        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);
        assertEq(tau, 7 days);
        directDepositHub.file(ilk, "tau", 1 days);
        (, , tau, , ) = directDepositHub.ilks(ilk);
        assertEq(tau, 1 days);
    }

    function testFail_set_tau_caged() public {
        (, , uint256 tau, , ) = directDepositHub.ilks(ilk);
        assertEq(tau, 7 days);

        directDepositHub.cage(ilk);

        // file should fail with error "D3MAaveDai/live"
        directDepositHub.file(ilk, "tau", 1 days);
    }

    // Make sure the module works correctly even when someone permissionlessly repays the urn
    function test_permissionless_repay() public {
        _setRelBorrowTarget(7500);

        // Permissionlessly repay the urn
        _giveTokens(dai, 100);
        dai.approve(address(daiJoin), 100);
        daiJoin.join(address(this), 100);
        vat.frob(ilk, address(address(d3mAaveDaiPool)), address(this), address(this), 0, -100); // Some small amount of dai repaid

        // We should be able to close out the vault completely even though ink and art do not match
        _setRelBorrowTarget(0);
    }
}
