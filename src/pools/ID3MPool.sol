// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021-2022 Dai Foundation
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

/**
    @title D3M Pool Interface
    @notice Pool contracts are contracts that the Hub uses to standardize
    interactions with external Pools.
    @dev Implementing contracts will hold any balance provided by the external
    pool as well as the balance in the Vat. This interface aims to use EIP-4626
    guidelines for assets/shares/maxWithdraw etc.
*/
interface ID3MPool {
    /**
        @notice Deposit assets (Dai) in the external pool.
        @dev If the external pool requires a different amount to be passed in, the
        conversion should occur here as the Hub passes Dai [wad] amounts.
        msg.sender must be authorized.
        @param amt amount in asset (Dai) terms that we want to deposit
    */
    function deposit(uint256 amt) external;

    /**
        @notice Withdraw assets (Dai) from the external pool.
        @dev If the external pool requires a different amount to be passed in
        the conversion should occur here as the Hub passes Dai [wad] amounts.
        msg.sender must be authorized.
        @param amt amount in asset (Dai) terms that we want to withdraw
    */
    function withdraw(uint256 amt) external;

     /**
        @notice Transfer shares.
        @dev If the external pool/shares contract requires a different amount to be
        passed in the conversion should occur here as the Hub passes Gem [wad]
        amounts. msg.sender must be authorized.
        @param dst address that should receive the shares
        @param amt amount in Gem terms that we want to withdraw
        @return bool whether the transfer was successful per ERC-20 standard
    */
    function transfer(address dst, uint256 amt) external returns (bool);

    /**
        @notice Transfer all shares from this pool.
        @dev msg.sender must be authorized.
        @param dst address that should receive the shares.
        @return bool whether the transfer was successful per ERC-20 standard
    */
    function transferAll(address dst) external returns (bool);

    /// @notice Some external pools require manually accruing fees/interest
    function accrueIfNeeded() external;

    /**
        @notice Balance of assets this pool "owns".
        @dev This could be greater than the amount the pool can withdraw due to
        lack of liquidity.
        @return uint256 number of assets in Dai [wad]
    */
    function assetBalance() external view returns (uint256);

    /**
        @notice Maximum number of assets the pool could deposit at present.
        @return uint256 number of assets in Dai [wad]
    */
    function maxDeposit() external view returns (uint256);

    /**
        @notice Maximum number of assets the pool could withdraw at present.
        @return uint256 number of assets in Dai [wad]
    */
    function maxWithdraw() external view returns (uint256);

    /**
        @notice Used to recover any ERC-20 accidentally sent to the pool.
        --- YOU SHOULD NOT SEND ERC-20 DIRECTLY TO THIS CONTRACT ---
        The presence of this function does not convey any right to recover tokens
        sent to this contract. Maker Governance must evaluate and perform this
        action at its sole discretion.
        @dev msg.sender must be authorized.
        @param token address of the ERC-20 token that will be transferred
        @param dst address that should receive the shares
        @param amt amount in Gem terms that we want to withdraw
        @return bool whether the transfer was successful per ERC-20 standard
    */
    function recoverTokens(address token, address dst, uint256 amt) external returns (bool);

    /// @notice Reports whether the plan is active
    function active() external view returns (bool);
}
