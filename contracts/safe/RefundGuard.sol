// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import "@gnosis.pm/safe-contracts/contracts/base/GuardManager.sol";
import "@gnosis.pm/safe-contracts/contracts/GnosisSafe.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRetailer {
    struct Payment {
        bytes32 id;
        address seller;
        address buyer;
        IERC20 token;
        uint256 amount;
        bool refunded;
    }
    function getPaymentInfo(bytes32 id) external view returns (Payment memory);

    function refund(bytes32 id) external payable;
}

/* Checks that a refund transaction is valid */
contract RefundGuard is Guard {
    IRetailer retailer;

    constructor(IRetailer _retailer) {
        retailer = _retailer;
    }

    function checkTransaction(
        address to,
        uint256 /* value */,
        bytes memory data,
        Enum.Operation /* operation */,
        uint256 /* safeTxGas */,
        uint256 /* baseGas */,
        uint256 /* gasPrice */,
        address /* gasToken */,
        address payable /* refundReceiver */,
        bytes memory /* signatures */,
        address /* msgSender */
    ) external view override {
        bytes4 functionSelector = bytes4(accessBytes(data, 0, 4));
        if (functionSelector != IRetailer.refund.selector) {
            return;
        }

        require(to == address(retailer), "Invalid retailer address.");
        // get payment id from calldata
        bytes32 paymentId = bytes32(accessBytes(data, 4, 36));
        IRetailer.Payment memory p = retailer.getPaymentInfo(paymentId);
        require(p.id != 0, "This payment doesn't exist.");
        require(p.refunded == false, "This payment is already refunded.");
        require(p.seller == address(this), "This payment was not made for this gnosis safe.");
    }

    function checkAfterExecution(bytes32 txHash, bool success) external {}

    function accessBytes(bytes memory b, uint8 from, uint8 n) internal pure returns (bytes memory) {
        bytes memory ret = new bytes(n);
        for (uint8 i = 0; i < n - from; i++) {
            ret[i] = b[i + from]; 
        }
        return ret;
    }

    fallback() external {
        // We don't revert on fallback to avoid issues in case of a Safe upgrade
        // E.g. The expected check method might change and then the Safe would be locked.
    }
}
