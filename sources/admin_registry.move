/// Admin Registry -- On-chain access control for the Cove decentralized transcoding network.
///
/// This module is the single source of truth for administrator privileges across the
/// Cove protocol. It manages two tiers of access:
///
///   1. **Super Admin** -- The deployer address (or its transferee). Can add and remove
///      regular admins, and transfer the super-admin role itself.
///   2. **Regular Admins** -- Addresses granted admin status by the super admin. They
///      can act as admins in other Cove contracts and may voluntarily renounce their
///      own status, but cannot modify anyone else's.
///
/// The `AdminRegistry` is published as a **shared object** so that any transaction can
/// read it (e.g. the orchestrator calling `is_admin` for auth checks), while mutations
/// are gated by on-chain sender assertions. This means that even if the off-chain
/// orchestrator server is fully compromised, an attacker cannot escalate privileges --
/// only the super-admin's signing key can grant admin access.
///
/// Design notes:
/// - The super admin is *implicitly* an admin; it is never stored in the `admins` table.
///   `is_admin` checks both the table and the `super_admin` field.
/// - A `version` field follows the standard Sui upgrade-safety pattern: every mutating
///   entry point asserts `version == VERSION`, and a `migrate` function bumps old
///   objects forward after a package upgrade.
/// - Error-code numeric values are part of the contract ABI -- do not renumber them.
module cove::admin_registry {
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;

    // ===  Error Codes ===
    // Values are ABI-stable; do not renumber.

    /// Caller is not the super admin.
    const ENotSuperAdmin: u64 = 0;
    /// Target address is not a registered admin.
    const ENotAdmin: u64 = 1;
    /// Target address is already a registered admin (or is the super admin).
    const EAlreadyAdmin: u64 = 2;
    /// Cannot remove or renounce the super admin via admin-removal paths.
    /// The super admin must use `transfer_super_admin` instead.
    const ECannotRemoveSuperAdmin: u64 = 3;
    /// Object version does not match the current package version.
    /// Call `migrate` first after a package upgrade.
    const EWrongVersion: u64 = 5;
    /// No pending super-admin transfer to accept.
    const ENoPendingTransfer: u64 = 6;

    // === Version Constant ===

    /// Current package version. Bumped on each contract upgrade so that old
    /// `AdminRegistry` objects can be migrated forward via `migrate`.
    const VERSION: u64 = 1;

    // === Core Types ===

    /// The shared registry object that stores all admin state.
    ///
    /// Created once during `init` and immediately shared. There is exactly one
    /// instance on-chain. Other Cove modules take `&AdminRegistry` to verify
    /// caller permissions without needing their own access-control logic.
    public struct AdminRegistry has key {
        id: UID,
        /// Object version -- must equal `VERSION` for any mutating call to succeed.
        version: u64,
        /// The super-admin address. Initially the deployer; transferable via
        /// the two-step `propose_super_admin` + `accept_super_admin` flow.
        /// In production this should be a multisig or governance-controlled address.
        super_admin: address,
        /// Pending super-admin for two-step transfer. `option::none()` when no
        /// transfer is in progress.
        pending_super_admin: Option<address>,
        /// Lookup table of regular admins. The super admin is *not* stored here;
        /// it is treated as an implicit admin in all read paths.
        admins: Table<address, AdminInfo>,
        /// Number of entries in `admins` (excludes super admin).
        admin_count: u64,
    }

    /// Metadata attached to each regular admin entry.
    public struct AdminInfo has store, drop {
        /// Epoch timestamp (ms) at which this admin was added.
        added_at: u64,
        /// The address (always the super admin) that granted this admin status.
        added_by: address,
        /// Free-form label supplied at registration time (e.g. "ops-bot", "alice").
        label: vector<u8>,
    }

    // === Events ===
    // Emitted on every admin-set mutation so indexers and the orchestrator can
    // react to permission changes without polling.

    /// Emitted when a new regular admin is added.
    public struct AdminAdded has copy, drop {
        admin: address,
        added_by: address,
        timestamp: u64,
    }

    /// Emitted when an admin is removed (by the super admin or by self-renunciation).
    public struct AdminRemoved has copy, drop {
        admin: address,
        removed_by: address,
        timestamp: u64,
    }

    /// Emitted when the super-admin role is transferred to a new address.
    public struct SuperAdminTransferred has copy, drop {
        old_super_admin: address,
        new_super_admin: address,
        timestamp: u64,
    }

    // === Initialization ===

    /// Module initializer -- called exactly once at publish time.
    ///
    /// Creates the `AdminRegistry` shared object with the transaction sender as
    /// the initial super admin and an empty admin table.
    fun init(ctx: &mut TxContext) {
        let registry = AdminRegistry {
            id: object::new(ctx),
            version: VERSION,
            super_admin: tx_context::sender(ctx),
            pending_super_admin: option::none(),
            admins: table::new(ctx),
            admin_count: 0,
        };

        transfer::share_object(registry);
    }

    // === Admin Management ===

    /// Register a new regular admin.
    ///
    /// Callable by: **super admin only**.
    ///
    /// Aborts if `new_admin` is already in the table or is the super admin
    /// (who is implicitly an admin and must not be double-registered).
    /// Emits `AdminAdded`.
    public fun add_admin(
        registry: &mut AdminRegistry,
        new_admin: address,
        label: vector<u8>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        assert!(sender == registry.super_admin, ENotSuperAdmin);
        assert!(!table::contains(&registry.admins, new_admin), EAlreadyAdmin);
        assert!(new_admin != registry.super_admin, EAlreadyAdmin); // super_admin is implicitly admin

        let timestamp = clock::timestamp_ms(clock);
        let info = AdminInfo {
            added_at: timestamp,
            added_by: sender,
            label,
        };

        table::add(&mut registry.admins, new_admin, info);
        registry.admin_count = registry.admin_count + 1;

        event::emit(AdminAdded {
            admin: new_admin,
            added_by: sender,
            timestamp,
        });
    }

    /// Revoke a regular admin's status.
    ///
    /// Callable by: **super admin only**.
    ///
    /// The super admin cannot remove themselves through this path -- they must
    /// use `transfer_super_admin` to hand off the role first.
    /// Emits `AdminRemoved`.
    public fun remove_admin(
        registry: &mut AdminRegistry,
        admin_to_remove: address,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        assert!(sender == registry.super_admin, ENotSuperAdmin);
        assert!(admin_to_remove != registry.super_admin, ECannotRemoveSuperAdmin);
        assert!(table::contains(&registry.admins, admin_to_remove), ENotAdmin);

        table::remove(&mut registry.admins, admin_to_remove);
        registry.admin_count = registry.admin_count - 1;

        let timestamp = clock::timestamp_ms(clock);
        event::emit(AdminRemoved {
            admin: admin_to_remove,
            removed_by: sender,
            timestamp,
        });
    }

    /// Propose transferring the super-admin role to a new address.
    ///
    /// Callable by: **super admin only**.
    ///
    /// This is step 1 of a two-step transfer. The proposed address must call
    /// `accept_super_admin` to finalize. Until then, the current super admin
    /// retains full control and can call `cancel_super_admin_transfer` to revoke.
    public fun propose_super_admin(
        registry: &mut AdminRegistry,
        new_super_admin: address,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == registry.super_admin, ENotSuperAdmin);
        registry.pending_super_admin = option::some(new_super_admin);
    }

    /// Accept a pending super-admin transfer.
    ///
    /// Callable by: **the pending super admin only**.
    ///
    /// Finalizes the transfer proposed via `propose_super_admin`. The caller
    /// becomes the new super admin. If they were previously a regular admin,
    /// they are removed from the table (since the super admin is implicit).
    ///
    /// Emits `SuperAdminTransferred`.
    public fun accept_super_admin(
        registry: &mut AdminRegistry,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(option::is_some(&registry.pending_super_admin), ENoPendingTransfer);
        let new_super_admin = *option::borrow(&registry.pending_super_admin);
        assert!(tx_context::sender(ctx) == new_super_admin, ENotSuperAdmin);

        let old_super_admin = registry.super_admin;
        registry.super_admin = new_super_admin;
        registry.pending_super_admin = option::none();

        // If new super_admin was in the admins table, remove them
        // (they're now implicitly admin as super_admin)
        if (table::contains(&registry.admins, new_super_admin)) {
            table::remove(&mut registry.admins, new_super_admin);
            registry.admin_count = registry.admin_count - 1;
        };

        let timestamp = clock::timestamp_ms(clock);
        event::emit(SuperAdminTransferred {
            old_super_admin,
            new_super_admin,
            timestamp,
        });
    }

    /// Cancel a pending super-admin transfer.
    ///
    /// Callable by: **super admin only**.
    /// Revokes a previously proposed transfer before acceptance.
    public fun cancel_super_admin_transfer(
        registry: &mut AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(tx_context::sender(ctx) == registry.super_admin, ENotSuperAdmin);
        registry.pending_super_admin = option::none();
    }

    /// Voluntarily give up admin status.
    ///
    /// Callable by: **any regular admin** (for their own address only).
    ///
    /// The super admin cannot renounce -- they must `transfer_super_admin` first.
    /// This allows admins to off-board themselves without requiring super-admin
    /// intervention (useful for key rotation or decommissioning bots).
    ///
    /// Emits `AdminRemoved` with `removed_by == admin`.
    public fun renounce_admin(
        registry: &mut AdminRegistry,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        assert!(sender != registry.super_admin, ECannotRemoveSuperAdmin); // super_admin must transfer first
        assert!(table::contains(&registry.admins, sender), ENotAdmin);

        table::remove(&mut registry.admins, sender);
        registry.admin_count = registry.admin_count - 1;

        let timestamp = clock::timestamp_ms(clock);
        event::emit(AdminRemoved {
            admin: sender,
            removed_by: sender,
            timestamp,
        });
    }

    // === View Functions ===
    // Read-only accessors used by the orchestrator and other on-chain modules
    // to check permissions. None of these mutate state.

    /// Returns `true` if `addr` has any admin privileges (super or regular).
    ///
    /// This is the primary authorization check used by the orchestrator when
    /// validating incoming requests. Other Cove modules also call this to
    /// gate admin-only entry points.
    public fun is_admin(registry: &AdminRegistry, addr: address): bool {
        addr == registry.super_admin || table::contains(&registry.admins, addr)
    }

    /// Returns `true` if `addr` is specifically the super admin.
    public fun is_super_admin(registry: &AdminRegistry, addr: address): bool {
        addr == registry.super_admin
    }

    /// Returns the current super-admin address.
    public fun super_admin(registry: &AdminRegistry): address {
        registry.super_admin
    }

    /// Returns the number of regular admins (does not count the super admin).
    public fun admin_count(registry: &AdminRegistry): u64 {
        registry.admin_count
    }

    /// Look up detailed info for an address.
    ///
    /// Returns a tuple `(is_admin, added_at, added_by)`:
    /// - For the super admin: `(true, 0, @0x0)` -- sentinel values since the
    ///   super admin was never "added" through the normal flow.
    /// - For a regular admin: `(true, <timestamp>, <granter>)`.
    /// - For a non-admin: `(false, 0, @0x0)`.
    public fun get_admin_info(registry: &AdminRegistry, addr: address): (bool, u64, address) {
        if (addr == registry.super_admin) {
            // Super admin - return special values
            (true, 0, @0x0)
        } else if (table::contains(&registry.admins, addr)) {
            let info = table::borrow(&registry.admins, addr);
            (true, info.added_at, info.added_by)
        } else {
            (false, 0, @0x0)
        }
    }

    // === Migration ===

    /// Bump the on-chain registry to the current package version after an upgrade.
    ///
    /// Callable by: **super admin only**.
    ///
    /// Must be called before any other mutating function will succeed on an
    /// old-version object. Aborts if the object is already at (or ahead of) the
    /// current `VERSION`.
    public fun migrate(
        registry: &mut AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(tx_context::sender(ctx) == registry.super_admin, ENotSuperAdmin);
        assert!(registry.version < VERSION, EWrongVersion);
        registry.version = VERSION;
    }

    // === Test Helpers ===

    #[test_only]
    /// Exposes `init` for unit tests so they can create an `AdminRegistry`
    /// without going through the publish flow.
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }
}
