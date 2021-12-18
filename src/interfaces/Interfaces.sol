// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface AuthLike {
    function wards(address) external returns (uint256);
}

interface BPoolFactoryLike {
    function newBPool() external returns (address);
}

interface BPoolLike {
    function balanceOf(address) external view returns (uint256);
    function bind(address, uint256, uint256) external;
    function finalize() external;
    function getSpotPrice(address, address) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
    function load(address,bytes32) external view returns (bytes32);
}

interface MapleGlobalsLike {
    function setLiquidityAsset(address, bool) external;
    function setPoolDelegateAllowlist(address, bool) external;
    function setPriceOracle(address, address) external;
    function setValidBalancerPool(address, bool) external;
}

interface PoolFactoryLike {
    function createPool(address, address, address, address, uint256, uint256, uint256) external returns (address);
}

interface PoolLike {
    function getInitialStakeRequirements() external view returns (uint256, uint256, bool, uint256, uint256);
    function getPoolSharesRequired(address, address, address, address, uint256) external view returns(uint256, uint256);
    function finalize() external;
    function stakeLocker() external returns (address);
}

interface StakeLockerLike {
    function stake(uint256) external;
}