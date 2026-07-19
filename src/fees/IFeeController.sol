// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IFeeController
/// @notice The onchain interface behind HoodedCash's "$HOODED reduces what you
///         pay" model. Every fund-moving contract quotes its protocol fee here,
///         and clients (the app, the SDK) call the same view to show a user
///         their live fee and discount before they transact.
///
/// @dev The discount is a function of how much $HOODED an account is tied to:
///      tokens staked in {HoodedStaking} count at full weight, tokens merely
///      held count at a reduced weight, and that combined balance maps to a
///      discount on the base fee. The more of the protocol you hold and stake,
///      the less you are taxed for using it.
interface IFeeController {
    /// @notice Quotes the protocol fee a `payer` owes on a transfer of `amount`
    ///         of a settlement token, after their $HOODED discount.
    /// @param payer The account whose $HOODED holdings and stake set the discount.
    /// @param amount Gross transfer amount, in the settlement token's units.
    /// @return feeAmount Fee due, in the settlement token's units.
    /// @return effectiveBps The realised fee rate in basis points, for display.
    function quoteFee(address payer, uint256 amount)
        external
        view
        returns (uint256 feeAmount, uint256 effectiveBps);

    /// @notice The discount, in basis points off the base fee, that `account`
    ///         currently earns from its held plus staked $HOODED.
    function discountBpsOf(address account) external view returns (uint256);

    /// @notice The combined, weighted $HOODED balance used to place `account`
    ///         on the discount curve (staked at full weight, held at partial).
    function loyaltyWeightOf(address account) external view returns (uint256);
}
