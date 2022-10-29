// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@gnosis.pm/safe-contracts/contracts/base/ModuleManager.sol";
import "@gnosis.pm/safe-contracts/contracts/base/OwnerManager.sol";
import "@gnosis.pm/safe-contracts/contracts/common/SecuredTokenTransfer.sol";
import "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import "@gnosis.pm/safe-contracts/contracts/common/SignatureDecoder.sol";
import "@gnosis.pm/safe-contracts/contracts/common/SelfAuthorized.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../utils/DateTime.sol";

contract RecurringPaymentModule is SecuredTokenTransfer, SignatureDecoder, DateTime, SelfAuthorized {
    using SafeMath for uint256;

    // recurringTransfers maps the composite hash of a token and account address to a recurring transfer struct.
    mapping (address => RecurringTransfer) public recurringTransfers;

    // nonce to invalidate previously executed transactions
    uint256 public nonce;

    IModuleManager manager;

    struct RecurringTransfer {
        address delegate;

        address token;
        uint256 amount;

        uint8 transferDay;
        uint8 transferHourStart;
        uint8 transferHourEnd;

        uint32 lastTransferTime;
    }

    constructor(IModuleManager _manager) {
        manager = _manager;
    }

    function addRecurringTransfer(
        address receiver,
        address delegate,
        address token,
        uint256 amount,
        uint8 transferDay,
        uint8 transferHourStart,
        uint8 transferHourEnd
    ) public authorized {
        require(amount != 0, "amount must be greater than 0");
        require(transferDay < 29, "transferDay must be less than 29");
        require(transferHourStart > 0, "transferHourStart must be greater than 0");
        require(transferHourEnd < 23, "transferHourEnd must be less than 23");
        require(transferHourStart < transferHourEnd, "transferHourStart must be less than transferHourEnd");
        recurringTransfers[receiver] = RecurringTransfer(delegate, token, amount, transferDay, transferHourStart, transferHourEnd, 0);
    }

    function removeRecurringTransfer(address receiver) public authorized {
        delete recurringTransfers[receiver];
    }

    function executeRecurringTransfer(
        address receiver,
        uint256 safeTxGas,
        uint256 dataGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes memory signature
    ) public {
        require(receiver != address(0), "A non-zero reciever address must be provided");
        RecurringTransfer memory recurringTransfer = recurringTransfers[receiver];
        require(recurringTransfer.amount != 0, "A recurring transfer has not been created for this address");
        require(isPastMonth(recurringTransfer.lastTransferTime), "Transfer has already been executed this month");
        require(isOnDayAndBetweenHours(recurringTransfer.transferDay, recurringTransfer.transferHourStart, recurringTransfer.transferHourEnd), "Transfer request not within valid timeframe");

        uint256 startGas = gasleft();
        bytes32 txHash = getTransactionHash(
            receiver,
            safeTxGas, dataGas, gasPrice, gasToken, refundReceiver,
            nonce
        );
        require(checkSignature(txHash, signature, recurringTransfer.delegate), "Invalid signature provided");
        nonce++;
        require(gasleft() >= safeTxGas, "Not enough gas to execute safe transaction");

        recurringTransfers[receiver].lastTransferTime = uint32(block.timestamp);

        if (recurringTransfer.token == address(0)) {
            require(manager.execTransactionFromModule(receiver, recurringTransfer.amount, "", Enum.Operation.Call), "Could not execute Ether transfer");
        } else {
            bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", receiver, recurringTransfer.amount);
            require(manager.execTransactionFromModule(recurringTransfer.token, 0, data, Enum.Operation.Call), "Could not execute token transfer");
        }

        // We transfer the calculated tx costs to the tx.origin to avoid sending it to intermediate contracts that have made calls
        if (gasPrice > 0) {
            handlePayment(startGas, dataGas, gasPrice, gasToken, refundReceiver);
        }
    }

    function isOnDayAndBetweenHours(uint8 day, uint8 hourStart, uint8 hourEnd)
        internal view returns (bool)
    {
        return getDay(block.timestamp) == day &&
        getHour(block.timestamp) >= hourStart &&
        getHour(block.timestamp) < hourEnd;
    }

    function isPastMonth(uint256 previousTime)
        internal view returns (bool)
    {
        return getYear(block.timestamp) > getYear(previousTime) ||
        getMonth(block.timestamp) > getMonth(previousTime);
    }

    function getTransactionHash(
        address receiver,
        uint256 safeTxGas,
        uint256 dataGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    )
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0), this, receiver, safeTxGas, dataGas, gasPrice, gasToken, refundReceiver, _nonce)
        );
    }

    function checkSignature(bytes32 transactionHash, bytes memory signature, address delegate)
        internal
        view
        returns (bool)
    {
        address signer = recoverKey(transactionHash, signature, 0);
        return signer == delegate || OwnerManager(address(manager)).isOwner(signer);
    }

    function handlePayment(
        uint256 gasUsed,
        uint256 dataGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver
    )
        private
    {
        uint256 amount = ((gasUsed.sub(gasleft())).add(dataGas)).mul(gasPrice);
        // solium-disable-next-line security/no-tx-origin
        address receiver = refundReceiver == address(0) ? tx.origin : refundReceiver;
        if (gasToken == address(0)) {
            // solium-disable-next-line security/no-send
            manager.execTransactionFromModule(receiver, amount, "", Enum.Operation.Call);
            require(manager.execTransactionFromModule(receiver, amount, "", Enum.Operation.Call), "Could not pay gas costs with ether");
        } else {
            bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", receiver, amount);
            require(manager.execTransactionFromModule(gasToken, 0, data, Enum.Operation.Call), "Could not pay gas costs with token");
        }
    }

    /// @dev Recovers address who signed the message
    /// @param messageHash operation ethereum signed message hash
    /// @param messageSignature message `txHash` signature
    /// @param pos which signature to read
    function recoverKey (
        bytes32 messageHash,
        bytes memory messageSignature,
        uint256 pos
    )
        internal
        pure
        returns (address)
    {
        uint8 v;
        bytes32 r;
        bytes32 s;
        (v, r, s) = signatureSplit(messageSignature, pos);
        return ecrecover(messageHash, v, r, s);
    }
}

interface IModuleManager {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external returns (bool success);
}