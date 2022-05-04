// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev Pool Token interface
 */
interface IPoolToken is IERC20 {
    /**
     * @dev returns the address of the reserve token
     */
    function reserveToken() external view returns (IERC20);

}
