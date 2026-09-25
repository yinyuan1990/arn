// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {Treasury} from "../src/Treasury.sol";

/// Weekly settlement of the protocol share (22% of the 1% pool fee) in exact parts of 22: 16 → reserve, 5 → buyback
/// fund (burns done by hand there), 1 → dev team. In trade terms that is 0.16% / 0.05% / 0.01%, plus the creator's
/// 0.78%. All three payout addresses are fixed in the constructor (`eco`, `buybackFund`, `dev` in Base).
contract TreasuryTest is Base {
    function _fund(uint256 amt) internal {
        usdc.mint(address(treasury), amt);
    }

    function test_treasury_splitIsImmutableConstants() public view {
        assertEq(treasury.ECO_PARTS(), 16);
        assertEq(treasury.BUYBACK_PARTS(), 5);
        assertEq(treasury.DEV_PARTS(), 1);
        assertEq(treasury.ECO_PARTS() + treasury.BUYBACK_PARTS() + treasury.DEV_PARTS(), treasury.TOTAL_PARTS());
        assertEq(treasury.ECO_BPS() + treasury.BUYBACK_BPS() + treasury.DEV_BPS(), 10_000, "display values add up");
        assertEq(treasury.INTERVAL(), 7 days);
        // of the 1% pool fee: 78 creator + 22 protocol
        assertEq(uint256(factory.CREATOR_SHARE_BPS()) / 100 + treasury.TOTAL_PARTS(), 100);
    }

    function test_treasury_addressesFixedAtDeploy() public {
        assertEq(treasury.ecoFund(), eco);
        assertEq(treasury.buybackFund(), buybackFund);
        assertEq(treasury.devFund(), dev);
        assertEq(locker.treasury(), address(treasury));
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), address(0), buybackFund, dev, owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), eco, address(0), dev, owner);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(address(usdc), address(router), eco, buybackFund, address(0), owner);
    }

    function test_treasury_executePaysAllThree() public {
        _fund(22e6);

        treasury.execute();
        assertEq(usdc.balanceOf(eco), 16e6, "16/22 to the reserve");
        assertEq(usdc.balanceOf(buybackFund), 5e6, "5/22 to the buyback fund");
        assertEq(usdc.balanceOf(dev), 1e6, "1/22 to the dev team");
        assertEq(usdc.balanceOf(address(treasury)), 0, "fully settled");
        assertEq(treasury.pendingRevenue(), 0);
        assertEq(treasury.totalToEco(), 16e6);
        assertEq(treasury.totalToBuyback(), 5e6);
        assertEq(treasury.totalToDev(), 1e6);
    }

    function test_treasury_anyoneCanExecute() public {
        _fund(22e6);
        vm.prank(buyer);
        treasury.execute();
        assertEq(usdc.balanceOf(buybackFund), 5e6);
    }

    function test_treasury_weeklyCadenceEnforced() public {
        _fund(22e6);
        treasury.execute();

        _fund(22e6);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, block.timestamp + 7 days));
        treasury.execute();

        vm.warp(block.timestamp + 7 days);
        treasury.execute();
        assertEq(usdc.balanceOf(eco), 32e6);
        assertEq(usdc.balanceOf(buybackFund), 10e6);
        assertEq(usdc.balanceOf(dev), 2e6);
    }

    function test_treasury_nothingToDoReverts() public {
        vm.expectRevert(Treasury.NothingToDo.selector);
        treasury.execute();
    }

    function test_treasury_roundingDustCarriesOver() public {
        _fund(33); // 16/22 = 24, 5/22 = 7, 1/22 = 1 → 32 paid, 1 left
        treasury.execute();
        assertEq(usdc.balanceOf(eco), 24);
        assertEq(usdc.balanceOf(buybackFund), 7);
        assertEq(usdc.balanceOf(dev), 1);
        assertEq(usdc.balanceOf(address(treasury)), 1, "dust waits for the next cycle");
    }
}
