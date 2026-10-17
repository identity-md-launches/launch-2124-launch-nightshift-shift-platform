// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShiftRewards} from "../../src/ShiftRewards.sol";
import {ShiftToken} from "../../src/ShiftToken.sol";

/// @notice Drives ShiftRewards with several stakers, the distributor, the owner and frog claimers in random order.
contract ShiftRewardsHandler is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant ETH = address(0);
    uint256 constant ACTOR_SHIFT = 10_000_000e18;

    ShiftRewards public rewards;
    ShiftToken public shift;
    address public distributor;
    address[] public actors;

    // ghosts
    mapping(address => uint256) public ghostStaked; // net stake per actor
    mapping(address => uint256) public ghostRewardShift; // SHIFT rewards and frog claims paid per actor
    mapping(address => uint256) public ghostRewardEth; // ETH rewards paid per actor
    mapping(address => uint256) public ghostFundedStakers; // to stakers per token (split half + owner notify)
    mapping(address => uint256) public ghostFundedFrogs; // to frogs pot per token
    mapping(address => uint256) public ghostPaidStakers; // RewardPaid per token
    mapping(address => uint256) public ghostFrogsClaimed; // claimFrogs per token
    uint256 public calls;
    uint256 public epochCount;

    struct EpochRec {
        address token;
        address claimer;
        uint256 amount;
    }

    EpochRec[] public epochs;

    constructor(ShiftRewards rewards_, ShiftToken shift_, address distributor_) {
        rewards = rewards_;
        shift = shift_;
        distributor = distributor_;
    }

    /// @dev Called once the handler holds SHIFT.
    function init() external {
        require(!_inited, "init once");
        _inited = true;
        for (uint256 i = 0; i < 3; i++) {
            address a = makeAddr(string.concat("staker", vm.toString(i)));
            actors.push(a);
            shift.transfer(a, ACTOR_SHIFT);
            vm.prank(a);
            shift.approve(address(rewards), type(uint256).max);
        }
        shift.transfer(OWNER, ACTOR_SHIFT);
        vm.prank(OWNER);
        shift.approve(address(rewards), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function epochsLength() external view returns (uint256) {
        return epochs.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 seed, uint256 amount, uint256 lockDays) external {
        address a = _actor(seed);
        uint256 bal = shift.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        lockDays = bound(lockDays, 0, 730);
        if (rewards.locksOf(a).length >= 30) lockDays = 0;
        vm.prank(a);
        rewards.stake(amount, lockDays);
        ghostStaked[a] += amount;
        calls++;
    }

    function withdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 free = rewards.withdrawable(a);
        if (free == 0) {
            // A locked or empty account is refused.
            uint256 tooMuch = rewards.balanceOf(a) + 1;
            vm.prank(a);
            vm.expectRevert();
            rewards.withdraw(tooMuch);
            return;
        }
        amount = bound(amount, 1, free);
        vm.prank(a);
        rewards.withdraw(amount);
        ghostStaked[a] -= amount;
        calls++;
    }

    function getReward(uint256 seed) external {
        address a = _actor(seed);
        uint256 e0 = rewards.earned(a, ETH);
        uint256 e1 = rewards.earned(a, address(shift));
        uint256 ethBefore = a.balance;
        uint256 shiftBefore = shift.balanceOf(a);
        vm.prank(a);
        rewards.getReward();
        assertEq(a.balance - ethBefore, e0, "ETH paid != earned");
        assertEq(shift.balanceOf(a) - shiftBefore, e1, "SHIFT paid != earned");
        assertEq(rewards.earned(a, ETH), 0);
        assertEq(rewards.earned(a, address(shift)), 0);
        ghostRewardEth[a] += e0;
        ghostRewardShift[a] += e1;
        ghostPaidStakers[ETH] += e0;
        ghostPaidStakers[address(shift)] += e1;
        calls++;
    }

    // ---------------------------------------------------------------- funding

    function fundEth(uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        vm.deal(distributor, amount);
        vm.prank(distributor);
        (bool ok,) = address(rewards).call{value: amount}("");
        require(ok, "fund eth");
        ghostFundedFrogs[ETH] += amount / 2;
        ghostFundedStakers[ETH] += amount - amount / 2;
        calls++;
    }

    function fundShift(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        shift.transfer(address(rewards), amount);
        vm.prank(distributor);
        rewards.notifyReceived(address(shift));
        ghostFundedFrogs[address(shift)] += amount / 2;
        ghostFundedStakers[address(shift)] += amount - amount / 2;
        calls++;
    }

    function ownerNotify(uint256 amount, uint256 duration, bool eth) external {
        duration = bound(duration, 1 days, 365 days);
        if (eth) {
            amount = bound(amount, 1, 50 ether);
            vm.deal(OWNER, amount);
            vm.prank(OWNER);
            rewards.notifyRewardAmount{value: amount}(ETH, amount, duration);
            ghostFundedStakers[ETH] += amount;
        } else {
            if (shift.balanceOf(OWNER) == 0) return;
            amount = bound(amount, 1, shift.balanceOf(OWNER));
            vm.prank(OWNER);
            rewards.notifyRewardAmount(address(shift), amount, duration);
            ghostFundedStakers[address(shift)] += amount;
        }
        calls++;
    }

    // ---------------------------------------------------------------- frogs

    function postRoot(uint256 seed, uint256 amount, bool eth) external {
        address token = eth ? ETH : address(shift);
        uint256 pot = rewards.frogsPot(token);
        if (pot == 0) return;
        amount = bound(amount, 1, pot);
        address claimer = _actor(seed);
        uint256 epoch = epochCount++;
        // A one-leaf StandardMerkleTree: the root is the leaf and the proof is empty.
        bytes32 root = keccak256(bytes.concat(keccak256(abi.encode(epoch, claimer, token, amount))));
        // Asking for more than the pot is refused.
        vm.prank(OWNER);
        vm.expectRevert();
        rewards.postRoot(epoch, root, token, pot + 1);
        vm.prank(OWNER);
        rewards.postRoot(epoch, root, token, amount);
        epochs.push(EpochRec(token, claimer, amount));
        calls++;
    }

    function claimFrogs(uint256 idx) external {
        if (epochs.length == 0) return;
        idx = bound(idx, 0, epochs.length - 1);
        EpochRec memory r = epochs[idx];
        ShiftRewards.Epoch memory e = rewards.epochInfo(idx, r.token);
        bytes32[] memory proof = new bytes32[](0);
        if (block.timestamp > e.expiresAt || rewards.frogsClaimed(idx, r.token, r.claimer)) {
            vm.prank(r.claimer);
            vm.expectRevert();
            rewards.claimFrogs(idx, r.token, r.amount, proof);
            return;
        }
        // Someone not in the tree, or the right claimer with a different amount, is refused.
        vm.prank(OWNER);
        vm.expectRevert(ShiftRewards.InvalidProof.selector);
        rewards.claimFrogs(idx, r.token, r.amount, proof);
        vm.prank(r.claimer);
        vm.expectRevert(ShiftRewards.InvalidProof.selector);
        rewards.claimFrogs(idx, r.token, r.amount + 1, proof);

        vm.prank(r.claimer);
        rewards.claimFrogs(idx, r.token, r.amount, proof);
        ghostFrogsClaimed[r.token] += r.amount;
        if (r.token == address(shift)) ghostRewardShift[r.claimer] += r.amount;
        calls++;
    }

    function settleEpoch(uint256 idx) external {
        if (epochs.length == 0) return;
        idx = bound(idx, 0, epochs.length - 1);
        EpochRec memory r = epochs[idx];
        ShiftRewards.Epoch memory e = rewards.epochInfo(idx, r.token);
        if (block.timestamp <= e.expiresAt || e.settled) {
            vm.expectRevert();
            rewards.settleEpoch(idx, r.token);
            return;
        }
        rewards.settleEpoch(idx, r.token);
        calls++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 20 days);
        vm.warp(block.timestamp + secs);
    }

    bool private _inited;
}

contract ShiftRewardsInvariantTest is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant ETH = address(0);

    ShiftToken shift;
    ShiftRewards rewards;
    ShiftRewardsHandler handler;
    address distributor = makeAddr("distributor");

    function setUp() public {
        vm.warp(1_700_000_000);
        shift = new ShiftToken();
        rewards = new ShiftRewards(address(shift), OWNER);
        rewards.setDistributor(distributor);
        handler = new ShiftRewardsHandler(rewards, shift, distributor);
        shift.transfer(address(handler), 100_000_000e18);
        handler.init();
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = ShiftRewardsHandler.stake.selector;
        sel[1] = ShiftRewardsHandler.withdraw.selector;
        sel[2] = ShiftRewardsHandler.getReward.selector;
        sel[3] = ShiftRewardsHandler.fundEth.selector;
        sel[4] = ShiftRewardsHandler.fundShift.selector;
        sel[5] = ShiftRewardsHandler.ownerNotify.selector;
        sel[6] = ShiftRewardsHandler.postRoot.selector;
        sel[7] = ShiftRewardsHandler.claimFrogs.selector;
        sel[8] = ShiftRewardsHandler.settleEpoch.selector;
        sel[9] = ShiftRewardsHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    function _openEpochs(address token) internal view returns (uint256 open) {
        uint256 n = handler.epochsLength();
        for (uint256 i = 0; i < n; i++) {
            (address t,,) = handler.epochs(i);
            if (t != token) continue;
            ShiftRewards.Epoch memory e = rewards.epochInfo(i, token);
            if (!e.settled) open += e.total - e.claimed;
        }
    }

    function _sumEarned(address token) internal view returns (uint256 s) {
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            s += rewards.earned(handler.actors(i), token);
        }
    }

    /// The contract holds at least what it has booked, for every reward token.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_holdsWhatItAccounts() public view {
        assertGe(address(rewards).balance, rewards.accounted(ETH), "ETH below accounted");
        assertGe(shift.balanceOf(address(rewards)), rewards.accounted(address(shift)), "SHIFT below accounted");
    }

    /// What it booked covers every liability: stakes, every staker's claimable reward, the pot, open epochs.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_solvent() public view {
        uint256 shiftOwed = rewards.totalSupply() + _sumEarned(address(shift)) + rewards.frogsPot(address(shift))
            + _openEpochs(address(shift));
        assertGe(rewards.accounted(address(shift)), shiftOwed, "SHIFT liabilities exceed accounted");
        assertGe(shift.balanceOf(address(rewards)), shiftOwed, "SHIFT liabilities exceed holdings");
        uint256 ethOwed = _sumEarned(ETH) + rewards.frogsPot(ETH) + _openEpochs(ETH);
        assertGe(rewards.accounted(ETH), ethOwed, "ETH liabilities exceed accounted");
        assertGe(address(rewards).balance, ethOwed, "ETH liabilities exceed holdings");
    }

    /// Stakes are exactly what stakers put in minus what they took out.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_stakeBookkeeping() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            assertEq(rewards.balanceOf(a), handler.ghostStaked(a), "balanceOf != net staked");
            assertLe(rewards.lockedBalance(a), rewards.balanceOf(a), "locked above balance");
            // Nobody loses SHIFT by staking: wallet + stake = start + SHIFT rewards.
            assertEq(
                shift.balanceOf(a) + rewards.balanceOf(a),
                10_000_000e18 + handler.ghostRewardShift(a),
                "staker SHIFT not conserved"
            );
            sum += rewards.balanceOf(a);
        }
        assertEq(rewards.totalSupply(), sum, "totalSupply != sum of stakes");
    }

    /// Stakers are never paid, nor can claim, more than was streamed to them; frogs never more than their half.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 60
    function invariant_paidNeverExceedsFunded() public view {
        address[2] memory tokens = [ETH, address(shift)];
        for (uint256 i = 0; i < 2; i++) {
            address t = tokens[i];
            assertLe(handler.ghostPaidStakers(t) + _sumEarned(t), handler.ghostFundedStakers(t), "stakers over-paid");
            assertEq(
                rewards.frogsPot(t) + _openEpochs(t) + handler.ghostFrogsClaimed(t),
                handler.ghostFundedFrogs(t),
                "frogs pot not conserved"
            );
        }
    }

    /// Trading in the handler actually happened, so the invariants above are not vacuous.
    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "handler made no successful calls");
    }
}
