// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract SadFaceNft is ERC721 {
    error ERC721Metadata__URI_QueryFor_NonExistentToken();

    uint256 private s_tokenCounter;
    string private s_imageUri;

    event MintedNFT(uint256 indexed tokenId);

    constructor(string memory ImageUri) ERC721("SadFace NFT", "SF") {
        s_tokenCounter = 0;
        s_imageUri = ImageUri;
    }

    function mintNft() public {
        _safeMint(msg.sender, s_tokenCounter);
        emit MintedNFT(s_tokenCounter);
        s_tokenCounter++;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (ownerOf(tokenId) == address(0)) {
            revert ERC721Metadata__URI_QueryFor_NonExistentToken();
        }
        return string(
        abi.encodePacked(
            _baseURI(),
            Base64.encode(
                bytes(
                    abi.encodePacked(
                        '{"name": "',
                        name(),
                        '", "description": "An NFT that is always sad", ',
                        '"attributes": [{"trait_type": "Mood", "value": "Sad"}], ',
                        '"image": "',
                        s_imageUri,
                        '"}'
                    )
                )
            )
        )
    );
    }  
}
