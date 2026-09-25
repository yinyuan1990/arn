// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CreatorFeeSplitter} from "./CreatorFeeSplitter.sol";

/// @title ReferralHub
/// @notice Creates the per-launch CreatorFeeSplitter (a deterministic EIP-1167 clone keyed by the token) and holds
///         the one piece of shared configuration: the keeper allowed to settle referral pools.
/// @dev The owner can only rotate the keeper. A keeper can at most pay promoters out of a splitter's pool, which is
///      capped by the creator's own `referralBps`; it can never touch the creator's direct share.
contract ReferralHub is Ownable {
    address public immutable implementation;
    address public factory;
    address public keeper;

    mapping(address token => address) public splitterOf;

    event SplitterCreated(address indexed token, address indexed splitter, address indexed creator, uint16 referralBps);
    event KeeperChanged(address indexed oldKeeper, address indexed newKeeper);
    event FactorySet(address factory);

    error OnlyFactory();
    error AlreadySet();
    error ZeroAddress();

    constructor(address usdc_, address locker_, address keeper_, address owner_) Ownable(owner_) {
        if (keeper_ == address(0)) revert ZeroAddress();
        implementation = address(new CreatorFeeSplitter(address(this), usdc_, locker_));
        keeper = keeper_;
        emit KeeperChanged(address(0), keeper_);
    }

    /// @notice One-time wiring; the factory is deployed after the hub.
    function setFactory(address factory_) external onlyOwner {
        if (factory != address(0)) revert AlreadySet();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        emit KeeperChanged(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @dev Called by the factory inside `launch`, before the lock is registered with the splitter as payout.
    function create(address token, address creator, uint16 referralBps) external returns (address splitter) {
        if (msg.sender != factory) revert OnlyFactory();
        splitter = Clones.cloneDeterministic(implementation, bytes32(uint256(uint160(token))));
        CreatorFeeSplitter(splitter).initialize(token, creator, referralBps);
        splitterOf[token] = splitter;
        emit SplitterCreated(token, splitter, creator, referralBps);
    }

    function predictSplitter(address token) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(uint256(uint160(token))));
    }
}
