// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ======================================================
// IMPORTS
// ======================================================
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {KeeperCompatibleInterface} from
    "@chainlink/contracts/src/v0.8/automation/interfaces/KeeperCompatibleInterface.sol";
import {PoseidonT3} from "@poseidon-solidity/contracts/PoseidonT3.sol";

// ======================================================
// CONTRACT DESCRIPTION & OVERVIEW
// ======================================================
/**
 * @title AuctionManager
 * @dev A commit-reveal sealed-bid NFT auction using Poseidon for bid commitments.
 * @author Victor_TheOracle (https://x.com/victorokpukpan_)
 *
 * The auction is divided into three phases:
 *  - Commit Phase: Bidders send deposits and commit their bid by submitting a hash computed off-chain using Poseidon(bid, salt).
 *    This phase lasts from `startTime` to `commitEndTime`.
 *  - Reveal Phase: Bidders reveal their bid and salt. The contract re-computes the commitment on-chain using Poseidon
 *    and verifies it matches the stored commitment. This phase lasts from `commitEndTime` to `revealEndTime`.
 *  - Finalization: After the reveal phase, the auction is finalized. The highest revealed bid wins, the NFT is transferred
 *    to the winner, the seller receives the winning deposit, and losing deposits are refunded.
 */
contract AuctionManager is KeeperCompatibleInterface {
    // ======================================================
    // DATA STRUCTURES
    // ======================================================

    /// @notice Structure representing a committed bid.
    struct BidCommit {
        address bidder;
        uint256 deposit; // The funds deposited (should equal the bid amount)
        bytes32 bidCommitment; // Commitment computed off-chain via Poseidon(bid, salt)
        bool revealed; // Whether the bidder has revealed their bid
        uint256 bidValue; // The revealed bid value (set during the reveal phase)
        bool refunded; // Whether the deposit has been refunded
    }

    /// @notice Structure representing an auction.
    struct Auction {
        uint256 id;
        address seller;
        address nftAddress;
        uint256 tokenId;
        uint256 minBid; // Minimum bid accepted (in wei)
        uint256 startTime; // Start time of the commit phase (Unix timestamp)
        uint256 commitEndTime; // End time of the commit phase (Unix timestamp)
        uint256 revealEndTime; // End time of the reveal phase (Unix timestamp)
        bool closed; // Whether the auction has been finalized
        address highestBidder;
        BidCommit[] bids;
    }

    // ======================================================
    // STATE VARIABLES
    // ======================================================
    uint256 public auctionCounter;
    mapping(uint256 => Auction) public auctions;
    uint256[] public activeAuctions;

    // ======================================================
    // EVENTS
    // ======================================================
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        address nftAddress,
        uint256 tokenId,
        uint256 startTime,
        uint256 commitEndTime,
        uint256 revealEndTime
    );
    event BidCommitted(uint256 indexed auctionId, address indexed bidder, uint256 deposit);
    event BidRevealed(uint256 indexed auctionId, address indexed bidder, uint256 bidValue);
    event AuctionClosed(uint256 indexed auctionId, address indexed winner, uint256 winningBid);
    event RefundIssued(uint256 indexed auctionId, address indexed bidder, uint256 amount);

    // ======================================================
    // MODIFIERS
    // ======================================================
    /**
     * @dev Modifier to check that an auction exists.
     * @param _auctionId The auction identifier.
     */
    modifier auctionExists(uint256 _auctionId) {
        require(_auctionId < auctionCounter, "Auction does not exist");
        _;
    }

    // ======================================================
    // AUCTION CREATION FUNCTION
    // ======================================================
    /**
     * @notice Creates a new auction by transferring the NFT into escrow and setting auction parameters.
     * @param nftAddress The address of the NFT contract.
     * @param tokenId The token ID of the NFT.
     * @param minBid The minimum bid accepted (in wei).
     * @param startTime The auction commit phase start time (Unix timestamp).
     * @param commitDuration The duration (in seconds) of the commit phase.
     * @param revealDuration The duration (in seconds) of the reveal phase.
     */
    function createAuction(
        address nftAddress,
        uint256 tokenId,
        uint256 minBid,
        uint256 startTime,
        uint256 commitDuration,
        uint256 revealDuration
    ) external {
        // Validate auction parameters.
        require(commitDuration > 0, "Commit duration must be > 0");
        require(revealDuration > 0, "Reveal duration must be > 0");
        require(block.timestamp <= startTime, "Auction must start in the future");

        // Calculate phase end times.
        uint256 commitEndTime = startTime + commitDuration;
        uint256 revealEndTime = commitEndTime + revealDuration;
        require(revealEndTime > startTime, "Invalid auction timing");

        // Transfer the NFT from the seller to this contract.
        IERC721(nftAddress).safeTransferFrom(msg.sender, address(this), tokenId);

        // Initialize new auction.
        Auction storage newAuction = auctions[auctionCounter];
        newAuction.id = auctionCounter;
        newAuction.seller = msg.sender;
        newAuction.nftAddress = nftAddress;
        newAuction.tokenId = tokenId;
        newAuction.minBid = minBid;
        newAuction.startTime = startTime;
        newAuction.commitEndTime = commitEndTime;
        newAuction.revealEndTime = revealEndTime;
        newAuction.closed = false;

        // Add auction to the active auctions list.
        activeAuctions.push(auctionCounter);

        // Emit event for auction creation.
        emit AuctionCreated(auctionCounter, msg.sender, nftAddress, tokenId, startTime, commitEndTime, revealEndTime);
        auctionCounter++;
    }

    // ======================================================
    // BID COMMIT PHASE FUNCTIONS
    // ======================================================
    /**
     * @notice Commit phase: Bidders call this function to commit their bid.
     * @dev The bidder sends a deposit (msg.value) and a bid commitment computed off-chain as Poseidon(bid, salt).
     * @param auctionId The auction identifier.
     * @param bidCommitment The bid commitment.
     */
    function commitBid(uint256 auctionId, bytes32 bidCommitment) external payable auctionExists(auctionId) {
        Auction storage auc = auctions[auctionId];
        require(block.timestamp >= auc.startTime, "Commit phase not started yet");
        require(block.timestamp < auc.commitEndTime, "Commit phase ended");
        require(msg.value >= auc.minBid, "Deposit below minimum bid");

        // Create and store a new bid commitment.
        BidCommit memory newBid = BidCommit({
            bidder: msg.sender,
            deposit: msg.value,
            bidCommitment: bidCommitment,
            revealed: false,
            bidValue: 0,
            refunded: false
        });
        auc.bids.push(newBid);
        emit BidCommitted(auctionId, msg.sender, msg.value);
    }

    // ======================================================
    // BID REVEAL PHASE FUNCTIONS
    // ======================================================
    /**
     * @notice Reveal phase: Bidders reveal their bid and salt to prove their commitment.
     * @dev The contract computes the commitment using Poseidon and compares it to the stored commitment.
     * @param auctionId The auction identifier.
     * @param bidValue The actual bid value.
     * @param salt The salt used in the commitment.
     */
    function revealBid(uint256 auctionId, uint256 bidValue, uint256 salt) external auctionExists(auctionId) {
        Auction storage auc = auctions[auctionId];
        require(block.timestamp >= auc.commitEndTime, "Reveal phase not started yet");
        require(block.timestamp < auc.revealEndTime, "Reveal phase ended");

        bool found = false;
        // Loop through bids to find the matching bidder that hasn't revealed yet.
        for (uint256 i = 0; i < auc.bids.length; i++) {
            BidCommit storage bidInstance = auc.bids[i];
            if (bidInstance.bidder == msg.sender && !bidInstance.revealed) {
                // Compute the commitment on-chain using Poseidon.
                uint256 computedCommitment = PoseidonT3.hash([bidValue, salt]);
                require(computedCommitment == uint256(bidInstance.bidCommitment), "Invalid reveal: commitment mismatch");
                bidInstance.bidValue = bidValue;
                bidInstance.revealed = true;
                found = true;
                emit BidRevealed(auctionId, msg.sender, bidValue);
                break;
            }
        }
        require(found, "No matching bid found or already revealed");
    }

    // ======================================================
    // WITHDRAWAL OF REFUNDS
    // ======================================================
    /**
     * @notice Allows a bidder to withdraw their deposit manually if they were not refunded.
     * @param auctionId The auction identifier.
     */
    function withdrawRefund(uint256 auctionId) external auctionExists(auctionId) {
        Auction storage auc = auctions[auctionId];
        require(auc.closed, "Auction not finalized yet");
        uint256 refundAmount;
        for (uint256 i = 0; i < auc.bids.length; i++) {
            BidCommit storage bidInstance = auc.bids[i];
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

    // ======================================================
    // CHAINLINK KEEPERS FUNCTIONS
    // ======================================================
    /**
     * @notice Chainlink Keepers: Checks if any auction's reveal phase has ended and needs finalization.
     * @return upkeepNeeded True if at least one auction is ready to be finalized.
     * @return performData Encoded data containing the list of auction IDs to finalize.
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
            if (!auc.closed && block.timestamp >= auc.revealEndTime) {
                auctionsToFinalize[count] = auctionId;
                count++;
            }
        }
        upkeepNeeded = (count > 0);
        performData = abi.encode(auctionsToFinalize, count);
    }

    /**
     * @notice Chainlink Keepers: Finalizes auctions automatically if needed.
     * @param performData Encoded data containing the list of auction IDs to finalize.
     */
    function performUpkeep(bytes calldata performData) external override {
        (uint256[] memory auctionsToFinalize, uint256 count) = abi.decode(performData, (uint256[], uint256));

        for (uint256 i = 0; i < count; i++) {
            uint256 auctionId = auctionsToFinalize[i];
            _finalizeAuction(auctionId);
        }
    }

    // ======================================================
    // INTERNAL HELPER FUNCTIONS
    // ======================================================

    /**
     * @notice Finalizes the auction after the reveal phase.
     * @dev Determines the highest revealed bid, transfers the NFT to the winner,
     *      sends funds to the seller, and refunds the other bidders. If there are no bidders,
     *      the NFT is returned to the Owner.
     * @param auctionId The auction identifier.
     */
    function _finalizeAuction(uint256 auctionId) internal auctionExists(auctionId) {
        Auction storage auc = auctions[auctionId];
        require(block.timestamp >= auc.revealEndTime, "Auction reveal phase not ended yet");
        require(!auc.closed, "Auction already finalized");

        // Identify the highest bid.
        uint256 winningBidValue = 0;
        uint256 winningIndex = type(uint256).max;
        for (uint256 i = 0; i < auc.bids.length; i++) {
            if (auc.bids[i].revealed && auc.bids[i].bidValue > winningBidValue) {
                winningBidValue = auc.bids[i].bidValue;
                winningIndex = i;
            }
        }

        // If no valid bid is revealed, send the NFT back to the seller (owner)
        if (winningIndex == type(uint256).max) {
            auc.closed = true;
            // Transfer NFT back to seller (owner)
            IERC721(auc.nftAddress).safeTransferFrom(address(this), auc.seller, auc.tokenId);
            emit AuctionClosed(auctionId, auc.seller, 0);
            _removeActiveAuction(auctionId);
            return;
        }

        // Set the winner and mark auction as closed.
        auc.highestBidder = auc.bids[winningIndex].bidder;
        auc.closed = true;

        // Transfer the NFT to the highest bidder.
        IERC721(auc.nftAddress).safeTransferFrom(address(this), auc.highestBidder, auc.tokenId);

        // Transfer the winning deposit to the seller.
        uint256 winningDeposit = auc.bids[winningIndex].deposit;
        (bool sentSeller,) = auc.seller.call{value: winningDeposit}("");
        require(sentSeller, "Transfer to seller failed");

        // Refund deposits for all other (losing) bids.
        for (uint256 i = 0; i < auc.bids.length; i++) {
            if (i != winningIndex && !auc.bids[i].refunded) {
                uint256 refundAmount = auc.bids[i].deposit;
                auc.bids[i].refunded = true;
                (bool sentRefund,) = auc.bids[i].bidder.call{value: refundAmount}("");
                require(sentRefund, "Refund failed");
                emit RefundIssued(auctionId, auc.bids[i].bidder, refundAmount);
            }
        }
        emit AuctionClosed(auctionId, auc.highestBidder, winningBidValue);
        _removeActiveAuction(auctionId);
    }

    /**
     * @dev Internal function to remove an auction from the activeAuctions array.
     * @param auctionId The auction identifier to remove.
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

    // ======================================================
    // VIEW FUNCTIONS
    // ======================================================
    /**
     * @notice Returns an array of all active auctions with their complete information.
     * @return Auction[] Array of active auctions.
     */
    function getActiveAuctions() external view returns (Auction[] memory) {
        Auction[] memory activeAuctionList = new Auction[](activeAuctions.length);
        for (uint256 i = 0; i < activeAuctions.length; i++) {
            activeAuctionList[i] = auctions[activeAuctions[i]];
        }
        return activeAuctionList;
    }

    // ======================================================
    // ERC721 RECEIVER FUNCTION
    // ======================================================
    /**
     * @notice ERC721 receiver function to allow safe transfers.
     * @return The selector confirming the token transfer.
     */
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
