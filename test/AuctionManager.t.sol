// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {AuctionManager} from "../src/AuctionManager.sol";

contract AuctionManagerTest is Test {
    AuctionManager public auctionManager;

    function setUp() public {
        auctionManager = new AuctionManager();
    }
}
