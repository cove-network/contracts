# Sui Contract Upgrades

## How Upgrades Work on Sui

When you publish a package, Sui returns an `UpgradeCap` object. This capability controls who can upgrade the package and how.

## Publishing with Upgrade Capability

```bash
# Publish and save the UpgradeCap
sui client publish --gas-budget 100000000

# Output includes:
# - Package ID (the deployed contract address)
# - UpgradeCap object ID (SAVE THIS - it's your upgrade key)
```

**IMPORTANT**: Store the `UpgradeCap` object ID securely. Without it, you cannot upgrade.

## How Cove upgrades this package

Cove upgrades in place under the **`compatible`** policy — new functions, new
modules, and changed function bodies ship without disturbing any shared object
(the worker registry, escrow pool, treasury, and every balance are preserved).
Struct or signature changes are never upgraded in place; those require a fresh
publish.

The `UpgradeCap` is held on a **hardware wallet** (the project's super-admin
key), and every upgrade is signed as a normal on-chain transaction through the
Cove admin dashboard. So the upgrade authority is a single hardware-secured key,
and each upgrade is publicly verifiable on-chain against the source in this
repository.

## Upgrade Policies

Sui supports these upgrade policies (set at publish time):

| Policy | Can Add | Can Change | Can Remove |
|--------|---------|------------|------------|
| `compatible` (default) | Yes | No (signatures) | No |
| `additive` | Yes | No | No |
| `immutable` | No | No | No |

For production, use `compatible` - it allows adding new functions and types while preserving existing APIs.

## What CAN Be Upgraded

- Add new functions (including new `public` entry points — e.g. a `register_v2`
  beside an unchanged `register`)
- Add new structs/types
- Add new modules
- Change function implementations (logic / bodies)

## What CANNOT Be Upgraded

- **Add, remove, reorder, or retype fields on an existing struct** — a struct's
  layout is frozen at its first publish. This is the single most common
  misconception; there is no "add a field with care." Adding a field is a
  fresh-publish-only change.
- Change existing function signatures (params or return types)
- Remove existing public functions
- Change module names

### How Cove adds state without a republish

Because struct fields are frozen, every long-lived object ships with an empty
**`config: sui::bag::Bag`**: `EscrowPool`, `SettlementBatch`, `AdminRegistry`,
`WorkerRegistry`, `Worker`, `Treasury`, `VestingSchedule`, `VestingRegistry`,
`Presale`, and `PurchaseRegistry`. (`cove_token` is intentionally excluded — it
defines no mutable shared object; the COVE coin type's identity is frozen at
first publish and must never gain a field.) Future per-object state attaches into
that `Bag` (or as a dynamic field on the object's `UID`) as a *compatible*
upgrade — no struct change, no fresh publish. NOTE: the two ephemeral objects
(`SettlementBatch`, and any future deletable object) `bag::destroy_empty` their
bag on consume, so anything written into those must be removed before the object
is destroyed; the permanent singletons never destroy theirs.
Likewise, anything that would otherwise need a signature change is added as a
new `fn_v2` next to the original. Bound-style policy knobs (fees, caps, rep
curve, vesting durations) are plain mutable fields with admin setters, so they
retune live without any upgrade at all. **Plan new state to land in the `Bag` or
a new function — never by editing a struct.**

## Performing an Upgrade

```bash
# 1. Make your changes to the Move code

# 2. Build to verify
sui move build

# 3. Upgrade using the UpgradeCap
sui client upgrade --gas-budget 100000000 --upgrade-capability <UPGRADE_CAP_ID>

# The new package gets a new ID, but shares objects remain accessible
```

## Best Practices

1. **Version your contracts** - every shared object carries a `version` constant
   guarded by `EWrongVersion`; bump it and add a `migrate()` when an upgrade
   changes an object's interpretation
2. **Test upgrades on testnet first**
3. **Keep the UpgradeCap on hardware** - hold it on a hardware wallet (or a
   multisig); never a hot key. Cove holds it on the super-admin's hardware wallet
   and signs each upgrade through the admin dashboard
4. **Design new state into the `config` Bag, not new struct fields** (see above)
5. **Document breaking changes** - struct/signature changes need a fresh publish + migration

## Example: Adding a New Feature

```move
// Original pool_escrow.move
module cove::pool_escrow {
    const VERSION: u64 = 1;
    // ... existing code
}

// After upgrade
module cove::pool_escrow {
    const VERSION: u64 = 2;

    // NEW: Add a new function (allowed)
    public fun new_feature(...) { ... }

    // EXISTING: Can change implementation, not signature
    public fun deposit(...) {
        // Changed logic is OK
    }
}
```

## Emergency: Immutable Fallback

If you lose the UpgradeCap or want to make contracts truly immutable:

```bash
# Make package immutable (IRREVERSIBLE)
sui client make-immutable <UPGRADE_CAP_ID>
```

## Multisig UpgradeCap (Recommended for Production)

```bash
# Transfer UpgradeCap to a multisig address
sui client transfer --to <MULTISIG_ADDRESS> --object-id <UPGRADE_CAP_ID>
```

This ensures no single party can upgrade without consensus.
