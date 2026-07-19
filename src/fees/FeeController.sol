// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IFeeController} from "./IFeeController.sol";
import {HoodedStaking} from "./HoodedStaking.sol";
import "../libraries/HoodedErrors.sol";

/// @title FeeController
/// @notice HoodedCash's protocol fee schedule and the home of the "$HOODED
///         reduces what you pay" discount. Fund-moving contracts call
///         {quoteFee} to price a transfer; the app and SDK call the same views
///         to show a user their live rate and discount.
///
/// @dev Fee math, all in basis points (1 bps = 0.01%):
///
///        grossFee   = amount * baseFeeBps / 10_000
///        discount   = discountBpsOf(payer)              // from held + staked $HOODED
///        netFee     = grossFee * (10_000 - discount) / 10_000
///        feeAmount  = min(netFee, feeCap)               // absolute cap, if set
///
///      The discount comes from a loyalty weight: staked $HOODED at full weight
///      plus held $HOODED at `heldWeightBps` of full weight. That weight is
///      matched against an ascending tier table; an account earns the discount
///      of the highest tier whose threshold it meets. Staking beats holding, and
///      holding beats nothing, which is exactly the intended incentive: the more
///      of the protocol you are tied to, the less you are taxed for using it.
///
///      Amounts and the cap are denominated in the settlement token's smallest
///      unit. The defaults assume a 6-decimal stablecoin (USDG): a 0.10% base
///      fee capped at 5 USDG, matching the published schedule. Weight thresholds
///      are in $HOODED's smallest unit (18 decimals).
contract FeeController is IFeeController {
    struct Tier {
        uint256 minWeight; // minimum loyalty weight, in $HOODED units (18 dp)
        uint16 discountBps; // discount off the base fee, in basis points
    }

    uint256 internal constant BPS = 10_000;

    /// @notice Authority allowed to retune the schedule (protocol multisig).
    address public authority;

    /// @notice The $HOODED token whose held balance feeds the loyalty weight.
    IERC20 public immutable hooded;

    /// @notice Staking vault whose staked balance feeds the loyalty weight.
    HoodedStaking public immutable staking;

    /// @notice Base fee rate before any discount, in basis points.
    uint16 public baseFeeBps;

    /// @notice Absolute fee cap in settlement-token units. Zero disables the cap.
    uint256 public feeCap;

    /// @notice Weight, in basis points of full weight, that merely-held $HOODED
    ///         contributes. Staked $HOODED always counts at full weight.
    uint16 public heldWeightBps;

    /// @notice Discount tiers, ascending by `minWeight`.
    Tier[] public tiers;

    event FeeScheduleUpdated(uint16 baseFeeBps, uint256 feeCap, uint16 heldWeightBps);
    event TiersUpdated(uint256 count);
    event AuthorityTransferred(address indexed newAuthority);

    modifier onlyAuthority() {
        if (msg.sender != authority) revert Unauthorized();
        _;
    }

    constructor(address authority_, IERC20 hooded_, HoodedStaking staking_) {
        if (
            authority_ == address(0) || address(hooded_) == address(0)
                || address(staking_) == address(0)
        ) {
            revert ZeroAddress();
        }
        authority = authority_;
        hooded = hooded_;
        staking = staking_;

        // Published defaults: 0.10% base fee, capped at 5 units (5 USDG at 6 dp),
        // held $HOODED counts at half the weight of staked $HOODED.
        baseFeeBps = 10;
        feeCap = 5_000_000;
        heldWeightBps = 5_000;

        // Ascending discount curve, thresholds in whole $HOODED (18 dp).
        tiers.push(Tier(1_000e18, 1_000)); // >= 1k HOODED: 10% off
        tiers.push(Tier(10_000e18, 2_500)); // >= 10k:      25% off
        tiers.push(Tier(100_000e18, 5_000)); // >= 100k:    50% off
        tiers.push(Tier(1_000_000e18, 7_500)); // >= 1M:    75% off
    }

    // ── Quoting ──────────────────────────────────────────────────────────────

    /// @inheritdoc IFeeController
    function quoteFee(address payer, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps)
    {
        uint256 gross = (amount * baseFeeBps) / BPS;
        uint256 discount = discountBpsOf(payer);
        uint256 net = (gross * (BPS - discount)) / BPS;
        feeAmount = (feeCap != 0 && net > feeCap) ? feeCap : net;
        effectiveBps = amount == 0 ? 0 : (feeAmount * BPS) / amount;
    }

    /// @inheritdoc IFeeController
    function discountBpsOf(address account) public view returns (uint256) {
        uint256 weight = loyaltyWeightOf(account);
        uint256 discount;
        uint256 n = tiers.length;
        for (uint256 i; i < n; ++i) {
            Tier storage t = tiers[i];
            if (weight >= t.minWeight) {
                discount = t.discountBps;
            } else {
                break; // tiers are ascending, so no later tier can match
            }
        }
        return discount;
    }

    /// @inheritdoc IFeeController
    function loyaltyWeightOf(address account) public view returns (uint256) {
        uint256 staked = staking.stakedOf(account);
        uint256 held = hooded.balanceOf(account);
        return staked + (held * heldWeightBps) / BPS;
    }

    /// @notice Convenience view combining the discount and the resulting quote.
    function feePreview(address payer, uint256 amount)
        external
        view
        returns (uint256 discountBps, uint256 feeAmount, uint256 effectiveBps)
    {
        discountBps = discountBpsOf(payer);
        uint256 gross = (amount * baseFeeBps) / BPS;
        uint256 net = (gross * (BPS - discountBps)) / BPS;
        feeAmount = (feeCap != 0 && net > feeCap) ? feeCap : net;
        effectiveBps = amount == 0 ? 0 : (feeAmount * BPS) / amount;
    }

    // ── Administration ─────────────────────────────────────────────────────────

    /// @notice Retunes the base fee, the cap, and the held-weight factor.
    function setSchedule(uint16 baseFeeBps_, uint256 feeCap_, uint16 heldWeightBps_)
        external
        onlyAuthority
    {
        if (baseFeeBps_ > BPS || heldWeightBps_ > BPS) revert InvalidFeeConfig();
        baseFeeBps = baseFeeBps_;
        feeCap = feeCap_;
        heldWeightBps = heldWeightBps_;
        emit FeeScheduleUpdated(baseFeeBps_, feeCap_, heldWeightBps_);
    }

    /// @notice Replaces the discount tier table. Tiers must be strictly ascending
    ///         by `minWeight` and no discount may exceed 100%.
    function setTiers(Tier[] calldata newTiers) external onlyAuthority {
        uint256 n = newTiers.length;
        for (uint256 i; i < n; ++i) {
            if (newTiers[i].discountBps > BPS) revert InvalidFeeConfig();
            if (i > 0 && newTiers[i].minWeight <= newTiers[i - 1].minWeight) {
                revert InvalidFeeConfig();
            }
        }
        delete tiers;
        for (uint256 i; i < n; ++i) {
            tiers.push(newTiers[i]);
        }
        emit TiersUpdated(n);
    }

    /// @notice Transfers the tuning authority.
    function transferAuthority(address newAuthority) external onlyAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        authority = newAuthority;
        emit AuthorityTransferred(newAuthority);
    }

    /// @notice Number of configured discount tiers.
    function tierCount() external view returns (uint256) {
        return tiers.length;
    }
}
