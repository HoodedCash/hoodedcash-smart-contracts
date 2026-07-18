// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HoodedRegistry} from "../src/HoodedRegistry.sol";
import {DisclosureRegistry} from "../src/DisclosureRegistry.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";
import {IHoodedRegistry} from "../src/interfaces/IHoodedRegistry.sol";
import "../src/libraries/HoodedErrors.sol";

contract DisclosureIndexTest is Test {
    ProtocolConfig config;
    HoodedRegistry registry;
    DisclosureRegistry disclosures;

    address compliance = makeAddr("compliance");
    address gwen = makeAddr("gwen");
    address felix = makeAddr("felix");

    function setUp() public {
        config = new ProtocolConfig(compliance);
        registry = new HoodedRegistry(IProtocolConfig(address(config)));
        disclosures = new DisclosureRegistry(IHoodedRegistry(address(registry)));

        vm.prank(gwen);
        registry.createProfile("gwen", HoodedRegistry.AccountKind.Personal);
        vm.prank(felix);
        registry.createProfile("felix", HoodedRegistry.AccountKind.Personal);
    }

    function test_index_tracks_a_profiles_receipts_in_order() public {
        vm.startPrank(gwen);
        uint256 a = disclosures.file("tx-a", keccak256("auditor"), keccak256("proof-a"));
        uint256 b = disclosures.file("tx-b", keccak256("auditor"), keccak256("proof-b"));
        vm.stopPrank();

        assertEq(disclosures.receiptCountOf(gwen), 2);
        uint256[] memory ids = disclosures.receiptIdsOf(gwen);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
    }

    function test_index_is_scoped_per_profile() public {
        vm.prank(gwen);
        disclosures.file("tx-gwen", keccak256("auditor"), keccak256("proof"));
        vm.prank(felix);
        disclosures.file("tx-felix", keccak256("auditor"), keccak256("proof"));

        assertEq(disclosures.receiptCountOf(gwen), 1);
        assertEq(disclosures.receiptCountOf(felix), 1);
        assertEq(disclosures.receiptIdsOf(gwen)[0], 1);
        assertEq(disclosures.receiptIdsOf(felix)[0], 2);
    }

    function test_index_empty_for_unknown_profile() public view {
        assertEq(disclosures.receiptCountOf(address(0xdead)), 0);
        assertEq(disclosures.receiptIdsOf(address(0xdead)).length, 0);
    }
}
