// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {KeeperCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";

/**
 * @title AuctionManager
 * @dev Implements a sealed-bid NFT auction where bid values remain hidden. Sellers list their NFT
 * for auction (with a time window). Bidders submit an encrypted bid (and a corresponding zk proof)
 * along with a deposit. When the auction ends, an off-chain process or auctioneer supplies a zk proof
 * (via zkVerify) that proves, without revealing bid values, which bid is the highest. Losing bidders
 * are automatically refunded.
 */
contract AuctionManager is KeeperCompatibleInterface {
    struct Bid {
        address bidder;
        uint256 deposit;
        bytes encryptedBid;
        bytes individualZkProof;
        bool refunded;
    }

    struct Auction {
        address seller;
        address nftAddress;
        uint256 tokenId;
        uint256 minBid;
        uint256 startTime;
        uint256 endTime;
        bool closed;
        address highestBidder;
        Bid[] bids;
    }

    uint256 public auctionCounter;
    mapping(uint256 => Auction) public auctions;
    uint256[] public activeAuctions;

    event AuctionCreated(
        uint256 auctionId, address seller, address nftAddress, uint256 tokenId, uint256 startTime, uint256 endTime
    );
    event BidPlaced(uint256 auctionId, address bidder, uint256 deposit);
    event AuctionClosed(uint256 auctionId, address winner);
    event RefundIssued(uint256 auctionId, address bidder, uint256 amount);

    modifier auctionExists(uint256 _auctionId) {
        require(_auctionId < auctionCounter, "Auction does not exist");
        _;
    }

    // ----- zkVerify Integration Stubs -----
    /**
     * @dev Verifies an individual bid's zk proof (e.g., that the bid is in an acceptable range).
     * Replace this stub with an actual call to zkVerify.
     */
    function verifyIndividualZkProof(bytes memory zkProof, bytes memory encryptedBid) internal pure returns (bool) {
        // TODO: Integrate with zkVerify.
        return true;
    }

    /**
     * @dev Verifies a final zk proof that attests the winning bid (at index _winningBidIndex) is higher
     * than all other bids without revealing the bid values.
     * Replace this stub with an actual zkVerify integration.
     */
    function verifyFinalAuctionZkProof(uint256 auctionId, uint256 winningBidIndex, bytes memory finalZkProof)
        internal
        view
        returns (bool)
    {
        // TODO: Call zkVerify (or validate an off-chain generated proof) that the bid at winningBidIndex
        // is higher than all other bids.
        return true;
    }

    // ----- Auction Creation -----
    /**
     * @dev Creates a new auction by transferring the NFT into escrow and setting auction parameters.
     */
    function createAuction(address nftAddress, uint256 tokenId, uint256 minBid, uint256 startTime, uint256 endTime)
        external
    {
        require(endTime > startTime, "End time must be greater than start time");
        require(block.timestamp <= startTime, "Auction start time must be in the future");

        // Transfer NFT from seller to contract.
        IERC721(nftAddress).safeTransferFrom(msg.sender, address(this), tokenId);

        Auction storage newAuction = auctions[auctionCounter];
        newAuction.seller = msg.sender;
        newAuction.nftAddress = nftAddress;
        newAuction.tokenId = tokenId;
        newAuction.minBid = minBid;
        newAuction.startTime = startTime;
        newAuction.endTime = endTime;
        newAuction.closed = false;

        activeAuctions.push(auctionCounter);
        emit AuctionCreated(auctionCounter, msg.sender, nftAddress, tokenId, startTime, endTime);
        auctionCounter++;
    }

    // ----- Bid Submission -----
    /**
     * @dev Place a sealed bid by submitting an encrypted bid and its zk proof.
     * The deposit is sent along with the bid.
     */
    function placeBid(uint256 auctionId, bytes calldata encryptedBid, bytes calldata individualZkProof)
        external
        payable
        auctionExists(auctionId)
    {
        Auction storage auc = auctions[auctionId];
        require(block.timestamp >= auc.startTime, "Auction not started yet");
        require(block.timestamp < auc.endTime, "Auction already ended");
        require(msg.value >= auc.minBid, "Deposit below minimum bid");
        require(verifyIndividualZkProof(individualZkProof, encryptedBid), "Invalid bid zk proof");

        Bid memory newBid = Bid({
            bidder: msg.sender,
            deposit: msg.value,
            encryptedBid: encryptedBid,
            individualZkProof: individualZkProof,
            refunded: false
        });
        auc.bids.push(newBid);
        emit BidPlaced(auctionId, msg.sender, msg.value);
    }

    // ----- Auction Finalization with zk Verification -----
    /**
     * @dev Finalizes the auction. Instead of comparing deposits directly (which would reveal bid amounts),
     * the auctioneer (or an off-chain process) provides a final zk proof (finalZkProof) and the winning bid index.
     * The proof attests that the bid at winningBidIndex is higher than all other bids.
     * This function then transfers the NFT to the winner, sends funds to the seller, and refunds losing bidders.
     * This function is callable by anyone after the auction end time.
     */
    function finalizeAuction(uint256 auctionId, uint256 winningBidIndex, bytes calldata finalZkProof)
        external
        auctionExists(auctionId)
    {
        Auction storage auc = auctions[auctionId];
        require(block.timestamp >= auc.endTime, "Auction not ended yet");
        require(!auc.closed, "Auction already finalized");
        require(winningBidIndex < auc.bids.length, "Invalid winning bid index");

        // Verify the final zk proof attesting the winning bid is the highest.
        bool valid = verifyFinalAuctionZkProof(auctionId, winningBidIndex, finalZkProof);
        require(valid, "Final auction zk proof invalid");

        auc.highestBidder = auc.bids[winningBidIndex].bidder;
        auc.closed = true;

        // Transfer NFT to the winning bidder.
        IERC721(auc.nftAddress).safeTransferFrom(address(this), auc.highestBidder, auc.tokenId);

        // For funds settlement, assume the winning bidder's deposit equals their bid amount.
        uint256 winningDeposit = auc.bids[winningBidIndex].deposit;
        // Transfer the winning deposit to the seller.
        (bool sentSeller,) = auc.seller.call{value: winningDeposit}("");
        require(sentSeller, "Transfer to seller failed");

        // Refund deposits for all losing bids.
        for (uint256 i = 0; i < auc.bids.length; i++) {
            if (i != winningBidIndex && !auc.bids[i].refunded) {
                uint256 refundAmount = auc.bids[i].deposit;
                auc.bids[i].refunded = true;
                (bool sentRefund,) = auc.bids[i].bidder.call{value: refundAmount}("");
                require(sentRefund, "Refund failed");
                emit RefundIssued(auctionId, auc.bids[i].bidder, refundAmount);
            }
        }
        emit AuctionClosed(auctionId, auc.highestBidder);
        _removeActiveAuction(auctionId);
    }

    // ----- Manual Refund Fallback -----
    /**
     * @dev Allows a bidder to withdraw their deposit manually if they were not refunded.
     */
    function withdrawRefund(uint256 auctionId) external auctionExists(auctionId) {
        Auction storage auc = auctions[auctionId];
        require(auc.closed, "Auction not finalized yet");
        uint256 refundAmount;
        for (uint256 i = 0; i < auc.bids.length; i++) {
            Bid storage bidInstance = auc.bids[i];
            if (bidInstance.bidder == msg.sender && !bidInstance.refunded && msg.sender != auc.highestBidder) {
                refundAmount = bidInstance.deposit;
                bidInstance.refunded = true;
                (bool sent,) = msg.sender.call{value: refundAmount}("");
                require(sent, "Refund failed");
                emit RefundIssued(auctionId, msg.sender, refundAmount);
                return;
            }
        }
        revert("No refundable deposit found");
    }

    // ----- Chainlink Keepers Integration -----
    /**
     * @dev checkUpkeep scans active auctions to see if any have ended but not been finalized.
     */
    function checkUpkeep(bytes calldata /* checkData */ )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 activeCount = activeAuctions.length;
        uint256[] memory auctionsToFinalize = new uint256[](activeCount);
        uint256 count = 0;

        for (uint256 i = 0; i < activeCount; i++) {
            uint256 auctionId = activeAuctions[i];
            Auction storage auc = auctions[auctionId];
            if (!auc.closed && block.timestamp >= auc.endTime) {
                auctionsToFinalize[count] = auctionId;
                count++;
            }
        }
        upkeepNeeded = (count > 0);
        performData = abi.encode(auctionsToFinalize, count);
    }

    /**
     * @dev performUpkeep is called by Chainlink Keepers to finalize auctions automatically.
     */
    function performUpkeep(bytes calldata performData) external override {
        (uint256[] memory auctionsToFinalize, uint256 count) = abi.decode(performData, (uint256[], uint256));
        for (uint256 i = 0; i < count; i++) {
            uint256 auctionId = auctionsToFinalize[i];
            // In production, the final zk proof and winning index would be provided off-chain.
            // For now, we assume the auctioneer (or a trusted process) supplies valid data.
            // Here we revert if such data is not provided, so this function might need further integration.
            // finalizeAuction(auctionId, winningBidIndex, finalZkProof);
            // For the MVP, you could call finalizeAuction manually.
        }
    }

    /**
     * @dev Removes an auction from the activeAuctions array.
     */
    function _removeActiveAuction(uint256 auctionId) internal {
        uint256 length = activeAuctions.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeAuctions[i] == auctionId) {
                activeAuctions[i] = activeAuctions[length - 1];
                activeAuctions.pop();
                break;
            }
        }
    }

    // ----- ERC721 Receiver Implementation -----
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
