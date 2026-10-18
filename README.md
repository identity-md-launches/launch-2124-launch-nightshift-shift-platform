# NIGHTSHIFT (SHIFT) — Uniswap v4 launch

Foundry project for the NIGHTSHIFT launch on Ethereum mainnet (chain id 1): the SHIFT token, the
`NightshiftHook` on the SHIFT/ETH Uniswap v4 pool, and the two helpers the hook creates in its
constructor, `FeeSplitter` and `ShiftRewards`.

```
forge build
forge test
forge fmt --check
```

Compiler is pinned to `solc = "0.8.26"`, `evm_version = "cancun"` (the hook uses transient storage),
`bytecode_hash = "none"`. Dependencies are vendored as plain files under `lib/` (forge-std, v4-core,
OpenZeppelin Contracts v5.4.0, solmate for v4-core's `Owned`). No submodules, no ffi, no fs access.

## Contracts

| Contract | File | Deployed by |
| --- | --- | --- |
| `ShiftToken` | `src/ShiftToken.sol` | launch factory (`$token`) |
| `NightshiftHook` | `src/NightshiftHook.sol` | launch factory, address mined for its flags |
| `FeeSplitter` | `src/FeeSplitter.sol` | `NightshiftHook` constructor, `hook.feeSplitter()` |
| `ShiftRewards` | `src/ShiftRewards.sol` | `NightshiftHook` constructor, `hook.rewards()` |
| `HookFlags` | `src/HookFlags.sol` | internal library, flag bits and address matching |

### ShiftToken

Plain OpenZeppelin ERC-20, name `NIGHTSHIFT`, symbol `SHIFT`, 18 decimals, 1,000,000,000 tokens
minted once to `msg.sender` (the launch factory). No owner, mint, pause, blocklist, fee or upgrade.
The brief asked for nothing more of the token; the sell fee lives in the hook.

### NightshiftHook

Constructor `(IPoolManager poolManager, address token, address owner, address factory)`, written in
the manifest as `"$poolManager"`, `"$token"`, `"$owner"`, `"$factory"`. The constructor calls no
outside contract: it creates `ShiftRewards` and `FeeSplitter`, wires them, and validates its own
address against its permissions.

Permissions (address flags `0x20CC` = 8396): `beforeInitialize`, `beforeSwap`, `afterSwap`,
`beforeSwapReturnDelta`, `afterSwapReturnDelta`. Why each:

- `beforeInitialize` is required for IMD launches. Only the launch factory may initialize, once,
  and only native ETH (currency0) paired with the launch token (currency1), with a static LP fee.
  Any listed static fee is accepted; the launch opens at 12500 (1.25%).
- `beforeSwap` enforces the launch gate and takes the *specified*-side fee part on sells (the SHIFT
  input on exact-input sells, the ETH output on exact-output sells).
- `afterSwap` opens trading on the first buy and takes the *unspecified*-side fee part on sells
  (the ETH output on exact-input sells, the SHIFT input on exact-output sells).
- The two return-delta flags are what let the hook charge those amounts. No liquidity callbacks are
  enabled, so the factory's zero-liquidity fee collect runs no hook code and cannot be blocked.

Wizard-style configuration record: `{"hook":"BaseHook","name":"NightshiftHook","pausable":false,
"currencySettler":false,"safeCast":true,"transientStorage":true,"shares":{"options":false},
"permissions":{"beforeInitialize":true,"beforeSwap":true,"afterSwap":true,
"beforeSwapReturnDelta":true,"afterSwapReturnDelta":true, all others false},"access":"ownable"}`.
The hook is written against v4-core directly (its own `onlyPoolManager` check) rather than a
periphery base contract, to keep the vendored dependency set small.

**Launch gate.** Until `tradingOpen` is true, `beforeSwap` reverts `TradingNotOpen` unless
`tx.origin == 0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69`. The check is on `tx.origin`, as the
brief requires, so the first buy works through any router including the Universal Router
(`0x66a9893cc07d91d95644aedd05d03f95e1dba8af`); the `sender` argument (the router) is ignored. The
first *buy* (ETH in, SHIFT out) by that origin sets `tradingOpen = true` and emits
`TradingOpened(firstBuyer, shiftOut)`. There is no other code path that writes `tradingOpen`: no
setter, no pause, no close. A sell by that wallet before the buy is allowed but does not open trading.
The buy has no minimum or maximum.

**Sell fee.** On every sell the hook takes `shiftFeeBps` of the SHIFT input and `ethFeeBps` of the
ETH output, both 250 (2.5%) at deployment, both sent to the `FeeSplitter`, and emits
`FeeTaken(seller = tx.origin, shiftFee, ethFee)`. Buys pay nothing and return zero deltas. For exact
output sells the ETH part is `requested * ethFeeBps / (10000 - ethFeeBps)` so the seller still
receives exactly what was requested; the SHIFT part is 2.5% of what the pool consumed. The fee is
taken on top of the pool's 1.25% LP fee. SHIFT is taken directly from the PoolManager (it holds the
pool's SHIFT reserve). ETH is taken directly when the PoolManager's native balance covers it;
otherwise the hook mints itself an ERC-6909 ETH claim (`FeeClaimMinted`) and anyone can call
`redeemFeeClaims()` later to turn claims into ETH at the FeeSplitter. The FeeSplitter has a plain
`receive()`; if a recipient rejected ETH a direct take would halt fee-bearing swaps, a claim would
not, which is why the recipient is our own contract.

Owner (`$owner`, the dev wallet) powers: `setFees(shiftFeeBps, ethFeeBps)`, each capped at 250.
Nothing else in the hook is owner-settable.

Universal Router and Quoter: the hook ignores `hookData`, so empty hook data works. `V4_SWAP` with
`SWAP_EXACT_IN_SINGLE` / `SWAP_EXACT_OUT_SINGLE` plus `SETTLE_ALL` / `TAKE_ALL` is compatible: the
fee is expressed through hook deltas that the router sees in the final balance delta. The V4 Quoter
(`0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203`) simulates the same path and quotes net of the fee;
before trading opens, quotes revert for every origin except the first buyer, as swaps do. The tests
use an in-repo router (`test/mocks/Swapper.sol`) with the same settle/take semantics; the
Universal Router itself is not vendored.

### FeeSplitter

One fixed rule for every token (ETH is `address(0)`): 40% to `ShiftRewards`, 20% to the dev wallet
`0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5`, 20% to the treasury wallet
`0x3322E6DD06Ade8377F1f1BCb766f6133d7b64D69`, 20% burned. Burned means SHIFT to
`0x…dEaD`, IMD (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`) to IMD's BurnExecutor
(`0xe29386719C155B6847aD5a4E97C6674f10ffc750`), ETH and any other token into the burn reserve
(`reserve(token)`). All of these are compile-time constants.

- `distribute(address token)`: anyone; splits everything held above the reserve, forwards the rewards
  share and announces it to `ShiftRewards`, emits `Distributed(token, rewards, dev, treasury, burned)`.
  Rounding dust goes to the rewards share so every wei is accounted.
- `burnReserve(address token, uint256 amountIn, uint256 minImdOut)`: keeper only; swaps that much of
  the reserve to IMD on Uniswap v4 inside one `unlock`, requires at least `minImdOut`, takes all the
  IMD straight to the BurnExecutor, emits `ImdBurned(token, amountIn, imdOut)`. ETH swaps on the
  ETH/IMD pool; another token first swaps to ETH on its token/ETH pool, then to IMD, in the same call.
- `setKeeper(address)`: the owner's only setting (`KeeperSet`).
- `setImdPool(PoolKey)` and `setEthPool(token, PoolKey)`: keeper-set swap routes (`ImdPoolSet`,
  `EthPoolSet`). `burnReserve` reverts `RouteNotConfigured` until the route it needs is set.

### ShiftRewards

SHIFT staking with Synthetix `StakingRewards` style accounting over several reward tokens (ETH and
SHIFT and IMD registered from the start; only the owner can register more, with
`addRewardToken(token)`, `notifyReceived` or `notifyRewardAmount`; at most 16).

- `stake(amount, lockDays)` with `lockDays` 0 to 730. Each locked stake is a separate lock
  (at most 32 unexpired per account; expired locks are pruned). `withdraw(amount)` only moves
  unlocked stake. `getReward()` pays every token, `getReward(token)` one, `exit()` both.
- Views: `balanceOf`, `earned(account, token)`, `withdrawable`, `lockedBalance`, `locksOf`,
  `rewardPerToken`, `frogsPot(token)`, `epochInfo(epoch, token)`, `accounted(token)`.
- Events: `Staked(account, amount, unlockAt)`, `Withdrawn`, `RewardPaid(account, token, amount)`,
  plus `RewardAdded`, `FrogsPotFunded`, `RootPosted`, `FrogsClaimed`, `EpochSettled`.
- Every reward received through the splitter (ETH by `receive()`, tokens by `notifyReceived(token)`
  from the FeeSplitter or the owner) is split: half streams to stakers over 7 days, half to the NIGHT
  FROGS pot (`0x55b8C762f1b86fE1D5406EdaAAE0f8ecF3688A0c` holders) for that token.
- `postRoot(epoch, root, token, total)`: owner; reserves `total` from the pot, never more than it
  holds, one root per epoch and token, claimable 30 days. `claimFrogs(epoch, token, amount, proof)`
  verifies an OpenZeppelin StandardMerkleTree leaf
  `keccak256(bytes.concat(keccak256(abi.encode(epoch, account, token, amount))))`, once per account,
  epoch and token, and never beyond the epoch total. `settleEpoch(epoch, token)`: anyone, after 30
  days, returns what was not claimed to the pot.
- A token the FeeSplitter forwards that the owner has not registered still gets its frogs half in the
  pot; its staker half is held in `unstreamed(token)` and starts its 7-day stream when the owner calls
  `addRewardToken(token)`. Nobody but the owner can grow the reward-token list.
- Splitter income streams in `feeStream(token)`; the owner's `notifyRewardAmount` streams in
  `rewardData(token)`. They are separate, so fee income or a 1 wei deposit never reschedules the
  owner's stream. A splitter top-up restarts its own 7-day window (Synthetix behaviour).
- While nobody is staked the streams' clocks are paused: what would have streamed is carried forward
  and paid to the stakers that come next, so nothing is stranded.
- `getReward()` and `exit()` skip a token whose transfer fails (event `RewardPaymentFailed`), leaving it
  claimable; `exit()` with nothing unlocked still pays rewards.
- `notifyRewardAmount(token, amount, duration)`: owner adds an outside reward for stakers only
  (pulled by `transferFrom`, or sent as `msg.value` for ETH), streamed over 1 to 365 days.
- The owner cannot move staked SHIFT or earned rewards: there is no sweep or recover function, and
  `accounted(token)` tracks every liability so only true surplus is ever treated as a new reward.

### Revision notes

- Sells the pool cannot fill completely (price limit reached) revert with `PartialFill`, because the
  fee is sized from the specified amount. The V4 Quoter already refuses such quotes.
- Exact-output sells pay `shiftFeeBps` of everything the seller pays in SHIFT (grossed up), the same
  rate as exact-input sells.
- `setImdPool` / `setEthPool` accept only unhooked pools, and `burnReserve` requires `minImdOut > 0`.
  The keeper still chooses fee tier and `minImdOut`: it is a trusted role appointed by the owner.
- Trust assumption: the owner's `postRoot` decides who receives the NIGHT FROGS pot; nothing on
  chain links a leaf to an NFT holder.
- Design limit: the sell fee applies only on the hooked launch pool; other SHIFT pools (v2/v3/v4
  without this hook) pay no hook fee, as the token itself is plain.

## Test coverage

`forge test` runs 61 tests (4 suites) including fuzz tests. Run them with the verifier's seed:
`FOUNDRY_FUZZ_SEED=0xe8f69d5a97069c4b71fa2bf1ed5665e21603e46101b3c8af05b66bb01fc141a5 forge test`.

- Hook: flag/permission agreement, callbacks refuse non-manager callers, initialize refused for a
  non-factory sender, a second pool, a wrong pair and a dynamic fee; gate blocks buys and sells for
  every other origin, the first buyer as `msg.sender` but not origin; first buy through a foreign
  router opens trading and emits the event; a first-buyer sell does not open; one-wei first buy;
  first buy on a fresh PoolManager seeded with SHIFT only (no ETH anywhere); nothing else opens or
  closes trading; exact-input and exact-output sell fees with `FeeTaken`; buys pay no fee; fuzzed
  sell fee; lowered fees apply; fee cap (fixed and fuzzed); ETH claim fallback and redemption;
  zero-liquidity collect and liquidity removal pass through.
- FeeSplitter: ETH, SHIFT, IMD and other-token splits with exact amounts and event, fuzzed
  conservation, reserve bookkeeping, keeper and route access control, route validation,
  ETH reserve burn to the BurnExecutor with `minImdOut` success and failure, two-hop token burn,
  keeper rotation, callback access.
- ShiftRewards: stake/withdraw, locks (early withdraw refused, pruning, max locks, max days),
  half/half split, 7-day stream, pro rata by amount and time, token rewards via `notifyReceived`,
  SHIFT rewards separated from stakes, owner `notifyRewardAmount` success and failure, owner cannot
  take stakes or rewards, reward-token cap, full Merkle epoch lifecycle (post, bad proofs, claim,
  double claim, expiry, settle), epoch cap, fuzzed stream bound.
- Token: metadata, supply to deployer, exact transfer, no mint or owner.

The pinned protected suites (`Hook`, `Owners`, `Token`) were run locally from `test/scratch` against
the built creation code with `$token`/`$factory` probes and all 13 passed. `test/mocks/MockERC20.sol`,
`test/mocks/Swapper.sol` and `test/floor/OwnerChecks.sol` are the files those suites import.

## Launch parameters and assumptions

- Chain Ethereum (1). Pool: SHIFT paired with native ETH, `pool.fee` 12500, `tickSpacing` 60. The
  deployer sets the opening price from the policy's opening market cap.
- Hook constructor args: `$poolManager`, `$token`, `$owner`, `$factory`. Owner is the dev wallet
  `0x6C4c78f2C3bDf4C4318Fe305FB1C8BC1694d19b5` for the hook, FeeSplitter and ShiftRewards.
- Hook address flags: 8396 (`0x20CC`). Hook runtime ~6.7 KB, creation code ~26 KB (it embeds the two
  helpers); runtime has no DELEGATECALL, CALLCODE or SELFDESTRUCT.
- Constants chosen where the brief left a number open: staker stream 7 days (given), frogs claim
  window 30 days (given), `MAX_ACTIVE_LOCKS` 32, `MAX_REWARD_TOKENS` 16, owner stream duration
  bounds 1 to 365 days. Fee parts 250 bps each (given).
- Nothing here receives any of the supply at launch. ShiftRewards holds only what users stake and
  what the splitter sends it.
- `tx.origin` is used for the launch gate because the brief requires it; the security references
  warn against `tx.origin` for authorization in general. Here it gates only who may trade before
  opening and the first buyer is the treasury, which accepts that a contract it calls could trade in
  its transaction before the gate opens.
- The IMD/ETH venue for `burnReserve` is assumed to be a Uniswap v4 pool. Its `PoolKey` is not in
  the brief, so the keeper sets it after launch (see below). If IMD only trades on v2/v3, a route
  cannot be expressed and the reserve stays until a route exists; this is the one open point for the
  requester.
- Synthetix-style streams accrue nothing while `totalSupply == 0`; rewards streamed with no stakers
  stay in the contract (still counted in `accounted`) and are not redistributed.
- A hook that sells more than roughly 40x the pool's SHIFT reserve in one exact-input swap would
  try to take more SHIFT fee than the PoolManager holds and revert; with 88.89% of the supply in the
  pool this cannot happen.

## After launch (operational responsibilities)

1. Treasury wallet `0x3322…4D69` makes the first buy (any size, any router). Nobody else can trade
   until then.
2. Owner calls `FeeSplitter.setKeeper(keeper)` with the bot or multisig that will run burns.
3. Keeper calls `FeeSplitter.setImdPool(PoolKey)` with the ETH/IMD Uniswap v4 pool key
   (`currency0 = address(0)`, `currency1 = IMD`, its fee, tick spacing and hooks). For any non-ETH
   token that reaches the reserve, `setEthPool(token, PoolKey)` with that token's ETH pool.
4. Anyone may call `FeeSplitter.distribute(address(0))` and `distribute(SHIFT)` to split fees as
   they accrue, and `NightshiftHook.redeemFeeClaims()` if `pendingEthClaims()` is nonzero.
5. Keeper runs `burnReserve(token, amountIn, minImdOut)` with a `minImdOut` from a fresh quote.
6. Owner snapshots NIGHT FROGS holders per epoch, builds a StandardMerkleTree with leaves
   `[epoch, account, token, amount]`, and calls `ShiftRewards.postRoot(epoch, root, token, total)`.
   After 30 days anyone calls `settleEpoch(epoch, token)`.
7. Owner may add SHIFT (or other) rewards with `notifyRewardAmount` after approving ShiftRewards.

Tests passing is not an audit. The hook holds no funds, but FeeSplitter and ShiftRewards hold other
people's assets and should get an independent adversarial review before launch.
