// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title AltBn128
/// @notice Group operations on the alt_bn128 (BN254) curve used by HoodedCash's
///         confidential token. Elliptic-curve additions and scalar
///         multiplications run through the EVM precompiles at 0x06 and 0x07,
///         which Robinhood Chain inherits from the Arbitrum Nitro stack, so
///         encrypted balances can be updated homomorphically onchain.
///
/// @dev ElGamal ciphertexts in the confidential token are pairs of points on
///      this curve. Homomorphic addition of two ciphertexts is a component-wise
///      point addition, which is what lets a verified transfer debit the sender
///      and credit the recipient without ever revealing the amount.
library AltBn128 {
    /// @notice A point in G1. The identity element is encoded as (0, 0), the
    ///         convention the precompiles use.
    struct Point {
        uint256 x;
        uint256 y;
    }

    /// @dev Field modulus of the curve.
    uint256 internal constant FIELD_MODULUS =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    error ECAddFailed();
    error ECMulFailed();

    /// @notice The conventional G1 generator, used as the base for encoding a
    ///         plaintext amount `m` as the point `m * G`.
    function generator() internal pure returns (Point memory) {
        return Point(1, 2);
    }

    /// @notice The identity element (point at infinity).
    function zero() internal pure returns (Point memory) {
        return Point(0, 0);
    }

    /// @notice Returns the additive inverse of `p`, so `add(p, negate(p))` is the
    ///         identity. Used to subtract an amount from an encrypted balance.
    function negate(Point memory p) internal pure returns (Point memory) {
        if (p.x == 0 && p.y == 0) return Point(0, 0);
        return Point(p.x, FIELD_MODULUS - (p.y % FIELD_MODULUS));
    }

    /// @notice Point addition via the 0x06 precompile.
    function add(Point memory a, Point memory b) internal view returns (Point memory r) {
        uint256[4] memory input = [a.x, a.y, b.x, b.y];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x06, input, 0x80, r, 0x40)
        }
        if (!ok) revert ECAddFailed();
    }

    /// @notice Scalar multiplication via the 0x07 precompile.
    function mul(Point memory p, uint256 s) internal view returns (Point memory r) {
        uint256[3] memory input = [p.x, p.y, s];
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x07, input, 0x60, r, 0x40)
        }
        if (!ok) revert ECMulFailed();
    }

    /// @notice Encodes a plaintext scalar `m` as the curve point `m * G`, the
    ///         representation a deposit adds to an encrypted balance.
    function encode(uint256 m) internal view returns (Point memory) {
        return mul(generator(), m);
    }
}
