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

- Add new functions
- Add new structs/types
- Add new modules
- Change function implementations (logic)
- Add new fields to existing structs (with care)

## What CANNOT Be Upgraded

- Change existing function signatures
- Remove existing public functions
- Change struct field types
- Remove struct fields
- Change module names

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

1. **Version your contracts** - Add a `version` constant to track deployments
2. **Test upgrades on testnet first**
3. **Keep UpgradeCap in a multisig** - For production, transfer to a multisig address
4. **Document breaking changes** - Some changes require migration

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
