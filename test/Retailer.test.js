const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Retailer", function(){
    it("Should deploy the contract", async function () {
        /* Deploy the Retailer contract */
        const retailerFactory = await ethers.getContractFactory("Retailer");
        const retailer = await retailerFactory.deploy();
        await retailer.deployed();

        const deployed_address = await retailer.address();
        console.log(`address is deployed at {address}`); 
        expect(deployed_address).is.not.empty();
    });
});