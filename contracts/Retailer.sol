// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract FallbackHandler {
    fallback() external {}
}
contract Retailer {

    struct Payment {
        bytes32 id;
        address seller;
        address buyer;
        IERC20 token;
        uint256 amount;
        bool refunded;
    }

    mapping (bytes32 => Payment) payments;

    event PaymentSent(bytes32 indexed id, uint256 indexed amount);
    event RefundSent(bytes32 indexed id, uint256 indexed amount);

    constructor(){}

    function pay(address payable seller, uint256 amount, IERC20 token) external payable {
        // paying it forward
        if (msg.value != 0) {
            // it's an eth transaction
            (bool success, ) = seller.call{value: msg.value}("");
            require(success, "Failed to send Ether");
            amount = msg.value;
        } else {
            // it's not eth
            bool success = token.transferFrom(msg.sender, seller, amount);
            require(success, "Failed to send ERC-20 Token");
        } 

        // saving the details in Payment struct
        bytes32 id = keccak256(abi.encodePacked(seller, msg.sender, amount, block.timestamp));
        Payment memory p = Payment(id, seller, msg.sender, token, amount, false);
        payments[id] = p;

        //emit event
        emit PaymentSent(id, amount);
    }

    function refund(bytes32 id) external payable onlySeller(id) {
        Payment memory p = payments[id];
        require(p.refunded != true, "You have already requested a refund");
        if (address(p.token) == address(0)) {
            (bool success, ) = p.buyer.call{value: p.amount}("");
            require(success, "Failed to send Ether");
        }  else {
            bool success = p.token.transferFrom(msg.sender, p.buyer, p.amount);
            require(success, "Failed to send ERC-20 Token");
        }

        p.refunded = true;
        payments[id] = p;
        
        //emit event
        emit RefundSent(p.id, p.amount);
    }

    function getPaymentInfo(bytes32 id) external view returns (Payment memory) {
        return payments[id];
    }

    modifier onlySeller(bytes32 id) {
        // check that payment exists
        // check that msg.sender is the seller
        Payment memory p = payments[id];
        require(msg.sender == p.seller, "You are not the seller");
        _;
    }
}