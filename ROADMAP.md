# Roadmap

Work that is planned but not done yet. The contract itself is feature-complete for its current
scope; what follows is testing depth, tooling, deployment and the client that will consume it.

Ordered roughly by what unblocks the most: testing and static analysis first, since they can change
the contract, and doing them before the frontend exists avoids redoing the ABI wiring afterwards.
Sections 6 and 7 are not tasks — one is a decision still to be made, the other records decisions
already taken.

---

## 1. Fuzz testing

The suite is 27 unit tests, all with fixed values: a 30 day stream of 1000 mUSDC with a 7 day lock.
That covers the intended paths but says nothing about the input space.

**To do:**

- [ ] Fuzz `createStream` over `_durationInDays`, `_totalAmount` and `_lockDurationInDays`, bounding
      them to plausible ranges with `bound()` so runs are not wasted on reverts.
- [ ] Fuzz withdrawals: warp to an arbitrary point in the stream and assert the vested amount never
      exceeds `totalAmount` and never goes below `amountWithdrawn`.
- [ ] Invariant test with a handler: the one that matters is

      sum over streams of (totalAmount - amountWithdrawn)  <=  token.balanceOf(engine)

      This is the solvency property. It would have caught the fee-on-transfer problem on its own.
- [ ] Invariant: `amountWithdrawn <= totalAmount` for every stream, at all times.
- [ ] Invariant: a stream past `endTime` always pays out exactly `totalAmount`, no more and no less.

**Worth probing specifically:**

- Very small `_totalAmount` over long durations. A 100-unit stream (0.0001 USDC) over 365 days
  vests nothing for a long while, because the division truncates to zero. Not a bug — the total is
  paid in full at `endTime` — but the fuzzer should confirm no value is ever lost.
- Many streams for the same employee, to see the index arrays grow.
- Withdrawals at `endTime` exactly, and one second before and after.

---

## 2. Security analysis with Slither

Never run against this codebase.

**To do:**

- [ ] `pip install slither-analyzer` and run `slither .` over `src/`.
- [ ] Triage every finding: fix, or annotate with a justification.
- [ ] Add Slither to CI (`.github/workflows/test.yml`) so regressions surface on push.

**Expected findings, already understood:**

- `block.timestamp` used in comparisons. Known and accepted: validator drift is seconds against
  streams that last days. `forge build` already emits this as a lint warning.
- The `try/catch` around `permit` swallowing every error. This one is a real open item, see §5.

**Also worth running:**

- [ ] `forge coverage` — no coverage numbers have been collected so far.
- [ ] Consider Aderyn or Mythril as a second opinion before any mainnet deployment.

---

## 3. Deployment to Sepolia with HelperConfig

`DeployLinearVault.s.sol` always deploys a fresh `ERC20Mock` and wires it as the payment token, so
it only makes sense on a local node. There is no network switching.

**To do:**

- [ ] Write `script/HelperConfig.s.sol` following the usual pattern: a `NetworkConfig` struct
      returning the token address per chain id.
  - **Sepolia (11155111):** the real USDC at `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`, per
    [Circle's contract address list](https://developers.circle.com/stablecoins/usdc-contract-addresses).
    Re-check it against that page at deploy time rather than trusting this copy.
  - **Anvil (31337):** deploy `ERC20Mock` on the fly, as the script does today.
- [ ] Rework `DeployLinearVault` to read the token from `HelperConfig` instead of always minting a
      mock.
- [ ] Fix the `Makefile`: the `deploy` target still points at `script/DeployDSC.s.sol:DeployDSC`,
      which does not exist in this repo — it was copied over from another project.
- [ ] Also fix `make install` there: it installs OpenZeppelin v4.8.3, while the code uses
      `ReentrancyGuardTransient`, which only exists in v5.
- [ ] Add `.env.example` with `SEPOLIA_RPC_URL`, `PRIVATE_KEY` and `ETHERSCAN_API_KEY`. `.gitignore`
      already excludes `.env` but keeps `.env.example`.
- [ ] Verify the contract on Etherscan as part of the deploy (`--verify`).
- [ ] Write down the deployed address in the README once it is live.

**Note on testing against Sepolia USDC:** it has 6 decimals like the mock, so the amounts carry
over. Getting test USDC requires a faucet or a swap; plan for that before the first end-to-end run.

---

## 4. Frontend

Nothing exists yet. The contract is ready to be consumed: since `getStreamsByEmployer` and
`getStreamsByEmployee` were added, a client can list an address's streams without an indexer.

**To do:**

- [ ] Pick the stack. Suggested: React + wagmi/viem + RainbowKit for wallet connection.
- [ ] Export the ABI from `out/LinearVaultEngine.sol/LinearVaultEngine.json`, ideally as a build
      step so it never drifts from the contract.
- [ ] **Employer view:** create a stream (with the two time fields in days, matching the contract's
      API), and list funded streams via `getStreamsByEmployer`.
- [ ] **Employee view:** list streams via `getStreamsByEmployee`, show the amount available in real
      time, and withdraw (full or partial).
- [ ] A progress bar over the vesting is the natural visual for this: `elapsed / duration`,
      recomputed client-side between blocks so it moves continuously.
- [ ] Support the `permit` path: sign the EIP-2612 message in the browser and call
      `createStreamWithPermit`, so the employer signs once instead of doing approve + create.

**Details that will come up:**

- USDC has 6 decimals, not 18. Format with `formatUnits(value, 6)`.
- The day/second split matters at the boundary: the creation form takes **days**, while
  `getStartTime` / `getEndTime` / `getWithdrawableFrom` return **timestamps in seconds**. Use
  `getDurationInDays` / `getLockDurationInDays` when what you want to show is the configured value.
- Decode the custom errors so the UI can show something better than "transaction reverted". They are
  all prefixed `LinearVaultEngine__`.
- `withdrawMax` is a no-op when there is nothing available, so the button can stay enabled without
  risking a revert — but disabling it when the available amount is zero is better UX.

---

## 5. Contract items still open

Carried over from the review, not urgent but not resolved either.

- [ ] **The `try/catch` around `permit` swallows every failure.** The front-running rationale is
      sound, but as written it also hides malformed signatures, expired deadlines and tokens with no
      `permit` at all. The failure then resurfaces as an opaque allowance revert. Fix: in the
      `catch`, check `allowance >= _totalAmount` and revert with a dedicated error if not. This
      matters mainly if the protocol is ever deployed to an L2 where the bridged `USDC.e` does not
      expose EIP-2612 the same way.
- [ ] **No minimum `_totalAmount`.** A stream small enough relative to its duration vests nothing
      for a long time, which looks broken from the outside even though it is arithmetically correct.
- [ ] **`withdrawTo(streamId, destination)`.** The only escape hatch left for dead capital. USDC can
      blacklist addresses; if an employee is blacklisted or loses their key, their funds are stuck
      forever, since there is deliberately no cancellation. Letting the employee — and only the
      employee — nominate a destination solves it without handing the employer any power over the
      money. This does not weaken the guarantee the protocol is built on: once funded, the money can
      only ever move towards the employee.
- [ ] **`forge fmt --check` currently fails** on `src/LinearVaultEngine.sol` and the test file, which
      means CI is red. The differences are import formatting and line breaks, not logic. Run
      `forge fmt` and commit the result.

---

## 6. Yield on idle capital — to evaluate

Not decided either way. Worth assessing properly before committing, because it changes the risk
profile of the whole protocol.

**Why it is tempting:** the money sitting in the contract is idle. In a year-long stream, roughly
half the capital is unproductive on average, across every stream at once. Putting it to work is
economically sound and is what makes the difference between a vault and a protocol.

**The two questions that decide everything.** Neither is a coding problem, and both must be answered
before writing any code:

1. **Who owns the yield?** The unvested money is not the employee's yet — it belongs to the employer
   until it vests. The defensible options are: it goes to the employer (it is their capital), it is
   split, or it funds the protocol. Whichever it is, it has to be fixed at stream creation and
   visible to both parties, never implicit.
2. **Who eats a loss?** If the deployed capital loses value, someone absorbs it. If it is the
   employee, they are being handed credit risk on their own salary without having asked for it. That
   would break the guarantee this protocol exists to provide.

**The risk this introduces.** Today the contract guarantees the money is always there. Deploying it
elsewhere replaces that certainty with liquidity risk: an employee goes to withdraw earned salary
and the funds are out working. A payroll vault that cannot pay on time has failed at its only job —
that is worse than earning nothing.

**If it goes ahead, the shape that is actually viable:**

- [ ] Deposit into an existing ERC-4626 vault (Aave, Morpho) rather than building a lending market
      from scratch. A lending market is oracles, collateral, liquidations, interest curves and bad
      debt — an entire protocol on its own, and where most historical hacks concentrate.
- [ ] Keep a liquidity buffer covering 100% of what is vested-but-unwithdrawn at all times. Only
      unvested capital is ever eligible to be deployed.
- [ ] Withdrawals must divest automatically if the buffer falls short, so the employee never sees a
      failed withdrawal.
- [ ] Opt-in per stream, never the default. An employer who wants a plain vault keeps a plain vault.
- [ ] Model what happens if the underlying vault is paused, exploited, or its withdrawals are
      throttled. That is the scenario that decides whether this is viable at all.

**The honest counter-argument**, worth keeping in view: this turns a contract with a very small
attack surface into one with external dependencies and an upgrade path it does not control. The
yield has to be worth that, and for payroll the answer may well be that it is not.

**Original idea, for the record:** letting employees keep their money in the protocol so it funds
loans to others, with the borrowers paying a premium the employees earn a share of. The section
above is the same intuition rebuilt around an existing vault instead of a bespoke lending market,
which is what makes it tractable.

---

## 7. Explicitly out of scope

Decisions already taken, recorded so they are not reopened by accident.

- **Employer-initiated cancellation.** Rejected by design. If the employer could reclaim unvested
  funds, an employee who did the work could be left unpaid, and the vault would stop being a
  guarantee. If separations ever need handling, the way that preserves the guarantee is mutual
  cancellation (both parties sign) or a `cancelable` flag fixed at creation, so the employee knows
  up front what they are accepting.
- **Fee-on-transfer and rebasing token support.** The contract records `totalAmount` as the
  requested amount rather than the amount actually received, so such a token would leave it
  insolvent. The target token is USDC, which is neither. This is documented in the README's security
  notes and in the NatSpec of `createStream`.
