// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title ShiftRewards
/// @notice SHIFT staking with optional time locks, Synthetix-style multi-token streaming rewards, and a
/// NIGHT FROGS holders pot paid out by Merkle epochs.
///
/// Of every reward this contract receives through `notifyReceived` (or plain ETH), half streams to stakers
/// over `STREAM_DURATION` and half is added to the frogs pot of that token. The owner posts a Merkle root per
/// epoch and token against the pot, holders claim within `CLAIM_WINDOW`, and whatever is left afterwards
/// returns to the pot. The owner can post roots and add rewards; nothing lets it move staked SHIFT or
/// rewards already earned.
contract ShiftRewards is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    /// @notice Native ETH is identified by the zero address everywhere in this contract.
    address public constant ETH = address(0);
    /// @notice The NIGHT FROGS collection whose holders the frogs pot is paid to.
    address public constant NIGHT_FROGS = 0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c;
    /// @notice Length of the staker stream for rewards received through the splitter.
    uint256 public constant STREAM_DURATION = 7 days;
    /// @notice How long an epoch stays claimable after its root is posted.
    uint256 public constant CLAIM_WINDOW = 30 days;
    /// @notice Longest lock a stake may choose, in days.
    uint256 public constant MAX_LOCK_DAYS = 730;
    /// @notice Most unexpired locks one account may hold; expired locks are pruned on stake and withdraw.
    uint256 public constant MAX_ACTIVE_LOCKS = 32;
    /// @notice Most distinct reward tokens; every staker action walks the list, so it is bounded.
    uint256 public constant MAX_REWARD_TOKENS = 16;
    /// @notice Shortest and longest duration the owner may stream an outside reward over.
    uint256 public constant MIN_NOTIFY_DURATION = 1 days;
    uint256 public constant MAX_NOTIFY_DURATION = 365 days;
    uint256 private constant PRECISION = 1e18;

    // ---------------------------------------------------------------- types

    struct Lock {
        uint128 amount;
        uint64 unlockAt;
    }

    struct RewardData {
        uint256 periodFinish;
        uint256 rewardRate; // reward wei per second, scaled by PRECISION
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored; // scaled by PRECISION
    }

    struct Epoch {
        bytes32 root;
        uint256 total;
        uint256 claimed;
        uint256 expiresAt;
        bool settled;
    }

    // ---------------------------------------------------------------- storage

    IERC20 public immutable shift;
    /// @notice The contract allowed to announce token rewards (the FeeSplitter). Set once by the deployer.
    address public distributor;

    uint256 public totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => Lock[]) private _locks;

    address[] public rewardTokens;
    mapping(address => bool) public isRewardToken;
    mapping(address => RewardData) public rewardData;
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    /// @notice Everything this contract owes per token: stakes, unpaid streams, the pot and posted epochs.
    mapping(address => uint256) public accounted;
    /// @notice The NIGHT FROGS pot per token, not yet reserved by an epoch root.
    mapping(address => uint256) public frogsPot;
    mapping(uint256 => mapping(address => Epoch)) private _epochs;
    mapping(uint256 => mapping(address => mapping(address => bool))) public frogsClaimed;

    // ---------------------------------------------------------------- events

    event Staked(address indexed account, uint256 amount, uint256 unlockAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, address indexed token, uint256 amount);
    event RewardAdded(address indexed token, uint256 amount, uint256 duration);
    event FrogsPotFunded(address indexed token, uint256 amount);
    event RootPosted(uint256 indexed epoch, address indexed token, bytes32 root, uint256 total, uint256 expiresAt);
    event FrogsClaimed(uint256 indexed epoch, address indexed account, address indexed token, uint256 amount);
    event EpochSettled(uint256 indexed epoch, address indexed token, uint256 returnedToPot);
    event DistributorSet(address distributor);

    // ---------------------------------------------------------------- errors

    error ZeroAmount();
    error LockTooLong();
    error TooManyLocks();
    error InsufficientUnlocked(uint256 requested, uint256 unlocked);
    error TooManyRewardTokens();
    error NotDistributor();
    error DistributorAlreadySet();
    error BadDuration();
    error ValueMismatch();
    error NothingReceived();
    error EpochExists();
    error EpochUnknown();
    error EpochExpired();
    error EpochNotExpired();
    error EpochAlreadySettled();
    error ExceedsPot(uint256 requested, uint256 pot);
    error ExceedsEpoch();
    error AlreadyClaimed();
    error InvalidProof();
    error EmptyRoot();
    error EthTransferFailed();

    // ---------------------------------------------------------------- constructor

    constructor(address shift_, address owner_) Ownable(owner_) {
        shift = IERC20(shift_);
        _addRewardToken(ETH);
        _addRewardToken(shift_);
    }

    /// @notice Names the FeeSplitter that forwards token rewards. Callable once, by the deployer (the hook).
    function setDistributor(address distributor_) external {
        if (distributor != address(0)) revert DistributorAlreadySet();
        distributor = distributor_;
        emit DistributorSet(distributor_);
    }

    // ---------------------------------------------------------------- staking

    /// @notice Stakes `amount` SHIFT, locked for `lockDays` days (0 to 730). A lock of 0 is withdrawable at once.
    function stake(uint256 amount, uint256 lockDays) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (lockDays > MAX_LOCK_DAYS) revert LockTooLong();
        _updateAll(msg.sender);

        uint256 unlockAt = block.timestamp;
        if (lockDays > 0) {
            _pruneLocks(msg.sender);
            Lock[] storage locks = _locks[msg.sender];
            if (locks.length >= MAX_ACTIVE_LOCKS) revert TooManyLocks();
            unlockAt = block.timestamp + lockDays * 1 days;
            locks.push(Lock({amount: uint128(amount), unlockAt: uint64(unlockAt)}));
        }

        totalSupply += amount;
        _balances[msg.sender] += amount;
        accounted[address(shift)] += amount;
        shift.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, unlockAt);
    }

    /// @notice Withdraws `amount` of unlocked stake.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(amount);
    }

    /// @notice Pays out everything earned across every reward token.
    function getReward() external nonReentrant {
        _updateAll(msg.sender);
        uint256 n = rewardTokens.length;
        for (uint256 i = 0; i < n; i++) {
            _payReward(msg.sender, rewardTokens[i]);
        }
    }

    /// @notice Pays out what was earned in one reward token.
    function getReward(address token) external nonReentrant {
        _updateAll(msg.sender);
        _payReward(msg.sender, token);
    }

    /// @notice Withdraws all unlocked stake and pays every reward.
    function exit() external nonReentrant {
        _withdraw(withdrawable(msg.sender));
        uint256 n = rewardTokens.length;
        for (uint256 i = 0; i < n; i++) {
            _payReward(msg.sender, rewardTokens[i]);
        }
    }

    function _withdraw(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _updateAll(msg.sender);
        _pruneLocks(msg.sender);
        uint256 unlocked = _balances[msg.sender] - _lockedOf(msg.sender);
        if (amount > unlocked) revert InsufficientUnlocked(amount, unlocked);

        totalSupply -= amount;
        _balances[msg.sender] -= amount;
        accounted[address(shift)] -= amount;
        shift.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function _payReward(address account, address token) internal {
        uint256 reward = rewards[account][token];
        if (reward == 0) return;
        rewards[account][token] = 0;
        accounted[token] -= reward;
        _send(token, account, reward);
        emit RewardPaid(account, token, reward);
    }

    function _pruneLocks(address account) internal {
        Lock[] storage locks = _locks[account];
        uint256 i = 0;
        while (i < locks.length) {
            if (locks[i].unlockAt <= block.timestamp) {
                locks[i] = locks[locks.length - 1];
                locks.pop();
            } else {
                i++;
            }
        }
    }

    function _lockedOf(address account) internal view returns (uint256 locked) {
        Lock[] storage locks = _locks[account];
        uint256 n = locks.length;
        for (uint256 i = 0; i < n; i++) {
            if (locks[i].unlockAt > block.timestamp) locked += locks[i].amount;
        }
    }

    // ---------------------------------------------------------------- staking views

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Stake that is still time-locked.
    function lockedBalance(address account) external view returns (uint256) {
        return _lockedOf(account);
    }

    /// @notice Stake that can be withdrawn now.
    function withdrawable(address account) public view returns (uint256) {
        return _balances[account] - _lockedOf(account);
    }

    /// @notice All locks of `account`, expired ones included until the next stake or withdraw prunes them.
    function locksOf(address account) external view returns (Lock[] memory) {
        return _locks[account];
    }

    function rewardTokenCount() external view returns (uint256) {
        return rewardTokens.length;
    }

    // ---------------------------------------------------------------- rewards maths

    function lastTimeRewardApplicable(address token) public view returns (uint256) {
        uint256 finish = rewardData[token].periodFinish;
        return block.timestamp < finish ? block.timestamp : finish;
    }

    function rewardPerToken(address token) public view returns (uint256) {
        RewardData storage r = rewardData[token];
        if (totalSupply == 0) return r.rewardPerTokenStored;
        uint256 elapsed = lastTimeRewardApplicable(token) - r.lastUpdateTime;
        return r.rewardPerTokenStored + (elapsed * r.rewardRate) / totalSupply;
    }

    /// @notice Reward in `token` that `account` can claim now.
    function earned(address account, address token) public view returns (uint256) {
        return _balances[account] * (rewardPerToken(token) - userRewardPerTokenPaid[account][token]) / PRECISION
            + rewards[account][token];
    }

    function _updateAll(address account) internal {
        uint256 n = rewardTokens.length;
        for (uint256 i = 0; i < n; i++) {
            address token = rewardTokens[i];
            RewardData storage r = rewardData[token];
            r.rewardPerTokenStored = rewardPerToken(token);
            r.lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = earned(account, token);
                userRewardPerTokenPaid[account][token] = r.rewardPerTokenStored;
            }
        }
    }

    function _addRewardToken(address token) internal {
        if (isRewardToken[token]) return;
        if (rewardTokens.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        isRewardToken[token] = true;
        rewardTokens.push(token);
    }

    /// @dev Starts or tops up the staker stream of `token` with `amount` over `duration`.
    function _notifyStakers(address token, uint256 amount, uint256 duration) internal {
        _addRewardToken(token);
        // Settle the global accumulator for this token before changing its rate.
        RewardData storage r = rewardData[token];
        r.rewardPerTokenStored = rewardPerToken(token);
        r.lastUpdateTime = lastTimeRewardApplicable(token);

        uint256 scaled = amount * PRECISION;
        if (block.timestamp >= r.periodFinish) {
            r.rewardRate = scaled / duration;
        } else {
            uint256 remaining = r.periodFinish - block.timestamp;
            uint256 leftover = remaining * r.rewardRate;
            r.rewardRate = (scaled + leftover) / duration;
        }
        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + duration;
        emit RewardAdded(token, amount, duration);
    }

    // ---------------------------------------------------------------- receiving rewards

    /// @notice ETH sent here is a reward: half streams to stakers, half funds the frogs pot.
    receive() external payable {
        if (msg.value == 0) revert ZeroAmount();
        _split(ETH, msg.value);
    }

    /// @notice Announces `token` the splitter just transferred in: everything above what is accounted for is a
    /// reward, half to stakers over 7 days and half to the frogs pot. For ETH the `receive` path does the same.
    function notifyReceived(address token) external nonReentrant {
        if (msg.sender != distributor && msg.sender != owner()) revert NotDistributor();
        if (token == ETH) revert ValueMismatch();
        uint256 received = IERC20(token).balanceOf(address(this)) - accounted[token];
        if (received == 0) revert NothingReceived();
        _split(token, received);
    }

    function _split(address token, uint256 amount) internal {
        uint256 toFrogs = amount / 2;
        uint256 toStakers = amount - toFrogs;
        accounted[token] += amount;
        frogsPot[token] += toFrogs;
        emit FrogsPotFunded(token, toFrogs);
        _notifyStakers(token, toStakers, STREAM_DURATION);
    }

    /// @notice Owner adds an outside reward for stakers only, streamed over `duration`. For ETH send it as value.
    function notifyRewardAmount(address token, uint256 amount, uint256 duration)
        external
        payable
        onlyOwner
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_NOTIFY_DURATION || duration > MAX_NOTIFY_DURATION) revert BadDuration();
        if (token == ETH) {
            if (msg.value != amount) revert ValueMismatch();
        } else {
            if (msg.value != 0) revert ValueMismatch();
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            amount = IERC20(token).balanceOf(address(this)) - before;
            if (amount == 0) revert NothingReceived();
        }
        accounted[token] += amount;
        _notifyStakers(token, amount, duration);
    }

    // ---------------------------------------------------------------- NIGHT FROGS pot

    /// @notice Reserves `total` of the `token` pot for `epoch`, claimable against `root` for 30 days.
    function postRoot(uint256 epoch, bytes32 root, address token, uint256 total) external onlyOwner {
        if (root == bytes32(0)) revert EmptyRoot();
        if (total == 0) revert ZeroAmount();
        Epoch storage e = _epochs[epoch][token];
        if (e.root != bytes32(0)) revert EpochExists();
        uint256 pot = frogsPot[token];
        if (total > pot) revert ExceedsPot(total, pot);
        frogsPot[token] = pot - total;
        e.root = root;
        e.total = total;
        e.expiresAt = block.timestamp + CLAIM_WINDOW;
        emit RootPosted(epoch, token, root, total, e.expiresAt);
    }

    /// @notice Claims `amount` of `token` from `epoch` with an OpenZeppelin StandardMerkleTree proof whose leaf is
    /// keccak256(bytes.concat(keccak256(abi.encode(epoch, msg.sender, token, amount)))).
    function claimFrogs(uint256 epoch, address token, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Epoch storage e = _epochs[epoch][token];
        if (e.root == bytes32(0)) revert EpochUnknown();
        if (block.timestamp > e.expiresAt) revert EpochExpired();
        if (frogsClaimed[epoch][token][msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(epoch, msg.sender, token, amount))));
        if (!MerkleProof.verifyCalldata(proof, e.root, leaf)) revert InvalidProof();
        if (e.claimed + amount > e.total) revert ExceedsEpoch();

        frogsClaimed[epoch][token][msg.sender] = true;
        e.claimed += amount;
        accounted[token] -= amount;
        _send(token, msg.sender, amount);
        emit FrogsClaimed(epoch, msg.sender, token, amount);
    }

    /// @notice After the claim window, returns what `epoch` left unclaimed to the pot. Anyone may call it.
    function settleEpoch(uint256 epoch, address token) external {
        Epoch storage e = _epochs[epoch][token];
        if (e.root == bytes32(0)) revert EpochUnknown();
        if (block.timestamp <= e.expiresAt) revert EpochNotExpired();
        if (e.settled) revert EpochAlreadySettled();
        e.settled = true;
        uint256 returned = e.total - e.claimed;
        frogsPot[token] += returned;
        emit EpochSettled(epoch, token, returned);
    }

    function epochInfo(uint256 epoch, address token) external view returns (Epoch memory) {
        return _epochs[epoch][token];
    }

    // ---------------------------------------------------------------- transfers

    function _send(address token, address to, uint256 amount) internal {
        if (token == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
