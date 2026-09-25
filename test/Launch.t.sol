// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.t.sol";
import {LaunchFactory} from "../src/LaunchFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FeeLocker} from "../src/FeeLocker.sol";
import {ReferralHub} from "../src/ReferralHub.sol";
import {CreatorFeeSplitter} from "../src/CreatorFeeSplitter.sol";
import {PriceMath} from "../src/libraries/PriceMath.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3.sol";

contract LaunchTest is Base {
    uint256 constant SUPPLY = 1_000_000_000e18;

    // ------------------------------------------------------------ launch

    function test_launch_createsPoolLocksLpForFree() public {
        uint256 ecoBefore = usdc.balanceOf(eco);
        uint256 creatorBefore = usdc.balanceOf(creator);
        (address token, address pool) = doLaunch(creator, "AAA", 0);

        LaunchToken t = LaunchToken(token);
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.liquidityPool(), pool);
        assertEq(uni.getPool(token, address(usdc), 10_000), pool);

        (uint256 tokenId,,,,,,, bool exists) = locker.locks(token);
        assertTrue(exists);
        assertEq(nfpm.ownerOf(tokenId), address(locker));

        // whole supply is in the pool (minus dust sent to treasury)
        uint256 inPool = t.balanceOf(pool);
        uint256 dust = t.balanceOf(address(treasury));
        assertEq(inPool + dust, SUPPLY);
        assertLt(dust, 1e18, "dust should be negligible");
        assertEq(t.balanceOf(address(factory)), 0);

        // launching is free: nobody was charged
        assertEq(usdc.balanceOf(eco), ecoBefore);
        assertEq(usdc.balanceOf(creator), creatorBefore);

        // the lock pays this token's splitter, which pays the creator
        (,,,,, address payout,,) = locker.locks(token);
        assertEq(payout, hub.splitterOf(token));
        assertEq(payout, hub.predictSplitter(token));
        assertEq(splitterOf(token).creator(), creator);
        assertEq(splitterOf(token).referralBps(), 0, "referral off by default");

        // spot mcap ≈ platform opening mcap (within 1 tick ≈ 0.01% + spacing 2%)
        assertApproxEqRel(spotMcap(token, pool), factory.startMcapUsdc(), 0.03e18);
    }

    function test_launch_hubIsRequired() public {
        assertEq(address(factory.referralHub()), address(hub));
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(
            address(uni), address(nfpm), address(router), address(usdc), address(locker), address(treasury), address(0), owner
        );
    }

    /// @dev Arm: launching is free — a wallet with no USDC and no approval can launch.
    function test_launch_isFree() public {
        assertEq(factory.creationFee(), 0);
        assertEq(factory.CREATOR_SHARE_BPS(), 7_800);
        address broke = makeAddr("broke");
        LaunchFactory.LaunchParams memory p = launchParams("NOFEE", 0);
        vm.prank(broke);
        (address token,,) = factory.launch(p);
        assertEq(splitterOf(token).creator(), broke);
    }

    function test_launch_referralBpsSetAtLaunchAndCapped() public {
        LaunchFactory.LaunchParams memory p = launchParams("REF", 0);
        p.referralBps = 2_000;
        vm.prank(creator);
        (address token,,) = factory.launch(p);
        assertEq(splitterOf(token).referralBps(), 2_000);

        p = launchParams("REF2", 0);
        p.referralBps = 5_001;
        vm.prank(creator);
        vm.expectRevert(CreatorFeeSplitter.BpsTooHigh.selector);
        factory.launch(p);
    }

    function test_hub_onlyFactoryCreates_onlyOwnerSetsKeeper() public {
        vm.expectRevert(ReferralHub.OnlyFactory.selector);
        hub.create(makeAddr("t"), creator, 0);
        vm.prank(buyer);
        vm.expectRevert();
        hub.setKeeper(buyer);
        vm.prank(owner);
        vm.expectRevert(ReferralHub.AlreadySet.selector);
        hub.setFactory(buyer);
        vm.prank(owner);
        hub.setKeeper(buyer);
        assertEq(hub.keeper(), buyer);
        // the implementation can never be initialized
        CreatorFeeSplitter impl = CreatorFeeSplitter(hub.implementation());
        vm.expectRevert(CreatorFeeSplitter.OnlyHub.selector);
        impl.initialize(makeAddr("t"), creator, 0);
    }

    /// @dev Launch params are constants — no setter exists, the owner has no function left on
    ///      the factory, and the values are exactly what the docs promise.
    function test_launch_paramsAreConstants() public {
        assertEq(factory.graduationThreshold(), 10_000e6);
        assertEq(factory.protectionBlocks(), 20);
        assertEq(factory.maxHoldBps(), 500);
        assertEq(factory.maxBuyBps(), 550);
        assertEq(factory.startMcapUsdc(), 5_000e6);
        // the old setter selector is gone: the call hits no function and reverts
        vm.prank(owner);
        (bool ok,) = address(factory).call(
            abi.encodeWithSignature("setLaunchParams(uint256,uint256,uint16,uint16,uint256)", 1_000e6, 20, 500, 550, 5_000e6)
        );
        assertFalse(ok);
        assertEq(factory.startMcapUsdc(), 5_000e6);
    }

    function test_launch_initialBuyGoesToCreator() public {
        (address token,) = doLaunch(creator, "DDD", 100e6);
        uint256 bal = LaunchToken(token).balanceOf(creator);
        assertGt(bal, 0);
        // 100 USDC into a $5k mcap pool: roughly 2% of supply, under the 5.5% cap
        assertLt(bal, (SUPPLY * 550) / 10_000);
    }

    /// @dev Fair launch: the creator has no price input; every token opens at the same market cap.
    function test_launch_everyTokenOpensAtSameMcap() public {
        uint256 target = factory.startMcapUsdc();
        assertEq(target, 5_000e6);
        for (uint256 i; i < 6; ++i) {
            (address token, address pool) = doLaunch(creator, string.concat("S", vm.toString(i)), 0);
            assertApproxEqRel(spotMcap(token, pool), target, 0.03e18);
        }
    }

    /// @dev Token addresses come from CREATE2 (salt = creator, count, prev blockhash), so orientation flips
    ///      pseudo-randomly. Ensure both work and that the prediction helper matches the factory.
    function test_launch_bothOrientations() public {
        bool seen0;
        bool seen1;
        for (uint256 i; i < 40 && !(seen0 && seen1); ++i) {
            string memory sym = string.concat("T", vm.toString(i));
            address predicted = nextTokenAddress(creator, sym);
            bool isToken0 = predicted < address(usdc);
            (address token, address pool) = doLaunch(creator, sym, 0);
            assertEq(token, predicted, "CREATE2 prediction");
            assertEq(token < address(usdc), isToken0);
            assertApproxEqRel(spotMcap(token, pool), 5_000e6, 0.03e18);
            // buy works in either orientation
            vm.roll(block.number + 30);
            uint256 out = buy(buyer, token, 50e6);
            assertGt(out, 0);
            if (isToken0) seen0 = true;
            else seen1 = true;
        }
        assertTrue(seen0 && seen1, "need both orientations covered");
    }

    // ------------------------------------------------------------ trading & price

    function test_trade_buyRaisesPriceSellLowers() public {
        (address token, address pool) = doLaunch(creator, "FFF", 0);
        vm.roll(block.number + 30);
        uint256 m0 = spotMcap(token, pool);
        uint256 out = buy(buyer, token, 500e6);
        uint256 m1 = spotMcap(token, pool);
        assertGt(m1, m0);
        sell(buyer, token, out / 2);
        uint256 m2 = spotMcap(token, pool);
        assertLt(m2, m1);
        assertGt(m2, m0);
    }

    // ------------------------------------------------------------ launch protection

    function test_protection_launchBlockOnlyCreator() public {
        (address token,) = doLaunch(creator, "GGG", 0);
        // same block: a stranger cannot buy
        vm.expectRevert();
        buy(buyer, token, 10e6);
        // the creator can
        uint256 out = buy(creator, token, 10e6);
        assertGt(out, 0);
    }

    function test_protection_capsDuringWindowThenLifted() public {
        (address token,) = doLaunch(creator, "HHH", 0);
        vm.roll(block.number + 1);
        // 5.5% of supply at $5k mcap ≈ $275+ of USDC; buying $2,000 would exceed maxBuy
        vm.expectRevert();
        buy(buyer, token, 2_000e6);
        // small buys fine
        buy(buyer, token, 100e6);
        // accumulate past 5% hold cap → revert
        vm.expectRevert();
        buy(buyer, token, 400e6);
        // sells are never restricted
        sell(buyer, token, LaunchToken(token).balanceOf(buyer) / 2);
        // after the window everything is allowed
        vm.roll(block.number + 25);
        uint256 out = buy(buyer, token, 5_000e6);
        assertGt(out, (SUPPLY * 550) / 10_000);
    }

    // ------------------------------------------------------------ fees

    /// @dev Creator and protocol receive USDC only; the token-side fee is sold into the pool first.
    function test_fees_distributeSplits75_25_usdcOnly() public {
        (address token,) = doLaunch(creator, "III", 0);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 1_000e6); // 1% fee = 10 USDC accrues to the position
        sell(buyer, token, out / 2); // token-side fee accrues too

        uint256 cU = usdc.balanceOf(creator);
        uint256 tU = usdc.balanceOf(address(treasury));
        uint256 cT = LaunchToken(token).balanceOf(creator);
        uint256 lockerTokens = LaunchToken(token).balanceOf(address(locker));

        (uint256 usdcCollected, uint256 usdcFromToken) = distributeAndSync(token, 0);
        assertApproxEqAbs(usdcCollected, 10e6, 2); // 1% of 1,000 USDC
        assertGt(usdcFromToken, 0, "token-side fee was converted");

        uint256 total = usdcCollected + usdcFromToken;
        uint256 share = (total * 7_800) / 10_000;
        assertEq(usdc.balanceOf(creator) - cU, share);
        assertEq(usdc.balanceOf(address(treasury)) - tU, total - share);

        // nobody received launch tokens, and none are stuck in the locker
        assertEq(LaunchToken(token).balanceOf(creator), cT);
        assertEq(LaunchToken(token).balanceOf(address(locker)), lockerTokens);
        assertEq(locker.unconvertedTokenFees(token), 0);

        // second distribute: no new USDC fees; the only thing left is the 1% pool fee our own conversion
        // swap just generated (a tail ~1% of the previous conversion), and it must not revert
        (uint256 q2, uint256 f2) = locker.distribute(token, 0);
        assertEq(q2, 0);
        assertLt(f2, usdcFromToken / 50);
    }

    /// @dev If the token→USDC swap fails the slippage guard, the tokens are kept and the USDC payout still happens.
    function test_fees_swapFailureDefersTokensButPaysUsdc() public {
        (address token,) = doLaunch(creator, "JJ2", 0);
        vm.roll(block.number + 30);
        uint256 out = buy(buyer, token, 1_000e6);
        sell(buyer, token, out / 2);

        uint256 cU = usdc.balanceOf(creator);
        // absurd minOut → swap reverts inside try/catch
        vm.expectEmit(true, false, false, false);
        emit FeeLocker.TokenFeesDeferred(token, 0);
        (uint256 usdcCollected, uint256 usdcFromToken) = distributeAndSync(token, type(uint256).max);
        assertGt(usdcCollected, 0);
        assertEq(usdcFromToken, 0);
        assertGt(locker.unconvertedTokenFees(token), 0);
        // USDC part was still paid 78/22
        assertEq(usdc.balanceOf(creator) - cU, (usdcCollected * 7_800) / 10_000);

        // next run with a sane guard converts the backlog
        uint256 backlog = locker.unconvertedTokenFees(token);
        (, uint256 f2) = locker.distribute(token, 0);
        assertGt(f2, 0);
        assertEq(locker.unconvertedTokenFees(token), 0);
        assertGt(backlog, 0);
    }

    function test_fees_blocklistedCreatorParkedAsClaimable() public {
        (address token,) = doLaunch(creator, "JJJ", 0);
        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);

        usdc.setBlocked(creator, true);
        uint256 tU = usdc.balanceOf(address(treasury));
        (uint256 q, uint256 f) = distributeAndSync(token, 0); // must NOT revert
        uint256 share = ((q + f) * 7_800) / 10_000;
        CreatorFeeSplitter s = splitterOf(token);
        assertEq(s.claimable(creator), share, "parked in the splitter");
        assertEq(s.totalClaimable(), share);
        assertEq(usdc.balanceOf(address(treasury)) - tU, (q + f) - share, "protocol still paid");
        // a later sync must not treat the parked amount as new revenue
        s.sync();
        assertEq(s.claimable(creator), share);

        // once unblocked, creator claims
        usdc.setBlocked(creator, false);
        uint256 before = usdc.balanceOf(creator);
        vm.prank(creator);
        s.claim();
        assertEq(usdc.balanceOf(creator) - before, share);
        assertEq(s.claimable(creator), 0);
    }

    // ------------------------------------------------------------ payout address / community takeover

    /// Arm: the lock pays the splitter; the creator rotates its wallet on the splitter, nobody else can.
    function test_payout_creatorRotatesViaSplitter_strangerCannot() public {
        (address token,) = doLaunch(creator, "KKK", 0);
        CreatorFeeSplitter s = splitterOf(token);
        address newWallet = makeAddr("newWallet");
        vm.prank(creator);
        s.setCreator(newWallet);
        assertEq(s.creator(), newWallet);

        vm.prank(buyer);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.setCreator(buyer);
        // the old wallet lost control immediately
        vm.prank(creator);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.setCreator(creator);

        // nobody (owner, creator, stranger) can point the lock elsewhere behind the splitter's back
        address[3] memory who = [owner, creator, buyer];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(FeeLocker.NotCreator.selector);
            locker.setPayout(token, who[i]);
        }

        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);
        uint256 before = usdc.balanceOf(newWallet);
        distributeAndSync(token, 0);
        assertGt(usdc.balanceOf(newWallet) - before, 0);
    }

    function test_payout_creatorCanPickFeeWalletAtLaunch() public {
        address feeWallet = makeAddr("feeWallet");
        LaunchFactory.LaunchParams memory p = launchParams("FEE", 0);
        p.payout = feeWallet;
        vm.prank(creator);
        (address token,,) = factory.launch(p);

        (,,,, address recCreator, address payout,,) = locker.locks(token);
        assertEq(recCreator, creator, "deployer stays the creator of record");
        assertEq(payout, hub.splitterOf(token));
        assertEq(splitterOf(token).creator(), feeWallet, "share goes to the chosen wallet");

        // the fee wallet, not the deployer, controls the splitter
        CreatorFeeSplitter s = splitterOf(token);
        vm.prank(creator);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.setCreator(creator);

        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);
        uint256 before = usdc.balanceOf(feeWallet);
        uint256 creatorBefore = usdc.balanceOf(creator);
        distributeAndSync(token, 0);
        assertGt(usdc.balanceOf(feeWallet) - before, 0);
        assertEq(usdc.balanceOf(creator), creatorBefore, "deployer receives nothing");
    }

    /// Exit: the creator can leave the splitter (pool empty) and have the lock pay a wallet directly.
    function test_payout_exitPointsLockAtWallet() public {
        (address token,) = doLaunch(creator, "EXIT", 0);
        CreatorFeeSplitter s = splitterOf(token);
        address mine = makeAddr("mine");
        vm.prank(buyer);
        vm.expectRevert(CreatorFeeSplitter.OnlyCreator.selector);
        s.exit(mine);

        vm.prank(creator);
        s.exit(mine);
        (,,,,, address payout,,) = locker.locks(token);
        assertEq(payout, mine);

        vm.roll(block.number + 30);
        buy(buyer, token, 1_000e6);
        uint256 before = usdc.balanceOf(mine);
        (uint256 q, uint256 f) = locker.distribute(token, 0);
        assertEq(usdc.balanceOf(mine) - before, ((q + f) * 7_800) / 10_000, "paid directly, no sync needed");

        // and can come back: the wallet (now the payout) re-points the lock at the splitter
        vm.prank(mine);
        locker.setPayout(token, address(s));
        (,,,,, payout,,) = locker.locks(token);
        assertEq(payout, address(s));
    }

    function test_locker_positionCanNeverLeave() public {
        (address token,) = doLaunch(creator, "LLL", 0);
        (uint256 tokenId,,,,,,,) = locker.locks(token);
        // no function exists to transfer it; even the owner cannot move it via the NFT contract
        vm.prank(owner);
        vm.expectRevert();
        nfpm.safeTransferFrom(address(locker), owner, tokenId);
        assertEq(nfpm.ownerOf(tokenId), address(locker));
    }

    // ------------------------------------------------------------ graduation

    function test_graduation_flagAndEvent() public {
        (address token, address pool) = doLaunch(creator, "MMM", 0);

        (uint256 paired, uint256 threshold, bool graduated) = factory.graduationStatus(token);
        assertEq(threshold, 10_000e6); // constant since v2.11
        assertEq(paired, 0);
        assertFalse(graduated);
        vm.expectRevert(LaunchFactory.NotGraduated.selector);
        factory.markGraduated(token);

        vm.roll(block.number + 30);
        // after the window there are no caps, so one buyer can push the pool past the threshold
        buy(buyer, token, 12_000e6);
        (paired,, graduated) = factory.graduationStatus(token);
        assertGe(paired, 10_000e6);
        assertTrue(graduated);
        assertEq(usdc.balanceOf(pool), paired);

        vm.expectEmit(true, false, false, false);
        emit LaunchFactory.Graduated(token, 0, 0);
        factory.markGraduated(token);
        vm.expectRevert(LaunchFactory.AlreadyGraduated.selector);
        factory.markGraduated(token);

        // trading continues in the same pool after graduation
        uint256 out = buy(buyer, token, 100e6);
        assertGt(out, 0);
    }

    // ------------------------------------------------------------ price math

    function test_priceMath_roundTrip() public pure {
        uint256[4] memory mcaps = [uint256(1_000e6), 5_000e6, 25_000e6, 1_000_000e6];
        for (uint256 i; i < mcaps.length; ++i) {
            uint160 s0 = PriceMath.sqrtPriceX96ForMcap(mcaps[i], true);
            uint160 s1 = PriceMath.sqrtPriceX96ForMcap(mcaps[i], false);
            assertApproxEqRel(PriceMath.mcapFromSqrtPriceX96(s0, true), mcaps[i], 0.001e18);
            assertApproxEqRel(PriceMath.mcapFromSqrtPriceX96(s1, false), mcaps[i], 0.001e18);
        }
    }
}
