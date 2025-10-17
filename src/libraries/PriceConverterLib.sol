// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverterLib {
    function getEthPrice(address priceFeed) internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(priceFeed).latestRoundData();
        // Chainlink returns price with 8 decimals
        // Return the ETH/USD price with 18 decimals
        return uint256(price * 1e10);
    }

    function getUsdValue(uint256 ethAmount, address priceFeed) internal view returns (uint256) {
        uint256 ethPrice = getEthPrice(priceFeed);
        // (Price_18 * ethAmount_18) / 1e18
        // Return the USD value of ethAmount with 18 decimals after adjusting the extra 0s
        uint256 ethAmountInUSD = (ethPrice * ethAmount) / 1e18;
        return ethAmountInUSD;
    }
}
