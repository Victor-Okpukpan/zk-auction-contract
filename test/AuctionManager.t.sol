// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {AuctionManager} from "../src/AuctionManager.sol";

contract AuctionManagerTest is Test {
    AuctionManager public auctionManager;

    function setUp() public {
        auctionManager = new AuctionManager();
    }
}
