// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { ERC20Like, PoolFactoryLike, PoolLike, StakeLockerLike } from "../interfaces/Interfaces.sol";

contract PoolDelegate {

    /************************/
    /*** Direct Functions ***/
    /************************/

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
        liquidityPool = PoolFactoryLike(poolFactory).createPool(
            liquidityAsset,
            stakeAsset,
            slFactory,
            llFactory,
            stakingFee,
            delegateFee,
            liquidityCap
        );
    }

    function approve(address token, address account, uint256 amt) external {
        ERC20Like(token).approve(account, amt);
    }

    function stake(address stakeLocker, uint256 amt) external {
        StakeLockerLike(stakeLocker).stake(amt);
    }

    function finalize(address pool) external {
        PoolLike(pool).finalize();
    }
    
}
