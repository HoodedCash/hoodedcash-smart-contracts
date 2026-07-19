// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {ReentrancyGuard} from "../libraries/ReentrancyGuard.sol";
import "../libraries/HoodedErrors.sol";

/// @title HoodedStaking
/// @notice Staking vault for the $HOODED governance token. Staking $HOODED is
///         what earns the largest fee reduction across HoodedCash: staked tokens
///         count at full weight in {FeeController}, where merely holding counts
///         at a reduced weight. Committing tokens here is the on-chain signal
///         that an account is tied to the protocol's activity.
///
/// @dev This contract only custodies $HOODED and tracks per-account stake. It
///      grants no rewards itself; the benefit is the fee discount the
///      FeeController reads from {stakedOf}. Unstaking is immediate; there is no
///      lockup, so a user can always pull their tokens back.
contract HoodedStaking is ReentrancyGuard {
    using SafeTransferLib for IERC20;

    /// @notice The $HOODED token being staked.
    IERC20 public immutable hooded;

    mapping(address => uint256) public stakedOf;
    mapping(address => uint64) public stakedSince;
    uint256 public totalStaked;

    event Staked(address indexed account, uint256 amount, uint256 newBalance);
    event Unstaked(address indexed account, uint256 amount, uint256 newBalance);

    constructor(IERC20 hooded_) {
        if (address(hooded_) == address(0)) revert ZeroAddress();
        hooded = hooded_;
    }

    /// @notice Stakes `amount` of $HOODED from the caller.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();

        uint256 before = hooded.balanceOf(address(this));
        hooded.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = hooded.balanceOf(address(this)) - before;

        stakedOf[msg.sender] += received;
        stakedSince[msg.sender] = uint64(block.timestamp);
        totalStaked += received;

        emit Staked(msg.sender, received, stakedOf[msg.sender]);
    }

    /// @notice Unstakes `amount` of $HOODED back to the caller. Immediate, no
    ///         lockup.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidSpendAmount();
        uint256 bal = stakedOf[msg.sender];
        if (amount > bal) revert InsufficientStakedBalance();

        unchecked {
            stakedOf[msg.sender] = bal - amount;
        }
        totalStaked -= amount;

        hooded.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, stakedOf[msg.sender]);
    }
}
