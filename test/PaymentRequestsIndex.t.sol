// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {PaymentRequests} from "../src/PaymentRequests.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import "../src/libraries/HoodedErrors.sol";

contract PaymentRequestsIndexTest is Test {
    ProtocolConfig config;
    HoodedRegistry registry;
    PaymentRequests requests;
    MockERC20 usdg;

    address admin = makeAddr("admin");
    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    uint256 constant USDG_ONE = 1e6;

    function usd(uint256 dollars) internal pure returns (uint256) {
        return dollars * USDG_ONE;
    }

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);

        vm.prank(admin);
        config = new ProtocolConfig(compliance);
        registry = new HoodedRegistry(IProtocolConfig(address(config)));
        requests = new PaymentRequests(
            IProtocolConfig(address(config)), IHoodedRegistry(address(registry))
        );

        vm.prank(gwen);
        registry.createProfile("gwen", HoodedRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", HoodedRegistry.AccountKind.Personal);
        usdg.mint(felix, usd(1_000));
    }

    function _create(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = requests.create(
            who,
            address(usdg),
            false,
            amount,
            bytes32(0),
            bytes32(0),
            uint64(block.timestamp + 1 hours)
        );
    }

    function test_index_lists_a_requesters_requests() public {
        uint256 a = _create(gwen, usd(10));
        uint256 b = _create(gwen, usd(20));

        assertEq(requests.requestCountOf(gwen), 2);
        uint256[] memory ids = requests.requestIdsOf(gwen);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(requests.requestCountOf(felix), 0);
    }

    function test_is_fulfillable_lifecycle() public {
        uint256 id = _create(gwen, usd(25));
        assertTrue(requests.isFulfillable(id));

        // Paying it closes the window.
        vm.startPrank(felix);
        usdg.approve(address(requests), type(uint256).max);
        requests.fulfill(id, usd(25), bytes32(0));
        vm.stopPrank();
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_after_cancel() public {
        uint256 id = _create(gwen, usd(25));
        vm.prank(gwen);
        requests.cancel(id);
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_after_expiry() public {
        uint256 id = _create(gwen, usd(25));
        vm.warp(block.timestamp + 2 hours);
        assertFalse(requests.isFulfillable(id));
    }

    function test_is_fulfillable_false_for_unknown_id() public view {
        assertFalse(requests.isFulfillable(999));
    }
}
