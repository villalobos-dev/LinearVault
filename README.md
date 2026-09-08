# LinearVault

Linear payment streaming on-chain: an employer deposits a total amount of an ERC20 token in favour of
an employee, and that amount is released proportionally to the time elapsed until maturity.

## How it works

A **stream** is created by the employer with four parameters: the beneficiary, the duration in
**days**, the total amount to deposit and a lock period, also in **days**. Both time parameters are
converted to seconds on the way in, so the stored stream and the vesting math always work in
seconds. On creation, the full amount is transferred into
[`LinearVaultEngine`](src/LinearVaultEngine.sol) and the stream is stored under an incremental id,
indexed under both its employer and its employee.

From then on the vested amount grows linearly:

```
vested = totalAmount * (block.timestamp - startTime) / (endTime - startTime)
available = vested - amountWithdrawn
```

Rules enforced by the contract:

- Only the beneficiary (`employee`) can withdraw from their stream. There is no cancellation: once
  funded, the money can only ever move towards the employee.
- An employer cannot be the beneficiary of its own stream.
- Nothing can be withdrawn before the minimum lock period has elapsed.
- The lock period must not be longer than the stream duration.
- Once `endTime` is reached, the whole remainder is available at once.
- Withdrawals always subtract what has already been taken out.

Because the creation API is denominated in whole days, sub-day granularity is not expressible: the
shortest possible stream is one day.

Every stream of a given deployment is paid in the same ERC20 token, fixed at construction time and
immutable afterwards.

## Contracts

| File | Description |
| --- | --- |
| [`src/LinearVaultEngine.sol`](src/LinearVaultEngine.sol) | The streaming engine: creation, vesting math and withdrawals. |
| [`script/DeployLinearVault.s.sol`](script/DeployLinearVault.s.sol) | Deploys the engine together with a mock token (local networks and tests). |
| [`test/mocks/ERC20Mock.sol`](test/mocks/ERC20Mock.sol) | USDC-like test token: 6 decimals and EIP-2612 `permit`. |
| [`test/unit/LinearVaultEngineUnitTest.t.sol`](test/unit/LinearVaultEngineUnitTest.t.sol) | Unit tests for both creation paths, vesting and partial withdrawals. |

### Main entry points

- `createStream(employee, durationInDays, totalAmount, lockDurationInDays)` — requires a previous
  `approve` of `totalAmount`.
- `createStreamWithPermit(..., deadline, v, r, s)` — approves and creates in a single transaction
  using an EIP-2612 signature. The `permit` call is wrapped in a `try/catch` so a front-run of the
  signature does not break the transaction.
- `withdrawSpecificAmount(streamId, amount)` — withdraws part of the vested funds. An `amount` of
  zero is rejected.
- `withdrawMax(streamId)` — withdraws everything currently available. It is a no-op when there is
  nothing to withdraw, so it stays idempotent once a stream is fully paid out.
- `amountAvailableToWithdraw(streamId)` — read-only view of what can be withdrawn right now.

Every entry point that takes a `streamId` reverts with `LinearVaultEngine__InvalidStreamId` when the
id was never assigned, rather than reading a zeroed struct out of the mapping. The lookups by
address (`getStreamsByEmployer`, `getStreamsByEmployee` and their counters) take no id, so they
return an empty list for an address with no streams.

Plus one getter per `Stream` field (`getStream`, `getEmployer`, `getEmployee`, `getStartTime`,
`getEndTime`, `getTotalAmount`, `getAmountWithdrawn`, `getWithdrawableFrom`) and
`getLastIdStream()`, which returns the next id to be assigned.

Time can be read back in either unit. `getWithdrawableFrom` and `getStartTime` / `getEndTime` return
absolute timestamps in seconds; `getDurationInDays(streamId)` and `getLockDurationInDays(streamId)`
return the values the stream was created with, in days.

To find streams without an indexer:

- `getStreamsByEmployer(employer)` / `getStreamsByEmployee(employee)` — the ids of an address's
  streams, in creation order.
- `getStreamCountByEmployer(employer)` / `getStreamCountByEmployee(employee)` — the length of those
  lists, so a caller can page instead of fetching the whole array.

## Security notes

- Withdrawals follow the Check-Effects-Interactions pattern and are protected with
  OpenZeppelin's `ReentrancyGuardTransient`.
- Token transfers go through `SafeERC20`.
- Vesting relies on `block.timestamp`; the resolution of a validator's manipulation is negligible
  against the stream durations this contract targets.
- Only plain ERC20 tokens are supported. A fee-on-transfer or rebasing token would leave the
  contract insolvent, since `totalAmount` is recorded as the requested amount rather than the amount
  actually received. The intended token is USDC.

## Roadmap

Pending work — fuzz and invariant testing, Slither, the Sepolia deployment with `HelperConfig`, and
the frontend — is tracked in [`ROADMAP.md`](ROADMAP.md), together with the design decisions that
were deliberately left out of scope.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Usage

```shell
forge build          # compile
forge test           # run the test suite
forge test -vvv      # run with traces
forge fmt            # format
forge coverage       # coverage report
```

The [`Makefile`](Makefile) wraps the most common commands:

```shell
make build
make test
make mt testWithdrawn   # run a single test by name
make anvil              # local node
```

### Deploy

Against a local Anvil node:

```shell
make anvil                                    # in one terminal
forge script script/DeployLinearVault.s.sol:DeployLinearVault \
  --rpc-url http://localhost:8545 \
  --private-key <your_private_key> \
  --broadcast
```

Note that `DeployLinearVault` also deploys an `ERC20Mock` and uses it as the payment token, so it is
intended for local networks and tests. To deploy against a real token, pass its address to the
`LinearVaultEngine` constructor instead of the mock.

## License

MIT — see [`LICENSE`](LICENSE).
