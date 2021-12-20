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

pragma solidity 0.8.7;

interface TokenLike {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function scaledBalanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface DaiJoinLike {
    function wards(address) external view returns (uint256);
    function rely(address usr) external;
    function deny(address usr) external;
    function vat() external view returns (address);
    function dai() external view returns (address);
    function live() external view returns (uint256);
    function cage() external;
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

interface VatLike {
    function hope(address) external;
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function gem(bytes32, address) external view returns (uint256);
    function live() external view returns (uint256);
    function slip(bytes32, address, int256) external;
    function move(address, address, uint256) external;
    function frob(bytes32, address, address, address, int256, int256) external;
    function grab(bytes32, address, address, address, int256, int256) external;
    function fork(bytes32, address, address, int256, int256) external;
    function suck(address, address, uint256) external;
}

interface EndLike {
    function debt() external view returns (uint256);
    function skim(bytes32, address) external;
}

interface PoolFactoryLike {
    function globals() external view returns (address);
}

interface PoolLike is TokenLike {
    function deposit(uint256 amount) external;
    function intendToWithdraw() external;
    function liquidityCap() external view returns (uint256);
    function liquidityLocker() external view returns (address);
    function principalOut() external view returns (uint256);
    function superFactory() external view returns (address);
    function withdraw(uint256) external;
    function withdrawCooldown(address) external view returns (uint256);
    function withdrawFunds() external;
    function withdrawableFundsOf(address) external view returns (uint256);
}

interface MapleGlobalsLike {
    function getLpCooldownParams() external view returns (uint256, uint256);
}

contract DssDirectDepositMaple {

    /*****************************************/
    /*** Immutable Variables and Constants ***/
    /*****************************************/

    uint256 constant internal RAY = 10 ** 27;

    bytes32 public immutable ilk;

    ChainlogLike public immutable chainlog;
    DaiJoinLike  public immutable daiJoin;
    PoolLike     public immutable pool;
    TokenLike    public immutable dai;
    TokenLike    public immutable gem;
    VatLike      public immutable vat;

    /***********************/
    /*** State Variables ***/
    /***********************/

    uint256 public tau;       // Time until you can write off the debt [sec]
    uint256 public bar;       // Target Interest Rate [ray]
    uint256 public live = 1;
    uint256 public culled;
    uint256 public tic;       // Timestamp when the system is caged
    address public king;      // Who gets the rewards

    enum Mode { NORMAL, MODULE_CULLED, MCD_CAGED }

    /**************/
    /*** Events ***/
    /**************/

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 data);
    event Wind(uint256 amount);
    event Unwind(uint256 amount);
    event Reap();
    event Cage();
    event Cull();
    event Uncull();

    /************/
    /*** Init ***/
    /************/

    constructor(address chainlog_, bytes32 ilk_, address pool_) {
        address vat_     = ChainlogLike(chainlog_).getAddress("MCD_VAT");
        address daiJoin_ = ChainlogLike(chainlog_).getAddress("MCD_JOIN_DAI");
        TokenLike dai_   = dai = TokenLike(DaiJoinLike(daiJoin_).dai());

        ilk      = ilk_;
        chainlog = ChainlogLike(chainlog_);
        daiJoin  = DaiJoinLike(daiJoin_);
        pool     = PoolLike(pool_);
        gem      = TokenLike(pool_);  // TODO: Consolidate gem and pool?
        vat      = VatLike(vat_);
        
        wards[msg.sender] = 1;
        emit Rely(msg.sender);

        // Auths
        VatLike(vat_).hope(daiJoin_);
        dai_.approve(pool_,    type(uint256).max);
        dai_.approve(daiJoin_, type(uint256).max);
    }

    /**********************/
    /*** Auth Functions ***/
    /**********************/

    mapping (address => uint) public wards;

    function rely(address usr) external auth {
        wards[usr] = 1;

        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;

        emit Deny(usr);
    }

    modifier auth {
        require(wards[msg.sender] == 1, "DssDirectDepositMaple/not-authorized");
        _;
    }

    /********************************/
    /*** Administrative Functions ***/
    /********************************/

    function file(bytes32 what, uint256 data) external auth {
        if (what == "tau" ) {
            require(live == 1, "DssDirectDepositMaple/not-live");

            tau = data;
        } else revert("DssDirectDepositMaple/file-unrecognized-param");

        emit File(what, data);
    }

    function file(bytes32 what, address data) external auth {
        require(vat.live() == 1, "DssDirectDepositMaple/no-file-during-shutdown");

        if (what == "king") king = data;
        else revert("DssDirectDepositMaple/file-unrecognized-param");
        emit File(what, data);
    }

    /**********************/
    /*** Math Functions ***/
    /**********************/

    function _min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x <= y ? x : y;
    }

    /*************************************/
    /*** Position Management Functions ***/
    /*************************************/

    event Debug(string, uint);
    event Debug(string);

    function _wind(uint256 amount) internal {
        // IMPORTANT: This function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why this module converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.

        // Wind amount is limited by the debt ceiling
        (uint256 Art,,, uint256 line,) = vat.ilks(ilk);

        uint256 lineWad = line / RAY; // Round down to always be under the actual limit
        
        if (Art + amount > lineWad) {
            amount = lineWad - Art;
        }

        if (amount == 0) {
            emit Wind(0);
            return;
        }

        require(int256(amount) >= 0, "DssDirectDepositMaple/overflow");

        vat.slip(ilk, address(this), int256(amount));
        vat.frob(ilk, address(this), address(this), address(this), int256(amount), int256(amount));
        // normalized debt == erc20 DAI to join (Vat rate for this ilk fixed to 1 RAY)
        daiJoin.exit(address(this), amount);

        uint256 prevBalance = pool.balanceOf(address(this));
        pool.deposit(amount);

        // No precision conversion necessary since both DAI and MPT are 18 decimals
        require(pool.balanceOf(address(this)) - prevBalance == amount, "DssDirectDepositMaple/no-receive-mpt");

        emit Wind(amount);
    }

    // Cannot be done atomically since there is a 10 day cooldown period in Maple pools.
    function _unwind(uint256 supplyReduction, uint256 availableLiquidity, Mode mode) internal {
        // IMPORTANT: This function assumes Vat rate of this ilk will always be == 1 * RAY (no fees).
        // That's why it converts normalized debt (art) to Vat DAI generated with a simple RAY multiplication or division
        // This module will have an unintended behaviour if rate is changed to some other value.

        address end;
        uint256 poolBalance = pool.balanceOf(address(this));
        uint256 daiDebt;
        
        if (mode == Mode.NORMAL) {
            // Normal mode or module just caged (no culled)
            // debt is obtained from CDP art
            ( , daiDebt ) = vat.urns(ilk, address(this));
        } else if (mode == Mode.MODULE_CULLED) {
            // Module shutdown and culled
            // debt is obtained from free collateral owned by this contract
            daiDebt = vat.gem(ilk, address(this));
        } else {
            // MCD caged
            // debt is obtained from free collateral owned by the End module
            end = chainlog.getAddress("MCD_END");
            EndLike(end).skim(ilk, address(this));
            daiDebt = vat.gem(ilk, address(end));
        }

        // Unwind amount is limited by how much:
        // - Max reduction desired
        // - Liquidity available
        // - MPT we have to withdraw
        // - DAI debt tracked in vat (CDP or free)
        uint256 amount = _min(
                            _min(
                                _min(
                                    supplyReduction,
                                    availableLiquidity
                                ),
                                poolBalance
                            ),
                            daiDebt
                        );

        // TODO: Factor in losses

        if (amount == 0) {
            emit Unwind(0);
            return;
        }

        require(amount <= 2 ** 255, "DssDirectDepositMaple/overflow");

        // To save gas you can bring the fees back with the unwind

        uint256 prevBalance = dai.balanceOf(address(this));
        pool.withdraw(amount);

        // TODO: Factor in losses
        require(dai.balanceOf(address(this)) - prevBalance == amount, "DssDirectDepositMaple/incorrect-withdrawal");

        daiJoin.join(address(this), amount);

        address vow = chainlog.getAddress("MCD_VOW");

        if (mode == Mode.NORMAL) {
            vat.frob(ilk, address(this), address(this), address(this), -int256(amount), -int256(amount));
            vat.slip(ilk, address(this), -int256(amount));
        } else if (mode == Mode.MODULE_CULLED) {
            vat.slip(ilk, address(this), -int256(amount));
            vat.move(address(this), vow, amount * RAY);
        } else {
            // This can be done with the assumption that the price of 1 aDai equals 1 DAI.
            // That way we know that the prev End.skim call kept its gap[ilk] emptied as the CDP was always collateralized.
            // Otherwise we couldn't just simply take away the collateral from the End module as the next line will be doing.
            vat.slip(ilk, end, -int256(amount));
            vat.move(address(this), vow, amount * RAY);
        }

        emit Unwind(amount);
    }

    function exec() external {
        // Clear out all interest
        if (pool.withdrawableFundsOf(address(this)) > 0) reap();

        uint256 availableLiquidity = dai.balanceOf(pool.liquidityLocker());  // Cash balance of pool

        ( uint256 lpCooldownPeriod, uint256 lpWithdrawWindow ) = MapleGlobalsLike(PoolFactoryLike(pool.superFactory()).globals()).getLpCooldownParams();

        bool canWithdraw; 
        unchecked {
            // Intentionally overflows if user is not past their cooldown yet
            canWithdraw = (block.timestamp - (pool.withdrawCooldown(address(this)) + lpCooldownPeriod)) <= lpWithdrawWindow;
        }

        // If MCD caged, withdraw max amount under MCD_CAGED enum
        if (vat.live() == 0 && canWithdraw) {
            require(EndLike(chainlog.getAddress("MCD_END")).debt() == 0, "DssDirectDepositMaple/end-debt-already-set");
            require(culled == 0, "DssDirectDepositMaple/module-has-to-be-unculled-first");
            _unwind(
                type(uint256).max,
                availableLiquidity,
                Mode.MCD_CAGED
            );
        } 
        // If D3M caged, withdraw max amount under MODULE_CULLED or NORMAL enum
        else if (live == 0 && canWithdraw) {
            _unwind(
                type(uint256).max,
                availableLiquidity,
                culled == 1
                    ? Mode.MODULE_CULLED
                    : Mode.NORMAL
            );
        } 
        // Else do a withdraw of available liquidity if in withdraw window, or deposit to fill debt ceiling
        else {
            // If D3M is in withdrawal window, trigger _unwind flow
            if (canWithdraw) {
                _unwind(
                    availableLiquidity,  // TODO: Figure out supplyReduction param
                    availableLiquidity,
                    Mode.NORMAL
                );
            }

            uint256 poolValue    = pool.principalOut() + dai.balanceOf(pool.liquidityLocker());
            uint256 liquidityCap = pool.liquidityCap();

            uint256 availablePoolCapacity = poolValue >= liquidityCap ? 0 : liquidityCap - poolValue;

            if (availablePoolCapacity > 0) {
                _wind(availablePoolCapacity);
            }
        }
    }

    // TODO: Figure out name
    function triggerCooldown() external auth {
        pool.intendToWithdraw();
    }

    /********************************/
    /*** Interest Claim Functions ***/
    /********************************/

    function reap() public {
        require(vat.live() == 1, "DssDirectDepositMaple/no-reap-during-shutdown");
        require(live == 1,       "DssDirectDepositMaple/no-reap-during-cage");

        uint256 preBalance = dai.balanceOf(address(this));

        pool.withdrawFunds();
        daiJoin.join(address(chainlog.getAddress("MCD_VOW")), dai.balanceOf(address(this)) - preBalance);
    }

    /***************************/
    /*** Emergency Functions ***/
    /***************************/

    // --- Allow DAI holders to exit during global settlement ---
    function exit(address usr, uint256 wad) external {
        require(wad <= 2 ** 255, "DssDirectDepositMaple/overflow");
        vat.slip(ilk, msg.sender, -int256(wad));
        require(pool.transfer(usr, wad), "DssDirectDepositMaple/failed-transfer");
    }

    // --- Shutdown ---
    function cage() external auth {
        require(vat.live() == 1, "DssDirectDepositMaple/no-cage-during-shutdown");
        live = 0;
        tic  = block.timestamp;
        emit Cage();
    }

    // --- Write-off ---
    function cull() external {
        require(vat.live() == 1, "DssDirectDepositMaple/no-cull-during-shutdown");
        require(live == 0,       "DssDirectDepositMaple/live");
        require(culled == 0,     "DssDirectDepositMaple/already-culled");

        require(tic + tau <= block.timestamp || wards[msg.sender] == 1, "DssDirectDepositMaple/unauthorized-cull");

        (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
        require(ink <= 2 ** 255, "DssDirectDepositMaple/overflow");
        require(art <= 2 ** 255, "DssDirectDepositMaple/overflow");
        vat.grab(ilk, address(this), address(this), chainlog.getAddress("MCD_VOW"), -int256(ink), -int256(art));

        culled = 1;
        emit Cull();
    }

    // --- Rollback Write-off (only if General Shutdown happened) ---
    // This function is required to have the collateral back in the vault so it can be taken by End module
    // and eventually be shared to DAI holders (as any other collateral) or maybe even unwinded
    function uncull() external {
        require(culled == 1,     "DssDirectDepositMaple/not-prev-culled");
        require(vat.live() == 0, "DssDirectDepositMaple/no-uncull-normal-operation");

        uint256 wad = vat.gem(ilk, address(this));
        require(wad < 2 ** 255, "DssDirectDepositMaple/overflow");
        address vow = chainlog.getAddress("MCD_VOW");
        vat.suck(vow, vow, wad * RAY); // This needs to be done to make sure we can deduct sin[vow] and vice in the next call
        vat.grab(ilk, address(this), address(this), vow, int256(wad), int256(wad));

        culled = 0;
        emit Uncull();
    }

    // --- Emergency Quit Everything ---
    function quit(address who) external auth {
        require(vat.live() == 1, "DssDirectDepositMaple/no-quit-during-shutdown");

        // Send all adai in the contract to who
        require(pool.transfer(who, pool.balanceOf(address(this))), "DssDirectDepositMaple/failed-transfer");

        if (culled == 1) {
            // Culled - just zero out the gems
            uint256 wad = vat.gem(ilk, address(this));
            require(wad <= 2 ** 255, "DssDirectDepositMaple/overflow");
            vat.slip(ilk, address(this), -int256(wad));
        } else {
            // Regular operation - transfer the debt position (requires who to accept the transfer)
            (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
            require(ink < 2 ** 255, "DssDirectDepositMaple/overflow");
            require(art < 2 ** 255, "DssDirectDepositMaple/overflow");
            vat.fork(ilk, address(this), who, int256(ink), int256(art));
        }
    }
}
