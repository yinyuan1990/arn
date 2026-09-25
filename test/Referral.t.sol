// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {CreatorFeeSplitter} from "../src/CreatorFeeSplitter.sol";

/// Promoter commission (scheme B): pool = creator share × referralBps × referred-volume share. On chain the splitter
/// reserves referralBps of every USDC (upper bound), pays the rest to the creator at once, and the keeper settles
/// the pool: promoters by referred volume, the unreferred remainder back to the creator.
contract ReferralTest is Base {
    address r1 = makeAddr("promoter1");
    address r2 = makeAddr("promoter2");

    function _launch(string memory sym, uint16 bps) internal returns (address token, CreatorFeeSplitter s) {
        LaunchFactory.LaunchParams memory p = launchParams(sym, 0);
        p.referralBps = bps;
        vm.prank(creator);
        (token,,) = factory.launch(p);
        s = splitterOf(token);
    }

    /// Simulates the FeeLocker pushing the creator share to the splitter.
    function _arrive(CreatorFeeSplitter s, uint256 amt) internal {
        usdc.mint(address(s), amt);
    }

    function _settle(CreatorFeeSplitter s, uint256 poolAmount, address[] memory who, uint256[] memory amts) internal {
        vm.prank(keeper);
        s.settle(poolAmount, who, amts);
    }

    function _two(address a, address b) internal pure returns (address[] memory w) {
        w = new address[](2);
        w[0] = a;
        w[1] = b;
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    // ------------------------------------------------------------ reserve on arrival

    function test_referral_offByDefault_everythingToCreator() public {
        (, CreatorFeeSplitter s) = _launch("OFF", 0);
        uint256 before = usdc.balanceOf(creator);
        _arrive(s, 100e6);
        s.sync();
        assertEq(usdc.balanceOf(creator) - before, 100e6);
        assertEq(s.pool(), 0);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    function test_referral_reservesBpsAndPaysTheRestAtOnce() public {
        (, CreatorFeeSplitter s) = _launch("RSV", 2_000);
        uint256 before = usdc.balanceOf(creator);
        _arrive(s, 100e6);
        vm.prank(buyer); // permissionless
        s.sync();
        assertEq(usdc.balanceOf(creator) - before, 80e6, "80% on the spot");
        assertEq(s.pool(), 20e6, "20% reserved as the upper bound");
        assertEq(s.poolSince(), block.timestamp);
        // idempotent: nothing new, nothing moves
        s.sync();
        assertEq(s.pool(), 20e6);
    }

    // ------------------------------------------------------------ settle

    function test_referral_settlePaysPromotersAndReturnsTheRest() public {
        (, CreatorFeeSplitter s) = _launch("SET", 2_000);
        _arrive(s, 100e6);
        s.sync(); // pool 20
        uint256 c0 = usdc.balanceOf(creator);
        // 30% of volume referred: 60% of it by r1, 40% by r2 → 20 × 0.3 = 6 → 3.6 / 2.4
        _settle(s, 20e6, _two(r1, r2), _two(3.6e6, 2.4e6));
        assertEq(usdc.balanceOf(r1), 3.6e6);
        assertEq(usdc.balanceOf(r2), 2.4e6);
        assertEq(usdc.balanceOf(creator) - c0, 14e6, "unreferred 70% of the pool back to the creator");
        assertEq(s.pool(), 0);
        assertEq(s.poolSince(), 0);
        assertEq(s.totalToReferrers(), 6e6);
        assertEq(s.totalToCreator(), 80e6 + 14e6);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    function test_referral_settleCannotExceedThePool() public {
        (, CreatorFeeSplitter s) = _launch("CAP", 2_000);
        _arrive(s, 100e6);
        s.sync(); // pool 20

        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.ExceedsPool.selector);
        s.settle(20e6 + 1, new address[](0), new uint256[](0));

        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.ExceedsPool.selector);
        s.settle(20e6, _two(r1, r2), _two(15e6, 5e6 + 1));

        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.LengthMismatch.selector);
        s.settle(20e6, _two(r1, r2), new uint256[](1));

        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.ZeroAddress.selector);
        s.settle(20e6, _two(r1, address(0)), _two(1e6, 1e6));

        // the whole pool to promoters is allowed (100% referred volume)
        _settle(s, 20e6, _two(r1, r2), _two(15e6, 5e6));
        assertEq(s.pool(), 0);
    }

    function test_referral_onlyKeeperSettles() public {
        (, CreatorFeeSplitter s) = _launch("KPR", 2_000);
        _arrive(s, 100e6);
        s.sync();
        address[3] memory who = [creator, owner, buyer];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(CreatorFeeSplitter.OnlyKeeper.selector);
            s.settle(20e6, _two(r1, r2), _two(1e6, 1e6));
        }
        // rotating the keeper on the hub takes effect for every splitter
        address k2 = makeAddr("keeper2");
        vm.prank(owner);
        hub.setKeeper(k2);
        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.OnlyKeeper.selector);
        s.settle(20e6, new address[](0), new uint256[](0));
        vm.prank(k2);
        s.settle(20e6, new address[](0), new uint256[](0));
        assertEq(s.pool(), 0);
    }

    function test_referral_tooManyReferrersRejected() public {
        (, CreatorFeeSplitter s) = _launch("MANY", 2_000);
        uint256 n = s.MAX_REFERRERS() + 1;
        vm.prank(keeper);
        vm.expectRevert(CreatorFeeSplitter.TooManyReferrers.selector);
        s.settle(0, new address[](n), new uint256[](n));
    }

    /// Fees that arrive after the keeper took its snapshot stay in the pool for the next round.
    function test_referral_snapshotLeavesLaterFundsForNextRound() public {
        (, CreatorFeeSplitter s) = _launch("SNAP", 2_000);
        _arrive(s, 100e6);
        s.sync(); // pool 20 — keeper computes on this
        _arrive(s, 50e6); // arrives before the settle tx lands; settle syncs it first → pool 30
        uint256 c0 = usdc.balanceOf(creator);
        _settle(s, 20e6, _two(r1, r2), _two(2e6, 0));
        assertEq(s.pool(), 10e6, "the later 20% of 50 waits");
        assertEq(usdc.balanceOf(creator) - c0, 40e6 + 18e6, "80% of the new 50 + unreferred 18 of the snapshot");
        assertEq(s.poolSince(), block.timestamp, "remaining pool restarts the release clock");
    }

    // ------------------------------------------------------------ safety valve / settings

    function test_referral_creatorReleasesAfterDelayIfKeeperIsGone() public {
        (, CreatorFeeSplitter s) = _launch("REL", 2_000);
        _arrive(s, 100e6);
        s.sync();
        uint256 since = s.poolSince();

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(CreatorFeeSplitter.TooEarly.selector, since + 7 days));
        s.release();

        vm.warp(since + 7 days);
        vm.prank(buyer);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.release();

        uint256 c0 = usdc.balanceOf(creator);
        vm.prank(creator);
        s.release();
        assertEq(usdc.balanceOf(creator) - c0, 20e6);
        assertEq(s.pool(), 0);
    }

    function test_referral_changingBpsSyncsPendingAtTheOldRate() public {
        (, CreatorFeeSplitter s) = _launch("BPS", 2_000);
        _arrive(s, 100e6); // not synced yet
        vm.prank(creator);
        s.setReferralBps(0);
        assertEq(s.pool(), 20e6, "pending fees were earned under 20%");
        assertEq(s.referralBps(), 0);
        _arrive(s, 100e6);
        s.sync();
        assertEq(s.pool(), 20e6, "nothing more reserved once off");

        vm.prank(buyer);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.setReferralBps(1_000);
        vm.prank(creator);
        vm.expectRevert(CreatorFeeSplitter.BpsTooHigh.selector);
        s.setReferralBps(5_001);
        vm.prank(creator);
        s.setReferralBps(5_000);
        assertEq(s.referralBps(), 5_000);
    }

    function test_referral_exitNeedsAnEmptyPool() public {
        (address token, CreatorFeeSplitter s) = _launch("EXT", 2_000);
        _arrive(s, 100e6);
        s.sync();
        address mine = makeAddr("mine");
        vm.prank(creator);
        vm.expectRevert(CreatorFeeSplitter.PoolNotEmpty.selector);
        s.exit(mine);

        _settle(s, 20e6, _two(r1, r2), _two(1e6, 1e6));
        vm.prank(creator);
        s.exit(mine);
        (,,,,, address payout,,) = locker.locks(token);
        assertEq(payout, mine);
    }

    function test_referral_blockedPromoterIsParkedNotLost() public {
        (, CreatorFeeSplitter s) = _launch("BLK", 2_000);
        _arrive(s, 100e6);
        s.sync();
        usdc.setBlocked(r1, true);
        _settle(s, 20e6, _two(r1, r2), _two(5e6, 5e6)); // must not revert
        assertEq(s.claimable(r1), 5e6);
        assertEq(usdc.balanceOf(r2), 5e6);
        // parked money is not mistaken for new revenue
        uint256 c0 = usdc.balanceOf(creator);
        s.sync();
        assertEq(usdc.balanceOf(creator), c0);
        assertEq(s.pool(), 0);

        usdc.setBlocked(r1, false);
        vm.prank(r1);
        s.claim();
        assertEq(usdc.balanceOf(r1), 5e6);
        assertEq(s.totalClaimable(), 0);
        vm.prank(r1);
        vm.expectRevert(CreatorFeeSplitter.NothingToClaim.selector);
        s.claim();
    }

    function test_referral_selfReferralIsAllowed() public {
        (, CreatorFeeSplitter s) = _launch("SELF", 2_000);
        _arrive(s, 100e6);
        s.sync();
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = buyer; // a buyer who used his own link
        a[0] = 4e6;
        _settle(s, 20e6, w, a);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    // ------------------------------------------------------------ end to end: the formula

    /// Real trades through the pool: pool paid to promoters = 78% × referralBps × referred share of the fees.
    function test_referral_endToEndMatchesTheFormula() public {
        (address token, CreatorFeeSplitter s) = _launch("E2E", 2_500);
        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);

        uint256 c0 = usdc.balanceOf(creator);
        uint256 t0 = usdc.balanceOf(address(treasury));
        (uint256 q, uint256 f) = distributeAndSync(token, 0);
        uint256 fees = q + f;
        uint256 creatorShare = (fees * 7_800) / 10_000;
        assertEq(usdc.balanceOf(address(treasury)) - t0, fees - creatorShare, "22% to the protocol");
        uint256 pool = s.pool();
        assertEq(pool, (creatorShare * 2_500) / 10_000);
        assertEq(usdc.balanceOf(creator) - c0, creatorShare - pool);

        // keeper: 40% of the period's volume was referred, all by r1
        uint256 toR1 = (pool * 40) / 100;
        address[] memory w = new address[](1);
        uint256[] memory a = new uint256[](1);
        w[0] = r1;
        a[0] = toR1;
        _settle(s, pool, w, a);

        assertApproxEqAbs(usdc.balanceOf(r1), (fees * 7_800 * 2_500 * 40) / (10_000 * 10_000 * 100), 2);
        assertEq(usdc.balanceOf(creator) - c0, creatorShare - toR1, "creator keeps everything unreferred");
        assertEq(usdc.balanceOf(address(s)), 0);
    }
}
