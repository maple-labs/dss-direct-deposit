// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.6.12;

import { ERC20Like, MaplePoolFactoryLike, MaplePoolLike, StakeLockerLike } from "../interfaces/interfaces.sol";

contract PoolDelegate {

    function approve(address token, address account, uint256 amt) external {
        ERC20Like(token).approve(account, amt);
    }

    function claim(address pool, address loan, address dlFactory) external returns (uint256[7] memory) {
        return MaplePoolLike(pool).claim(loan, dlFactory);
    }

    function createPool(
        address poolFactory,
        address liquidityAsset,
        address stakeAsset,
        address slFactory,
        address llFactory,
        uint256 stakingFee,
        uint256 delegateFee,
        uint256 liquidityCap
    )
        external returns (address liquidityPool)
    {
        liquidityPool = MaplePoolFactoryLike(poolFactory).createPool(
            liquidityAsset,
            stakeAsset,
            slFactory,
            llFactory,
            stakingFee,
            delegateFee,
            liquidityCap
        );
    }

    function finalize(address pool) external {
        MaplePoolLike(pool).finalize();
    }

    function fundLoan(address pool, address loan, address dlFactory, uint256 amt) external {
        MaplePoolLike(pool).fundLoan(loan, dlFactory, amt);
    }

    function setAllowList(address pool, address account, bool status) external {
        MaplePoolLike(pool).setAllowList(account, status);
    }

    function stake(address stakeLocker, uint256 amt) external {
        StakeLockerLike(stakeLocker).stake(amt);
    }

}