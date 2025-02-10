// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {SadFaceNft} from "../src/SadFaceNft.sol";

contract SadFaceNftTest is Test {
    SadFaceNft private sadFaceNft;
    address private user = address(1);
    
    function setUp() public {
        sadFaceNft = new SadFaceNft("ipfs://example-image-uri");
    }
    
    function testMinting() public {
        vm.prank(user);
        sadFaceNft.mintNft();
        
        assertEq(sadFaceNft.ownerOf(0), user);
    }
    
    function testTokenUri() public {
        vm.prank(user);
        sadFaceNft.mintNft();
        
        string memory expectedUriPrefix = "data:application/json;base64,";
        string memory tokenUri = sadFaceNft.tokenURI(0);
        
        assertTrue(bytes(tokenUri).length > bytes(expectedUriPrefix).length);
        console.log(tokenUri);
    }
    
    function testTokenUriForNonExistentToken() public {
        vm.expectRevert();
        sadFaceNft.tokenURI(999);
    }
}
