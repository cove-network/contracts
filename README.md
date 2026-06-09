# Cove Protocol — Smart Contracts

Move source code for the **Cove Protocol** — a decentralized network for
video transcoding on the [Sui blockchain](https://sui.io). Customers
pay COVE to transcode videos; operators earn COVE for processing them;
the protocol takes a 2.5% fee.

🌐 **Live testnet**: [testnet.covelabs.xyz](https://testnet.covelabs.xyz)
📖 **Docs**: [testnet.covelabs.xyz/docs](https://testnet.covelabs.xyz/docs)
📄 **Whitepaper**: [testnet.covelabs.xyz/whitepaper](https://testnet.covelabs.xyz/whitepaper)
💬 **Discord**: [discord.gg/AsjX6PkJbu](https://discord.gg/AsjX6PkJbu)
🐦 **X**: [@cove_labs](https://twitter.com/cove_labs)

> **Status**: Live on Sui Testnet. Mainnet target: Q3-Q4 2026.

---

## What's in this repo

Six Move modules implementing the protocol:

| Module | What it does |
|---|---|
| [`cove_token`](sources/cove_token.move) | The COVE coin type. Defines the 10B fixed supply. |
| [`admin_registry`](sources/admin_registry.move) | Admin role management. Two-step super-admin transfer, per-admin labels, audit events. |
| [`treasury`](sources/treasury.move) | Six-pool token distribution: presale, team, liquidity, community, reserve, fee. Per-pool withdrawal caps. `lock_supply` permanently destroys the TreasuryCap. |
| [`worker_registry`](sources/worker_registry.move) | Operator registry. Per-node `Worker` objects, tier system (Bronze→Platinum), suspend/ban mechanisms. |
| [`pool_escrow`](sources/pool_escrow.move) | Client deposit + per-job settlement. 2.5% protocol fee retained on every payout. |
| [`presale`](sources/presale.move) | 5-stage bonding-curve presale with linear vesting (25% immediate + 75% over 90 days). `parameters_frozen` flag locks contract terms on first purchase. |

Tests live in [`tests/`](tests/). Run them with:

```sh
sui move test
```

---

## Building

You'll need the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install) installed.

```sh
# Verify your toolchain
sui --version

# Build the package (compiles all 6 modules)
sui move build

# Run the test suite
sui move test

# Run a specific test
sui move test --filter test_purchase_within_stage
```

The package targets Sui Move **[edition 2024.beta](https://move-book.com)** — the latest beta
edition with current experimental language features — built against
the Sui testnet framework branch (see [`Move.toml`](Move.toml)). For
Sui-specific Move patterns (objects, abilities, capabilities), see
the [Sui Move concepts docs](https://docs.sui.io/concepts/sui-move-concepts).

---

## Live deployments

The active **testnet** deployment lives at the following object IDs.
Verify any field directly on Suiscan:

| Object | ID |
|---|---|
| **Package** | [`0x6a1aa3d8…`](https://suiscan.xyz/testnet/object/0x6a1aa3d83bb71f82b24198a8471c2eaee87d07548f279766f9a2b544bb601884) |
| **AdminRegistry** | [`0x4daf4db3…`](https://suiscan.xyz/testnet/object/0x4daf4db39459c29eff750dd043572f848d274219f1d107ad27f3ccb965ee1307) |
| **Treasury** | [`0x6e90238d…`](https://suiscan.xyz/testnet/object/0x6e90238d8f33f9fc3066b129c4e2b46dfaed1ac4a541486a9e0ac1fd5d646dd0) |
| **WorkerRegistry** | [`0x2980da7f…`](https://suiscan.xyz/testnet/object/0x2980da7f9a625ef0695775964c5246e3d8346e9fbe56a8751d54d9e05ec434d4) |
| **EscrowPool** | [`0x4e5ebbf5…`](https://suiscan.xyz/testnet/object/0x4e5ebbf588c50e8316a9be84e234a1d480af43535e627e2f101f6dcdd15f2f1b) |
| **Presale** | [`0x1cd299f0…`](https://suiscan.xyz/testnet/object/0x1cd299f05b034c5fc36c599e51b622655fbf0826b8cc1853b2ac5ab1741eae56) |
| **PurchaseRegistry** | [`0x13e6afc7…`](https://suiscan.xyz/testnet/object/0x13e6afc703f4e9f8401220b969d2a816168b2982318576a2595d556139ee4b3c) |

Mainnet deployment will be added here when it ships.

---

## Security posture

We're a small team shipping pre-mainnet, so the security story is
honest and layered rather than dependent on a single named-firm audit:

### What we've done

- **Test coverage**: A comprehensive Move test suite exercising every
  public entry function, including edge cases (zero-value purchases,
  overflow checks, cap-window rollovers, multi-stage vesting math,
  refund flows, parameter-freeze enforcement). Run it yourself:
  `sui move test`.
- **Internal security review**: Completed before each testnet
  deployment. All identified issues are resolved before code is pushed
  to chain. The current testnet package incorporates findings from
  multiple internal review passes.
- **Defense in depth**: Multiple independent guards on every
  high-value operation — per-pool withdrawal caps, rolling-window
  rate limits, super-admin gates, freeze flags on buyer-facing
  parameters, and a permanent supply lock that destroys the mint
  capability.
- **Open source**: This repository. The Sui Move ecosystem is small
  enough that real bugs surface when code is public. We welcome
  community review.

### What we haven't done (yet)

- **Third-party paid audit**: Resource-constrained pre-mainnet. We
  intend to fund a formal audit once protocol revenue begins. In the
  meantime, the code is public for review.
- **Formal verification**: Out of scope for this version.

### Bug bounty

See [SECURITY.md](SECURITY.md) for how to report a vulnerability and
the responsible-disclosure policy.

---

## License

[MIT](LICENSE) — permissive use, including commercial. Just keep the
copyright notice.

---

## Contributing

Bug reports, code review, and well-scoped PRs are very welcome —
especially from the Sui Move community.

For security issues, please do **NOT** open a public issue. See
[SECURITY.md](SECURITY.md).

For everything else: open an issue on this repo or drop into
[Discord](https://discord.gg/AsjX6PkJbu).
