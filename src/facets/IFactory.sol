// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IFactory {
    function deployAgreement(
        address client,
        address executor,
        address arbiter,
        uint256 amount,
        uint256 deadlineDays,
        string calldata terms,
        uint8 region
    ) external returns (address agreementAddress);
}
