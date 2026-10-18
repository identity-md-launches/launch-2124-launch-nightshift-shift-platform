// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShiftRewards} from "../src/ShiftRewards.sol";
import {ShiftToken} from "../src/ShiftToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ShiftRewardsTest is Test {
    address constant OWNER = 0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5;
    address constant ETH = address(0);

    ShiftToken shift;
    ShiftRewards rewards;
    MockERC20 imd;
    address distributor = makeAddr("distributor");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address frog1 = makeAddr("frog1");
    address frog2 = makeAddr("frog2");

    event Staked(address indexed account, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, address indexed token, uint256 amount);

    function setUp() public {
        vm.warp(1_700_000_000);
        shift = new ShiftToken();
        rewards = new ShiftRewards(address(shift), OWNER);
        rewards.setDistributor(distributor);
        imd = new MockERC20("IMD", "IMD", 0);
        shift.transfer(alice, 1_000_000e18);
        shift.transfer(bob, 1_000_000e18);
        shift.transfer(OWNER, 1_000_000e18);
        vm.prank(alice);
        shift.approve(address(rewards), type(uint256).max);
        vm.prank(bob);
        shift.approve(address(rewards), type(uint256).max);
        vm.prank(OWNER);
        shift.approve(address(rewards), type(uint256).max);
    }

    function _fundEth(uint256 amount) internal {
        vm.deal(distributor, amount);
        vm.prank(distributor);
        (bool ok,) = address(rewards).call{value: amount}("");
        assertTrue(ok);
    }

    function _fundToken(MockERC20 token, uint256 amount) internal {
        token.mint(address(rewards), amount);
        vm.prank(distributor);
        rewards.notifyReceived(address(token));
    }

    // ---------------------------------------------------------------- staking and locks

    function test_stakeAndWithdrawUnlocked() public {
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Staked(alice, 100e18, block.timestamp);
        vm.prank(alice);
        rewards.stake(100e18, 0);
        assertEq(rewards.balanceOf(alice), 100e18);
        assertEq(rewards.totalSupply(), 100e18);
        assertEq(rewards.withdrawable(alice), 100e18);
        assertEq(rewards.accounted(address(shift)), 100e18);

        vm.expectEmit(true, true, true, true, address(rewards));
        emit Withdrawn(alice, 40e18);
        vm.prank(alice);
        rewards.withdraw(40e18);
        assertEq(rewards.balanceOf(alice), 60e18);
        assertEq(shift.balanceOf(alice), 1_000_000e18 - 60e18);
    }

    function test_lockedStakeCannotBeWithdrawnEarly() public {
        uint256 unlockAt = block.timestamp + 30 days;
        vm.expectEmit(true, true, true, true, address(rewards));
        emit Staked(alice, 100e18, unlockAt);
        vm.startPrank(alice);
        rewards.stake(100e18, 30);
        rewards.stake(50e18, 0);
        assertEq(rewards.lockedBalance(alice), 100e18);
        assertEq(rewards.withdrawable(alice), 50e18);

        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.InsufficientUnlocked.selector, 60e18, 50e18));
        rewards.withdraw(60e18);
        rewards.withdraw(50e18);

        vm.warp(unlockAt - 1);
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.InsufficientUnlocked.selector, 1, 0));
        rewards.withdraw(1);
        vm.warp(unlockAt);
        rewards.withdraw(100e18);
        assertEq(rewards.balanceOf(alice), 0);
        assertEq(rewards.locksOf(alice).length, 0, "expired lock pruned");
        vm.stopPrank();
    }

    function test_stakeRejectsBadInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(ShiftRewards.ZeroAmount.selector);
        rewards.stake(0, 0);
        vm.expectRevert(ShiftRewards.LockTooLong.selector);
        rewards.stake(1e18, 731);
        rewards.stake(1e18, 730);
        for (uint256 i = 1; i < 32; i++) {
            rewards.stake(1e18, 1);
        }
        vm.expectRevert(ShiftRewards.TooManyLocks.selector);
        rewards.stake(1e18, 1);
        vm.expectRevert(ShiftRewards.ZeroAmount.selector);
        rewards.withdraw(0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- streaming rewards

    function test_ethRewardSplitsHalfToStakersHalfToPot() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        _fundEth(10 ether);
        assertEq(rewards.frogsPot(ETH), 5 ether);
        assertEq(rewards.accounted(ETH), 10 ether);
        (uint256 periodFinish, uint256 rate,,) = rewards.feeStream(ETH);
        assertEq(periodFinish, block.timestamp + 7 days);
        assertEq(rate, uint256(5 ether) * 1e18 / 7 days);

        vm.warp(block.timestamp + 7 days);
        uint256 earned = rewards.earned(alice, ETH);
        assertApproxEqRel(earned, 5 ether, 1e12);
        assertLe(earned, 5 ether);

        vm.expectEmit(true, true, true, true, address(rewards));
        emit RewardPaid(alice, ETH, earned);
        vm.prank(alice);
        rewards.getReward();
        assertEq(alice.balance, earned);
        assertEq(rewards.earned(alice, ETH), 0);
        assertEq(rewards.accounted(ETH), 10 ether - earned);
    }

    function test_rewardsProRataToStakeAndTime() public {
        vm.prank(alice);
        rewards.stake(300e18, 0);
        vm.prank(bob);
        rewards.stake(100e18, 0);
        _fundEth(8 ether); // 4 ETH stream
        vm.warp(block.timestamp + 7 days);
        uint256 a = rewards.earned(alice, ETH);
        uint256 b = rewards.earned(bob, ETH);
        assertApproxEqRel(a, 3 ether, 1e12);
        assertApproxEqRel(b, 1 ether, 1e12);
        assertApproxEqAbs(a, 3 * b, 1e6);

        // Bob stakes more half way through a new stream: earns more than before, less than Alice.
        _fundEth(8 ether);
        vm.warp(block.timestamp + 3.5 days);
        vm.prank(bob);
        rewards.stake(200e18, 0);
        vm.warp(block.timestamp + 3.5 days);
        uint256 a2 = rewards.earned(alice, ETH) - a;
        uint256 b2 = rewards.earned(bob, ETH) - b;
        // First half: 300/400 vs 100/400 of 2 ETH. Second half: 300/600 vs 300/600 of 2 ETH.
        assertApproxEqRel(a2, 2.5 ether, 1e9);
        assertApproxEqRel(b2, 1.5 ether, 1e9);
    }

    function test_tokenRewardsThroughNotifyReceived() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        vm.expectRevert(ShiftRewards.NotDistributor.selector);
        rewards.notifyReceived(address(imd));
        vm.prank(distributor);
        vm.expectRevert(ShiftRewards.NothingReceived.selector);
        rewards.notifyReceived(address(imd));

        // The distributor cannot register a token: the staker half waits until the owner adds it.
        _fundToken(imd, 1000e18);
        assertFalse(rewards.isRewardToken(address(imd)));
        assertEq(rewards.frogsPot(address(imd)), 500e18);
        assertEq(rewards.unstreamed(address(imd)), 500e18);
        vm.prank(alice);
        vm.expectRevert();
        rewards.addRewardToken(address(imd));
        vm.prank(OWNER);
        rewards.addRewardToken(address(imd));
        assertTrue(rewards.isRewardToken(address(imd)));
        assertEq(rewards.unstreamed(address(imd)), 0);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        rewards.getReward(address(imd));
        assertApproxEqRel(imd.balanceOf(alice), 500e18, 1e12);
    }

    function test_shiftRewardsDoNotMixWithStakes() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        shift.transfer(address(rewards), 200e18);
        vm.prank(distributor);
        rewards.notifyReceived(address(shift));
        assertEq(rewards.frogsPot(address(shift)), 100e18);
        assertEq(rewards.accounted(address(shift)), 300e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        rewards.exit();
        assertApproxEqRel(shift.balanceOf(alice), 1_000_000e18 + 100e18, 1e12);
        assertEq(rewards.balanceOf(alice), 0);
    }

    function test_ownerNotifyRewardAmount() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        vm.prank(alice);
        vm.expectRevert();
        rewards.notifyRewardAmount(address(shift), 100e18, 7 days);

        vm.startPrank(OWNER);
        vm.expectRevert(ShiftRewards.BadDuration.selector);
        rewards.notifyRewardAmount(address(shift), 100e18, 1 hours);
        vm.expectRevert(ShiftRewards.ValueMismatch.selector);
        rewards.notifyRewardAmount(ETH, 1 ether, 7 days);
        rewards.notifyRewardAmount(address(shift), 700e18, 7 days);
        vm.stopPrank();
        assertEq(rewards.frogsPot(address(shift)), 0, "outside rewards go to stakers only");
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(rewards.earned(alice, address(shift)), 100e18, 1e12);

        vm.deal(OWNER, 2 ether);
        vm.prank(OWNER);
        rewards.notifyRewardAmount{value: 2 ether}(ETH, 2 ether, 2 days);
        vm.warp(block.timestamp + 2 days);
        assertApproxEqRel(rewards.earned(alice, ETH), 2 ether, 1e12);
    }

    function test_ownerCannotTakeStakesOrRewards() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        _fundEth(10 ether);
        vm.warp(block.timestamp + 7 days);
        uint256 earnedBefore = rewards.earned(alice, ETH);
        vm.startPrank(OWNER);
        (bool ok,) =
            address(rewards).call(abi.encodeWithSignature("recoverERC20(address,uint256)", address(shift), 100e18));
        assertFalse(ok);
        (ok,) = address(rewards).call(abi.encodeWithSignature("sweep(address)", address(shift)));
        assertFalse(ok);
        // A root can only be paid from the frogs pot, never from stakes or the stream.
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.ExceedsPot.selector, 5 ether + 1, 5 ether));
        rewards.postRoot(1, bytes32(uint256(1)), ETH, 5 ether + 1);
        vm.stopPrank();
        assertEq(shift.balanceOf(address(rewards)), 100e18);
        assertEq(rewards.earned(alice, ETH), earnedBefore);
    }

    function test_rewardTokenListIsBounded() public {
        // Junk from the distributor never grows the list.
        for (uint256 i = 0; i < 20; i++) {
            MockERC20 t = new MockERC20("T", "T", 0);
            _fundToken(t, 1e18);
        }
        assertEq(rewards.rewardTokenCount(), 3);
        for (uint256 i = 0; i < 13; i++) {
            MockERC20 t = new MockERC20("T", "T", 0);
            vm.prank(OWNER);
            rewards.addRewardToken(address(t));
        }
        assertEq(rewards.rewardTokenCount(), 16);
        MockERC20 extra = new MockERC20("X", "X", 0);
        extra.mint(address(rewards), 1e18);
        vm.prank(OWNER);
        vm.expectRevert(ShiftRewards.TooManyRewardTokens.selector);
        rewards.notifyReceived(address(extra));
    }

    // ---------------------------------------------------------------- NIGHT FROGS pot

    function _leaf(uint256 epoch, address account, address token, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epoch, account, token, amount))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function test_frogsEpochLifecycle() public {
        _fundEth(10 ether); // pot 5 ETH
        bytes32 l1 = _leaf(1, frog1, ETH, 3 ether);
        bytes32 l2 = _leaf(1, frog2, ETH, 1 ether);
        bytes32 root = _pair(l1, l2);

        vm.prank(alice);
        vm.expectRevert();
        rewards.postRoot(1, root, ETH, 4 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(ShiftRewards.EmptyRoot.selector);
        rewards.postRoot(1, bytes32(0), ETH, 4 ether);
        vm.expectRevert(abi.encodeWithSelector(ShiftRewards.ExceedsPot.selector, 6 ether, 5 ether));
        rewards.postRoot(1, root, ETH, 6 ether);
        rewards.postRoot(1, root, ETH, 4 ether);
        vm.expectRevert(ShiftRewards.EpochExists.selector);
        rewards.postRoot(1, root, ETH, 1 ether);
        vm.stopPrank();
        assertEq(rewards.frogsPot(ETH), 1 ether);

        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = l2;
        bytes32[] memory proof2 = new bytes32[](1);
        proof2[0] = l1;

        // Wrong amount, wrong account, wrong epoch all fail.
        vm.prank(frog1);
        vm.expectRevert(ShiftRewards.InvalidProof.selector);
        rewards.claimFrogs(1, ETH, 2 ether, proof1);
        vm.prank(alice);
        vm.expectRevert(ShiftRewards.InvalidProof.selector);
        rewards.claimFrogs(1, ETH, 3 ether, proof1);
        vm.prank(frog1);
        vm.expectRevert(ShiftRewards.EpochUnknown.selector);
        rewards.claimFrogs(2, ETH, 3 ether, proof1);

        vm.prank(frog1);
        rewards.claimFrogs(1, ETH, 3 ether, proof1);
        assertEq(frog1.balance, 3 ether);
        vm.prank(frog1);
        vm.expectRevert(ShiftRewards.AlreadyClaimed.selector);
        rewards.claimFrogs(1, ETH, 3 ether, proof1);

        // Too early to settle; after 30 days claims close and the rest returns to the pot.
        vm.expectRevert(ShiftRewards.EpochNotExpired.selector);
        rewards.settleEpoch(1, ETH);
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(frog2);
        vm.expectRevert(ShiftRewards.EpochExpired.selector);
        rewards.claimFrogs(1, ETH, 1 ether, proof2);
        rewards.settleEpoch(1, ETH);
        assertEq(rewards.frogsPot(ETH), 2 ether);
        vm.expectRevert(ShiftRewards.EpochAlreadySettled.selector);
        rewards.settleEpoch(1, ETH);
        assertEq(rewards.accounted(ETH), 7 ether);
    }

    function test_frogsClaimTokenAndEpochCap() public {
        _fundToken(imd, 1000e18); // pot 500
        // A root whose leaves add up to more than the posted total: the later claim is cut off by the cap.
        bytes32 l1 = _leaf(7, frog1, address(imd), 300e18);
        bytes32 l2 = _leaf(7, frog2, address(imd), 300e18);
        vm.prank(OWNER);
        rewards.postRoot(7, _pair(l1, l2), address(imd), 500e18);
        bytes32[] memory p1 = new bytes32[](1);
        p1[0] = l2;
        bytes32[] memory p2 = new bytes32[](1);
        p2[0] = l1;
        vm.prank(frog1);
        rewards.claimFrogs(7, address(imd), 300e18, p1);
        assertEq(imd.balanceOf(frog1), 300e18);
        vm.prank(frog2);
        vm.expectRevert(ShiftRewards.ExceedsEpoch.selector);
        rewards.claimFrogs(7, address(imd), 300e18, p2);
        // The same leaf cannot be used for another token.
        vm.prank(frog1);
        vm.expectRevert(ShiftRewards.EpochUnknown.selector);
        rewards.claimFrogs(7, ETH, 300e18, p1);
    }

    function testFuzz_earnedNeverExceedsStream(uint128 stakeA, uint128 stakeB, uint32 elapsed) public {
        stakeA = uint128(bound(stakeA, 1e18, 1_000_000e18));
        stakeB = uint128(bound(stakeB, 1e18, 1_000_000e18));
        elapsed = uint32(bound(elapsed, 1, 30 days));
        vm.prank(alice);
        rewards.stake(stakeA, 0);
        vm.prank(bob);
        rewards.stake(stakeB, 0);
        _fundEth(10 ether);
        vm.warp(block.timestamp + elapsed);
        uint256 total = rewards.earned(alice, ETH) + rewards.earned(bob, ETH);
        assertLe(total, 5 ether);
        uint256 expected = elapsed >= 7 days ? 5 ether : 5 ether * uint256(elapsed) / 7 days;
        assertApproxEqRel(total, expected, 1e12); // rate is an integer per second: tiny rounding at 1s
        assertApproxEqAbs(
            rewards.earned(alice, ETH) * stakeB, rewards.earned(bob, ETH) * stakeA, uint256(stakeA) * stakeB
        );
    }

    // ---------------------------------------------------------------- revision checks

    function test_ownerStreamNotRescheduledBySplitterIncome() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        vm.deal(OWNER, 365 ether);
        vm.prank(OWNER);
        rewards.notifyRewardAmount{value: 365 ether}(ETH, 365 ether, 365 days);
        (uint256 finish,,,) = rewards.rewardData(ETH);
        (bool ok,) = address(rewards).call{value: 1}("");
        assertTrue(ok);
        (uint256 finishAfter,,,) = rewards.rewardData(ETH);
        assertEq(finishAfter, finish);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(rewards.earned(alice, ETH), 7 ether, 1e12);
    }

    function test_streamWhileNobodyStakedGoesToFirstStaker() public {
        _fundEth(10 ether);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        rewards.stake(100e18, 0);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(rewards.earned(alice, ETH), 5 ether, 1e12);
        assertLe(rewards.earned(alice, ETH), 5 ether);
    }

    function test_exitWithEverythingLockedStillPaysRewards() public {
        vm.prank(alice);
        rewards.stake(100e18, 30);
        _fundEth(10 ether);
        vm.warp(block.timestamp + 1 days);
        uint256 e = rewards.earned(alice, ETH);
        assertGt(e, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        rewards.exit();
        assertEq(alice.balance - before, e);
        assertEq(rewards.balanceOf(alice), 100e18);
    }

    function test_failingRewardTokenDoesNotBlockBatch() public {
        vm.prank(alice);
        rewards.stake(100e18, 0);
        BrokenToken bad = new BrokenToken();
        vm.prank(OWNER);
        rewards.addRewardToken(address(bad));
        bad.mint(address(rewards), 1e18);
        vm.prank(distributor);
        rewards.notifyReceived(address(bad));
        _fundEth(10 ether);
        vm.warp(block.timestamp + 7 days);
        uint256 owedBad = rewards.earned(alice, address(bad));
        uint256 before = alice.balance;
        vm.prank(alice);
        rewards.getReward();
        assertApproxEqRel(alice.balance - before, 5 ether, 1e12);
        assertEq(rewards.earned(alice, address(bad)), owedBad);
    }
}

contract BrokenToken is MockERC20("B", "B", 0) {
    function transfer(address, uint256) public pure override returns (bool) {
        revert("no");
    }
}
