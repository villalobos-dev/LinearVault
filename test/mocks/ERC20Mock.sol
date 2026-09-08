// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title ERC20Mock
 * @author villalobos-dev
 * @notice Test token that mimics USDC: 6 decimals and EIP-2612 (`permit`) support.
 * @dev Minting is open to anyone on purpose so tests can fund any address. Never deploy to production.
 */
contract ERC20Mock is ERC20Permit {
    /// @dev Number of decimals, matching USDC instead of the ERC20 default of 18.
    uint8 private constant DECIMALS = 6;

    /// @notice Deploys the mock token with its name, symbol and EIP-712 domain.
    constructor() ERC20("Mock USDC", "mUSDC") ERC20Permit("Mock USDC") {}

    /**
     * @notice Returns the number of decimals of the token.
     * @return Always 6, to mirror USDC.
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Mints new tokens to an address.
     * @dev Unrestricted: any caller can mint. Test helper only.
     * @param to Address that receives the newly minted tokens.
     * @param amount Amount to mint, in token units (6 decimals).
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
