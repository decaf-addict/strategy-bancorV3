// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import { Fraction112 } from "./Fraction.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolToken } from "./IPoolToken.sol";

struct PoolLiquidity {
    uint128 bntTradingLiquidity; // the BNT trading liquidity
    uint128 baseTokenTradingLiquidity; // the base token trading liquidity
    uint256 stakedBalance; // the staked balance
}

struct AverageRate {
    uint32 blockNumber;
    Fraction112 rate;
}

struct Pool {
    IPoolToken poolToken; // the pool token of the pool
    uint32 tradingFeePPM; // the trading fee (in units of PPM)
    bool tradingEnabled; // whether trading is enabled
    bool depositingEnabled; // whether depositing is enabled
    AverageRate averageRate; // the recent average rate
    uint256 depositLimit; // the deposit limit
    PoolLiquidity liquidity; // the overall liquidity in the pool
}

struct WithdrawalAmounts {
    uint256 totalAmount;
    uint256 baseTokenAmount;
    uint256 bntAmount;
}

//// trading enabling/disabling reasons
//uint8 constant TRADING_STATUS_UPDATE_DEFAULT = 0;
//uint8 constant TRADING_STATUS_UPDATE_ADMIN = 1;
//uint8 constant TRADING_STATUS_UPDATE_MIN_LIQUIDITY = 2;

struct TradeAmountAndFee {
    uint256 amount; // the source/target amount (depending on the context) resulting from the trade
    uint256 tradingFeeAmount; // the trading fee amount
    uint256 networkFeeAmount; // the network fee amount (always in units of BNT)
}

/**
 * @dev Pool Collection interface
 */
interface IPoolCollection {
    /**
     * @dev returns the type of the pool
     */
    function poolType() external pure returns (uint16);

    /**
     * @dev returns the default trading fee (in units of PPM)
     */
    function defaultTradingFeePPM() external view returns (uint32);

    /**
     * @dev returns all the pools which are managed by this pool collection
     */
    function pools() external view returns (IERC20[] memory);

    /**
     * @dev returns the number of all the pools which are managed by this pool collection
     */
    function poolCount() external view returns (uint256);

    /**
     * @dev returns whether a pool is valid
     */
    function isPoolValid(IERC20 pool) external view returns (bool);

    /**
     * @dev returns specific pool's data
     */
    function poolData(IERC20 pool) external view returns (Pool memory);

    /**
     * @dev returns the overall liquidity in the pool
     */
    function poolLiquidity(IERC20 pool) external view returns (PoolLiquidity memory);

    /**
     * @dev returns the pool token of the pool
     */
    function poolToken(IERC20 pool) external view returns (IPoolToken);

    /**
     * @dev converts the specified pool token amount to the underlying base token amount
     */
    function poolTokenToUnderlying(IERC20 pool, uint256 poolTokenAmount) external view returns (uint256);

    /**
     * @dev converts the specified underlying base token amount to pool token amount
     */
    function underlyingToPoolToken(IERC20 pool, uint256 tokenAmount) external view returns (uint256);

    /**
     * @dev returns the number of pool token to burn in order to increase everyone's underlying value by the specified
     * amount
     */
    function poolTokenAmountToBurn(
        IERC20 pool,
        uint256 tokenAmountToDistribute,
        uint256 protocolPoolTokenAmount
    ) external view returns (uint256);


    /**
     * @dev returns the amounts that would be returned if the position is currently withdrawn,
     * along with the breakdown of the base token and the BNT compensation
     */
    function withdrawalAmounts(IERC20 pool, uint256 poolTokenAmount) external view returns (WithdrawalAmounts memory);

}
