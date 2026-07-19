// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {AgentManager} from "../src/AgentManager.sol";
import {PaymentRequests} from "../src/PaymentRequests.sol";
import {HoodedStaking} from "../src/fees/HoodedStaking.sol";
import {FeeController} from "../src/fees/FeeController.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Exercises the "$HOODED reduces what you pay" fee model end to end:
///         the quoting math, the hold-plus-stake discount curve, and fee routing
///         through the agent and payment-request settlement paths.
contract FeeModelTest is Test {
    ProtocolConfig config;
    HoodedRegistry registry;
    AgentManager agents;
    PaymentRequests requests;
    HoodedStaking staking;
    FeeController fees;
    MockERC20 usdg; // 6 dp settlement token
    MockERC20 hooded; // 18 dp governance token

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address treasury = makeAddr("treasury");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");
    address vendor = makeAddr("vendor");
    address signer = makeAddr("signer");

    function usd(uint256 d) internal pure returns (uint256) {
        return d * 1e6;
    }

    function hood(uint256 d) internal pure returns (uint256) {
        return d * 1e18;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        hooded = new MockERC20("HoodedCash", "HOODED", 18);

        vm.prank(admin);
        config = new ProtocolConfig(compliance);
        registry = new HoodedRegistry(IProtocolConfig(address(config)));
        agents =
            new AgentManager(IProtocolConfig(address(config)), IHoodedRegistry(address(registry)));
        requests = new PaymentRequests(
            IProtocolConfig(address(config)), IHoodedRegistry(address(registry))
        );

        staking = new HoodedStaking(IERC20(address(hooded)));
        fees = new FeeController(admin, IERC20(address(hooded)), staking);

        vm.prank(admin);
        config.setFeeConfig(treasury, address(fees));

        vm.prank(gwen);
        registry.createProfile("gwen", HoodedRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", HoodedRegistry.AccountKind.Personal);

        usdg.mint(gwen, usd(1_000_000));
        usdg.mint(felix, usd(1_000_000));
    }

    // ── Quoting and the discount curve ─────────────────────────────────────────

    function test_base_fee_no_hooded() public view {
        // 0.10% of 1,000 USDG = 1 USDG, no discount.
        (uint256 fee, uint256 bps) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1));
        assertEq(bps, 10);
        assertEq(fees.discountBpsOf(gwen), 0);
    }

    function test_holding_earns_partial_discount() public {
        // Held counts at half weight: 20k held -> 10k weight -> 25% tier.
        hooded.mint(gwen, hood(20_000));
        assertEq(fees.loyaltyWeightOf(gwen), hood(10_000));
        assertEq(fees.discountBpsOf(gwen), 2_500);

        (uint256 fee,) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1) * 7_500 / 10_000); // 25% off => 0.75 USDG
    }

    function test_staking_beats_holding() public {
        // Staked counts at full weight: 100k staked -> 100k weight -> 50% tier.
        hooded.mint(gwen, hood(100_000));
        vm.startPrank(gwen);
        hooded.approve(address(staking), type(uint256).max);
        staking.stake(hood(100_000));
        vm.stopPrank();

        assertEq(fees.loyaltyWeightOf(gwen), hood(100_000));
        assertEq(fees.discountBpsOf(gwen), 5_000);

        (uint256 fee,) = fees.quoteFee(gwen, usd(1_000));
        assertEq(fee, usd(1) / 2); // 50% off
    }

    function test_top_tier_discount() public {
        hooded.mint(gwen, hood(1_000_000));
        vm.startPrank(gwen);
        hooded.approve(address(staking), type(uint256).max);
        staking.stake(hood(1_000_000));
        vm.stopPrank();
        assertEq(fees.discountBpsOf(gwen), 7_500); // 75% off, the deepest tier
    }

    function test_fee_cap_applies() public view {
        // 0.10% of 100,000 USDG = 100 USDG, capped at 5 USDG.
        (uint256 fee,) = fees.quoteFee(gwen, usd(100_000));
        assertEq(fee, usd(5));
    }

    function test_unstake_lowers_discount() public {
        hooded.mint(gwen, hood(100_000));
        vm.startPrank(gwen);
        hooded.approve(address(staking), type(uint256).max);

        // Staked: 100k weight -> 50% tier.
        staking.stake(hood(100_000));
        assertEq(fees.discountBpsOf(gwen), 5_000);

        // Unstaked: the 100k is back in the wallet, now only half-weighted, so
        // the discount drops to the 25% tier. Staking beats holding.
        staking.unstake(hood(100_000));
        vm.stopPrank();
        assertEq(fees.loyaltyWeightOf(gwen), hood(50_000));
        assertEq(fees.discountBpsOf(gwen), 2_500);

        // Move the tokens away entirely and the discount goes to zero.
        vm.prank(gwen);
        hooded.transfer(vendor, hood(100_000));
        assertEq(fees.discountBpsOf(gwen), 0);
    }

    // ── Fee routing through settlement ─────────────────────────────────────────

    function _fundedAgent() internal returns (uint256 agentId) {
        address[] memory none = new address[](0);
        vm.prank(gwen);
        agentId = agents.createAgent(
            signer,
            "bot",
            AgentManager.AutonomyTier.SemiAutonomous,
            address(usdg),
            usd(2_000),
            usd(10_000),
            usd(2_000),
            none,
            false
        );
        vm.startPrank(gwen);
        usdg.approve(address(agents), type(uint256).max);
        agents.fundAgent(agentId, usd(5_000));
        vm.stopPrank();
    }

    function test_agent_pay_charges_fee_to_treasury() public {
        // gwen stakes 10k HOODED -> 25% off.
        hooded.mint(gwen, hood(10_000));
        vm.startPrank(gwen);
        hooded.approve(address(staking), type(uint256).max);
        staking.stake(hood(10_000));
        vm.stopPrank();

        uint256 agentId = _fundedAgent();

        // Spend 1,000 USDG. Gross fee 1 USDG, 25% off => 0.75 USDG.
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        uint256 expectedFee = usd(1) * 7_500 / 10_000;
        assertEq(usdg.balanceOf(vendor), usd(1_000)); // recipient kept whole
        assertEq(usdg.balanceOf(treasury), expectedFee); // fee to treasury
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000) - expectedFee);
    }

    function test_agent_pay_no_fee_when_unconfigured() public {
        // Turn fees back off; settlement returns to a plain transfer.
        vm.prank(admin);
        config.setFeeConfig(address(0), address(0));

        uint256 agentId = _fundedAgent();
        vm.prank(signer);
        agents.payInvoice(agentId, vendor, usd(1_000), bytes32("inv"));

        assertEq(usdg.balanceOf(vendor), usd(1_000));
        assertEq(usdg.balanceOf(treasury), 0);
        assertEq(agents.vaultBalance(agentId), usd(5_000) - usd(1_000));
    }

    function test_payment_request_charges_fee_on_top() public {
        // gwen requests 500 USDG; felix (no HOODED) pays it plus the fee.
        vm.prank(gwen);
        uint256 id = requests.create(
            gwen,
            address(usdg),
            false,
            usd(500),
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 days)
        );

        uint256 gwenBefore = usdg.balanceOf(gwen);
        uint256 felixBefore = usdg.balanceOf(felix);

        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(500), bytes32(0));
        vm.stopPrank();

        uint256 fee = usd(500) * 10 / 10_000; // 0.10% = 0.5 USDG, no discount
        assertEq(usdg.balanceOf(gwen), gwenBefore + usd(500)); // requester whole
        assertEq(usdg.balanceOf(treasury), fee);
        assertEq(usdg.balanceOf(felix), felixBefore - usd(500) - fee); // payer pays fee
    }

    function test_only_authority_tunes_schedule() public {
        vm.expectRevert();
        vm.prank(gwen);
        fees.setSchedule(20, usd(10), 5_000);

        vm.prank(admin);
        fees.setSchedule(20, usd(10), 5_000);
        assertEq(fees.baseFeeBps(), 20);
    }
}
