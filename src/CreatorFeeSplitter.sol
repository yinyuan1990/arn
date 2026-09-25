// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IReferralHub {
    function keeper() external view returns (address);
}

interface IFeeLockerPayout {
    function setPayout(address token, address newPayout) external;
}

/// @title CreatorFeeSplitter
/// @notice One per launch (EIP-1167 clone created by ReferralHub). The FeeLocker pushes the creator share of the
///         token's swap fees here as USDC; this contract shares it with the promoters who brought buyers in.
///
///         Scheme B — only referred volume is charged: the referral pool is
///             creator share × referralBps × (referred volume / total volume)
///         and everything else belongs to the creator. Referred volume is attributed off-chain (first-touch
///         `?ref=` binding signed by the buyer, counted by the indexer), so the split happens in two steps:
///           1. `sync` (anyone): of every USDC that arrives, `referralBps` is reserved in `pool` (the upper bound,
///              as if all volume had been referred) and the rest is pushed to the creator on the spot;
///           2. `settle` (keeper): pays promoters out of a snapshot of `pool` in proportion to referred volume —
///              the sum can never exceed the snapshot — and returns the unreferred remainder to the creator.
///         If the keeper does not settle within RELEASE_DELAY, the creator can `release` the pool to itself.
///
///         referralBps defaults to 0 (feature off: every USDC goes straight to the creator) and the creator may
///         change it at any time; the change applies to fees synced after it (pending USDC is synced first at the
///         old rate). `exit` points the FeeLocker payout back at a plain wallet; the pool must be empty first.
/// @dev Transfers use low-level calls and park failures in `claimable` (Arc USDC has a blocklist), so one bad
///      address can never wedge a settlement.
contract CreatorFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_REFERRAL_BPS = 5_000; // at most half of the creator share goes to promoters
    uint256 public constant RELEASE_DELAY = 7 days;
    uint256 public constant MAX_REFERRERS = 200; // per settle call

    IReferralHub public immutable hub;
    address public immutable usdc;
    IFeeLockerPayout public immutable locker;

    address public token;
    /// @dev Beneficiary of the creator share; only this address can rotate it.
    address public creator;
    uint16 public referralBps;
    /// @dev USDC reserved for promoters, not yet settled.
    uint256 public pool;
    /// @dev When the current pool started filling (0 = empty). `release` opens RELEASE_DELAY after this.
    uint256 public poolSince;
    /// @dev Pushes that failed, withdrawable with `claim`; excluded from new revenue in `sync`.
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    uint256 public totalToCreator;
    uint256 public totalToReferrers;

    event Initialized(address indexed token, address indexed creator, uint16 referralBps);
    event Synced(uint256 received, uint256 toCreator, uint256 toPool, bool creatorPaid);
    event ReferralPaid(address indexed referrer, uint256 amount, bool pushed);
    event Settled(uint256 poolAmount, uint256 toReferrers, uint256 toCreator, uint256 referrers);
    event Released(uint256 amount);
    event ReferralBpsChanged(uint16 oldBps, uint16 newBps);
    event CreatorChanged(address indexed oldCreator, address indexed newCreator);
    event Exited(address indexed newPayout);
    event Claimed(address indexed account, uint256 amount);

    error OnlyHub();
    error OnlyCreator();
    error OnlyKeeper();
    error AlreadyInitialized();
    error BpsTooHigh();
    error ZeroAddress();
    error LengthMismatch();
    error TooManyReferrers();
    error ExceedsPool();
    error PoolNotEmpty();
    error TooEarly(uint256 at);
    error NothingToClaim();

    constructor(address hub_, address usdc_, address locker_) {
        if (hub_ == address(0) || usdc_ == address(0) || locker_ == address(0)) revert ZeroAddress();
        hub = IReferralHub(hub_);
        usdc = usdc_;
        locker = IFeeLockerPayout(locker_);
        // the implementation itself can never be initialized
        token = address(1);
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert OnlyCreator();
        _;
    }

    function initialize(address token_, address creator_, uint16 referralBps_) external {
        if (msg.sender != address(hub)) revert OnlyHub();
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0) || creator_ == address(0)) revert ZeroAddress();
        if (referralBps_ > MAX_REFERRAL_BPS) revert BpsTooHigh();
        token = token_;
        creator = creator_;
        referralBps = referralBps_;
        emit Initialized(token_, creator_, referralBps_);
    }

    // ------------------------------------------------------------------ revenue

    /// @notice Split USDC that arrived since the last call: `referralBps` into the pool, the rest to the creator.
    ///         Permissionless; the keeper calls it right after FeeLocker.distribute.
    function sync() external nonReentrant {
        _sync();
    }

    function _sync() internal {
        uint256 bal = IERC20(usdc).balanceOf(address(this));
        uint256 accounted = pool + totalClaimable;
        if (bal <= accounted) return;
        uint256 received = bal - accounted;
        uint256 toPool = (received * referralBps) / 10_000;
        uint256 toCreator = received - toPool;
        if (toPool > 0) {
            if (pool == 0) poolSince = block.timestamp;
            pool += toPool;
        }
        bool paid = true;
        if (toCreator > 0) {
            paid = _push(creator, toCreator);
            totalToCreator += toCreator;
        }
        emit Synced(received, toCreator, toPool, paid);
    }

    /// @notice Keeper: pay promoters out of `poolAmount` (≤ current pool) and return the rest of it to the creator.
    /// @param poolAmount the pool snapshot the keeper computed the shares on; anything that arrived later stays
    ///        in the pool for the next settlement
    function settle(uint256 poolAmount, address[] calldata referrers, uint256[] calldata amounts) external nonReentrant {
        if (msg.sender != hub.keeper()) revert OnlyKeeper();
        if (referrers.length != amounts.length) revert LengthMismatch();
        if (referrers.length > MAX_REFERRERS) revert TooManyReferrers();
        _sync();
        if (poolAmount > pool) revert ExceedsPool();

        uint256 paidOut;
        for (uint256 i; i < referrers.length; ++i) {
            uint256 amt = amounts[i];
            if (amt == 0) continue;
            if (referrers[i] == address(0)) revert ZeroAddress();
            paidOut += amt;
            if (paidOut > poolAmount) revert ExceedsPool();
            emit ReferralPaid(referrers[i], amt, _push(referrers[i], amt));
        }
        uint256 rest = poolAmount - paidOut;
        pool -= poolAmount;
        poolSince = pool == 0 ? 0 : block.timestamp;
        if (rest > 0) _push(creator, rest);
        totalToReferrers += paidOut;
        totalToCreator += rest;
        emit Settled(poolAmount, paidOut, rest, referrers.length);
    }

    /// @notice Creator safety valve: if the keeper has not settled for RELEASE_DELAY, take the whole pool back.
    function release() external nonReentrant onlyCreator {
        _sync();
        uint256 amt = pool;
        if (amt == 0) return;
        if (block.timestamp < poolSince + RELEASE_DELAY) revert TooEarly(poolSince + RELEASE_DELAY);
        pool = 0;
        poolSince = 0;
        totalToCreator += amt;
        _push(creator, amt);
        emit Released(amt);
    }

    // ------------------------------------------------------------------ creator settings

    /// @notice Change the referral share (0 = off). USDC already here is synced at the old rate first.
    function setReferralBps(uint16 newBps) external nonReentrant onlyCreator {
        if (newBps > MAX_REFERRAL_BPS) revert BpsTooHigh();
        _sync();
        emit ReferralBpsChanged(referralBps, newBps);
        referralBps = newBps;
    }

    function setCreator(address newCreator) external nonReentrant onlyCreator {
        if (newCreator == address(0)) revert ZeroAddress();
        _sync();
        emit CreatorChanged(creator, newCreator);
        creator = newCreator;
    }

    /// @notice Leave the referral scheme: the FeeLocker pays `newPayout` directly from now on. The pool must be
    ///         empty (wait for the keeper to settle, or `release` after the delay) so promoters are never cut off.
    function exit(address newPayout) external nonReentrant onlyCreator {
        if (newPayout == address(0)) revert ZeroAddress();
        _sync();
        if (pool != 0) revert PoolNotEmpty();
        locker.setPayout(token, newPayout);
        emit Exited(newPayout);
    }

    // ------------------------------------------------------------------ parked pushes

    function claim() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amt;
        IERC20(usdc).safeTransfer(msg.sender, amt);
        emit Claimed(msg.sender, amt);
    }

    function _push(address to, uint256 amount) internal returns (bool ok) {
        (bool success, bytes memory ret) = usdc.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        ok = success && (ret.length == 0 || abi.decode(ret, (bool)));
        if (!ok) {
            claimable[to] += amount;
            totalClaimable += amount;
        }
    }
}
