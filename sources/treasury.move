/// Treasury — central token distribution, vesting, and platform-fee management for the
/// Cove decentralized transcoding network.
///
/// Holds the `TreasuryCap`, manages the full COVE supply lifecycle, and enforces per-pool
/// withdrawal caps so that an admin-key compromise cannot drain everything in one tx.
///
/// 1. **Initialization.** After `cove_token` is published, the admin calls
///    `create_treasury()` with the one-time `TreasuryCap`, then `initialize_distribution()`
///    to mint the entire 10B COVE supply into five pools.
///
/// 2. **Pool allocations (10B total, 9 decimals):**
///
///    | Pool           |  COVE   | % | Drain rule |
///    |----------------|---------|---|------------|
///    | presale_pool   |  2.5B   |25%| Loaded once into `cove::presale` at init |
///    | team_pool      |  2.5B   |25%| 4-year linear vesting + 1-year cliff   |
///    | liquidity_pool |  3.0B   |30%| Funded once at DEX listing             |
///    | community_pool |  1.0B   |10%| Funds chunkify payouts + ecosystem grants |
///    | reserve_pool   |  1.0B   |10%| Strategic reserve, "break glass" only  |
///
///    Public-sale price discovery happens on a DEX (Cetus / Sui-native AMM) post-launch
///    rather than via an on-chain sale contract.
///
/// 3. **Withdrawal caps.** Every admin-discretionary withdraw (`withdraw_presale`,
///    `withdraw_community_rewards`, `withdraw_liquidity`, `withdraw_reserve`,
///    `withdraw_fees`) is gated by a per-pool rolling-window cap. A withdrawal that would
///    push cumulative outflow past `cap_per_window` aborts. The super-admin can retune
///    caps at any time via `set_admin_withdrawal_cap()`. Setting a cap to 0 effectively
///    pauses that pool's discretionary withdrawals.
///
///    Caps do NOT apply to:
///    - `release_vested_tokens` — bounded by the vesting schedule on-chain
///    - `deposit_fees` — inflow only
///    - `add_to_community_pool` / `add_to_liquidity_pool` — admin INFLOWS (moving tokens
///      INTO pools is fine; the danger is admin OUTFLOWS)
///
/// 4. **Team vesting.** Uses `VestingSchedule` shared objects with linear vesting after a
///    1-year cliff. Anyone can call `release_vested_tokens` on behalf of a beneficiary
///    since the schedule is a shared object.
///
/// 5. **Platform fees.** `treasury.fee_pool` is a long-term fee reserve, distinct from
///    `pool_escrow.fee_pool` (which collects fees during settlement in real time). Admin
///    bridges fees from `pool_escrow` into `treasury.fee_pool` via `deposit_fees()`.
///
/// 6. **Supply locking.** After `initialize_distribution()` mints the full 10B supply,
///    `lock_supply()` freezes the `TreasuryCap` permanently — no further minting.
///
/// 7. **Upgrade safety.** Treasury / VestingSchedule / VestingRegistry each carry a
///    `version` field. After a package upgrade bumps `VERSION`, the admin must call the
///    corresponding `migrate_*` function before the object can be used.
///
/// 8. **Admin auth.** All admin-gated functions consult `AdminRegistry` — there is no
///    module-local admin field. Cap-setting requires the super-admin specifically
///    (one wallet, not all admins) so a regular admin can't loosen caps.
module cove::treasury {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::bag::{Self, Bag};
    use sui::event;
    use cove::cove_token::COVE_TOKEN;
    use cove::admin_registry::{Self, AdminRegistry};

    // ─── Error codes ────────────────────────────────────────────────────────

    /// Caller is not an admin in the AdminRegistry.
    const ENotAdmin: u64 = 0;
    /// Caller is not the super-admin (required for cap mutations).
    const ENotSuperAdmin: u64 = 1;
    /// Pool does not have enough tokens for the requested operation.
    const EInsufficientBalance: u64 = 2;
    /// Cliff period has not elapsed yet; no tokens may be released.
    const EVestingNotStarted: u64 = 3;
    /// Vested amount minus already-released amount is zero; nothing to claim.
    const ENoTokensToRelease: u64 = 4;
    /// Generic invalid input (also used to guard against double-initialization).
    const EInvalidAmount: u64 = 5;
    /// A vesting schedule already exists for the given beneficiary address.
    const EVestingAlreadyExists: u64 = 6;
    /// Object version does not match the current package version.
    const EWrongVersion: u64 = 7;
    /// The TreasuryCap has already been frozen via `lock_supply()`.
    const ESupplyAlreadyLocked: u64 = 8;
    /// Discretionary withdrawals are paused (cap is 0).
    const EAdminWithdrawalsPaused: u64 = 9;
    /// Withdrawal would push cumulative outflow past the per-window cap.
    const EAdminWithdrawalCapExceeded: u64 = 10;
    /// 2026-06-08 — move_between_pools received an invalid pool id
    /// (out of 1..6 range) or same source/dest.
    const EInvalidPool: u64 = 11;

    // ── Pool IDs for move_between_pools (2026-06-08) ─────────────────
    // u8 enum used by `move_between_pools` to identify source/dest.
    // Numeric ids (not strings) keep the call cheap; the dashboard's
    // command builder maps friendly names to numbers.
    const POOL_PRESALE:   u8 = 1;
    const POOL_TEAM:      u8 = 2;
    const POOL_LIQUIDITY: u8 = 3;
    const POOL_COMMUNITY: u8 = 4;
    const POOL_RESERVE:   u8 = 5;
    const POOL_FEE:       u8 = 6;

    // ─── Package version ────────────────────────────────────────────────────

    const VERSION: u64 = 2;

    // ─── Fee configuration ──────────────────────────────────────────────────

    /// Platform fee in basis points: 2.5% = 250/10000.
    const PLATFORM_FEE_BPS: u64 = 250;
    const BPS_DENOMINATOR: u64 = 10000;

    // ─── Withdrawal cap defaults ────────────────────────────────────────────
    //
    // Sized for "5-10× legitimate daily flow" — see docs/WITHDRAWAL_CAPS.md.
    // Caps are stored on the Treasury struct so super-admin can retune via
    // `set_admin_withdrawal_cap()` without a contract upgrade.

    /// Default rolling-window length: 24 hours.
    const DEFAULT_CAP_WINDOW_MS: u64 = 86_400_000;

    /// Default presale cap: 1k COVE / 24h.
    /// Rationale: presale_pool only moves during a one-time bulk load into `cove::presale`.
    /// Kept intentionally tight; super-admin raises it for that planned event then lowers back.
    const DEFAULT_PRESALE_CAP: u64 = 1_000_000_000_000;
    /// Default community cap: 100k COVE / 24h.
    /// Rationale: must accommodate chunkify payouts (~0.5 COVE × N jobs/day, well under)
    /// plus occasional ecosystem grants.
    const DEFAULT_COMMUNITY_CAP: u64 = 100_000_000_000_000;
    /// Default liquidity cap: 10k COVE / 24h.
    /// Rationale: LP adds are rare bursty events. Super-admin raises temporarily for
    /// genuine LP top-ups.
    const DEFAULT_LIQUIDITY_CAP: u64 = 10_000_000_000_000;
    /// Default reserve cap: 1k COVE / 24h.
    /// Rationale: reserve_pool is "break glass" only; legitimate use is rarer than presale.
    const DEFAULT_RESERVE_CAP: u64 = 1_000_000_000_000;
    /// Default fee cap: 50k COVE / 24h.
    /// Rationale: fee_pool accumulates from admin-bridged platform fees. Periodic sweeps
    /// to ops wallet shouldn't exceed this.
    const DEFAULT_FEE_CAP: u64 = 50_000_000_000_000;

    // ─── Structs ─────────────────────────────────────────────────────────────

    /// The central treasury. Exactly one instance exists, shared at creation time.
    /// Admin authorization delegated to `AdminRegistry`.
    public struct Treasury has key {
        id: UID,
        /// Checked against `VERSION` to enforce post-upgrade migration.
        version: u64,
        /// One-time minting cap. `Some` until `lock_supply()` freezes it.
        treasury_cap: Option<TreasuryCap<COVE_TOKEN>>,

        // ── Pools ──
        /// 2.5B COVE — drawn by `cove::presale` via `withdraw_presale`.
        presale_pool: Balance<COVE_TOKEN>,
        /// 2.5B COVE — drawn by `release_vested_tokens` as team schedules vest.
        team_pool: Balance<COVE_TOKEN>,
        /// 3.0B COVE — reserved for DEX/CEX liquidity provisioning at launch.
        liquidity_pool: Balance<COVE_TOKEN>,
        /// 1.0B COVE — node-operator rewards (chunkify payouts) and ecosystem grants.
        community_pool: Balance<COVE_TOKEN>,
        /// 1.0B COVE — strategic reserve.
        reserve_pool: Balance<COVE_TOKEN>,
        /// Long-term fee reserve, fed by `deposit_fees` from `pool_escrow.fee_pool`.
        /// 0 at init.
        fee_pool: Balance<COVE_TOKEN>,

        // ── Admin-withdrawal cap state ──
        /// Rolling-window length applied uniformly to every capped pool. 24h default.
        admin_window_ms: u64,

        /// Cap on `withdraw_presale` per window. 0 = paused.
        presale_cap: u64,
        presale_window_start: u64,
        presale_window_used: u64,

        /// Cap on `withdraw_community_rewards` per window.
        community_cap: u64,
        community_window_start: u64,
        community_window_used: u64,

        /// Cap on `withdraw_liquidity` per window.
        liquidity_cap: u64,
        liquidity_window_start: u64,
        liquidity_window_used: u64,

        /// Cap on `withdraw_reserve` per window.
        reserve_cap: u64,
        reserve_window_start: u64,
        reserve_window_used: u64,

        /// Cap on `withdraw_fees` per window.
        fee_cap: u64,
        fee_window_start: u64,
        fee_window_used: u64,

        /// Guard flag set to `true` once `initialize_distribution` completes.
        initialized: bool,
        /// Forward-compat: future treasury state (new pools, cap dimensions,
        /// staking sub-balances) attaches here as a compatible upgrade — never
        /// add struct fields post-publish. See contracts/UPGRADE.md.
        config: Bag,
    }

    /// Linear vesting schedule for a single beneficiary. Shared so anyone can
    /// trigger releases on the beneficiary's behalf.
    public struct VestingSchedule has key, store {
        id: UID,
        version: u64,
        beneficiary: address,
        total_amount: u64,
        released_amount: u64,
        start_time: u64,
        duration: u64,
        cliff_duration: u64,
        balance: Balance<COVE_TOKEN>,
        /// Forward-compat: a schedule lives for years, so future per-grant state
        /// (revocability, cliff acceleration, transfer-on-departure, metadata)
        /// attaches here as a compatible upgrade — never a struct-field add. The
        /// object is never deleted, so this bag is never destroyed.
        config: Bag,
    }

    /// Maps beneficiary → VestingSchedule ID. Enforces one-schedule-per-beneficiary.
    public struct VestingRegistry has key {
        id: UID,
        version: u64,
        schedules: Table<address, ID>,
        /// Forward-compat: future registry-level state attaches here (permanent
        /// singleton, bag never destroyed). See contracts/UPGRADE.md.
        config: Bag,
    }

    // ─── Events ──────────────────────────────────────────────────────────────

    public struct TreasuryInitialized has copy, drop {
        total_supply: u64,
        timestamp: u64,
    }

    public struct VestingScheduleCreated has copy, drop {
        beneficiary: address,
        schedule_id: ID,
        amount: u64,
        start_time: u64,
        duration: u64,
        cliff_duration: u64,
    }

    public struct VestingReleased has copy, drop {
        beneficiary: address,
        schedule_id: ID,
        released_now: u64,
        total_released: u64,
        timestamp: u64,
    }

    public struct PoolWithdrawn has copy, drop {
        /// "presale" / "community" / "liquidity" / "reserve" / "fee"
        pool: vector<u8>,
        amount: u64,
        recipient: address,
        timestamp: u64,
        /// Cumulative used in the current rolling window AFTER this withdrawal.
        window_used: u64,
    }

    /// Emitted whenever a super-admin retunes a per-pool cap.
    public struct AdminCapUpdated has copy, drop {
        /// "presale" / "community" / "liquidity" / "reserve" / "fee"
        pool: vector<u8>,
        new_cap: u64,
        new_window_ms: u64,
        timestamp: u64,
    }

    public struct FeesDeposited has copy, drop {
        amount: u64,
        depositor: address,
        timestamp: u64,
    }

    public struct SupplyLocked has copy, drop {
        timestamp: u64,
    }

    /// Emitted on `move_between_pools`. Lets off-chain monitors track
    /// admin-initiated internal transfers between pool Balances —
    /// distinct from PoolWithdrawn which represents outflows from the
    /// treasury entirely.
    public struct PoolsRebalanced has copy, drop {
        admin: address,
        from_pool: u8,
        to_pool: u8,
        amount: u64,
        timestamp_ms: u64,
    }

    // ─── Initialization ──────────────────────────────────────────────────────

    /// Create the shared Treasury + VestingRegistry. Called exactly once after
    /// `cove_token` is published, passing in the `TreasuryCap`.
    public fun create_treasury(
        treasury_cap: TreasuryCap<COVE_TOKEN>,
        ctx: &mut TxContext
    ) {
        let treasury = Treasury {
            id: object::new(ctx),
            version: VERSION,
            treasury_cap: option::some(treasury_cap),
            presale_pool: balance::zero(),
            team_pool: balance::zero(),
            liquidity_pool: balance::zero(),
            community_pool: balance::zero(),
            reserve_pool: balance::zero(),
            fee_pool: balance::zero(),

            // Caps initialized to defaults. window_start = 0 so the very first
            // withdrawal rolls into a fresh window starting at that tx's clock.
            admin_window_ms: DEFAULT_CAP_WINDOW_MS,
            presale_cap: DEFAULT_PRESALE_CAP,
            presale_window_start: 0,
            presale_window_used: 0,
            community_cap: DEFAULT_COMMUNITY_CAP,
            community_window_start: 0,
            community_window_used: 0,
            liquidity_cap: DEFAULT_LIQUIDITY_CAP,
            liquidity_window_start: 0,
            liquidity_window_used: 0,
            reserve_cap: DEFAULT_RESERVE_CAP,
            reserve_window_start: 0,
            reserve_window_used: 0,
            fee_cap: DEFAULT_FEE_CAP,
            fee_window_start: 0,
            fee_window_used: 0,

            initialized: false,
            config: bag::new(ctx),
        };

        let registry = VestingRegistry {
            id: object::new(ctx),
            version: VERSION,
            schedules: table::new(ctx),
            config: bag::new(ctx),
        };

        transfer::share_object(treasury);
        transfer::share_object(registry);
    }

    /// Mint the full 10B COVE supply and split into the five pools.
    /// Admin-only, one-shot.
    public fun initialize_distribution(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(!treasury.initialized, EInvalidAmount);
        assert!(option::is_some(&treasury.treasury_cap), ESupplyAlreadyLocked);

        let cap = option::borrow_mut(&mut treasury.treasury_cap);

        // 10B total allocation, 9 decimals.
        let presale_coins   = coin::mint(cap, 2_500_000_000_000_000_000, ctx); // 2.5B (25%)
        let team_coins      = coin::mint(cap, 2_500_000_000_000_000_000, ctx); // 2.5B (25%)
        let liquidity_coins = coin::mint(cap, 3_000_000_000_000_000_000, ctx); // 3.0B (30%)
        let community_coins = coin::mint(cap, 1_000_000_000_000_000_000, ctx); // 1.0B (10%)
        let reserve_coins   = coin::mint(cap, 1_000_000_000_000_000_000, ctx); // 1.0B (10%)

        balance::join(&mut treasury.presale_pool,   coin::into_balance(presale_coins));
        balance::join(&mut treasury.team_pool,      coin::into_balance(team_coins));
        balance::join(&mut treasury.liquidity_pool, coin::into_balance(liquidity_coins));
        balance::join(&mut treasury.community_pool, coin::into_balance(community_coins));
        balance::join(&mut treasury.reserve_pool,   coin::into_balance(reserve_coins));

        treasury.initialized = true;

        event::emit(TreasuryInitialized {
            total_supply: 10_000_000_000_000_000_000,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// Permanently freeze the TreasuryCap. No further minting possible.
    public fun lock_supply(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(treasury.initialized, EInvalidAmount);
        assert!(option::is_some(&treasury.treasury_cap), ESupplyAlreadyLocked);

        let cap = option::extract(&mut treasury.treasury_cap);
        transfer::public_freeze_object(cap);

        event::emit(SupplyLocked { timestamp: clock::timestamp_ms(clock) });
    }

    // ─── Withdrawal cap helpers (private) ────────────────────────────────────
    //
    // One shared helper that every capped withdraw function calls before
    // mutating its pool. Aborts if cap=0 (paused) or amount would exceed cap.
    // Otherwise rolls the window if expired and records the new usage.

    fun check_and_record_admin_withdrawal(
        cap: u64,
        window_ms: u64,
        window_start: &mut u64,
        window_used: &mut u64,
        amount: u64,
        clock: &Clock,
    ) {
        assert!(cap > 0, EAdminWithdrawalsPaused);
        let now = clock::timestamp_ms(clock);
        // AN-07 fix: guard against backwards clock movement. If the on-chain
        // Clock is ever observed earlier than the stored window_start (e.g.
        // a validator-coordinated clock anomaly), reset the window rather
        // than letting `now + window_ms` underflow and stall withdrawals.
        if (now < *window_start) {
            *window_start = now;
            *window_used = 0;
        };
        // Roll the window if it has expired (or if this is the first ever
        // withdrawal — window_start defaults to 0, so now >= 0 + window_ms
        // for any realistic clock).
        if (now >= *window_start + window_ms) {
            *window_start = now;
            *window_used = 0;
        };
        assert!(*window_used + amount <= cap, EAdminWithdrawalCapExceeded);
        *window_used = *window_used + amount;
    }

    // ─── Vesting ──────────────────────────────────────────────────────────────

    /// Create a vesting schedule for a beneficiary by splitting tokens from `team_pool`.
    /// One schedule per beneficiary; admin-only.
    public fun create_team_vesting(
        treasury: &mut Treasury,
        registry: &mut VestingRegistry,
        admin_reg: &AdminRegistry,
        beneficiary: address,
        amount: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(registry.version == VERSION, EWrongVersion);
        // SUPER-ADMIN only. This splits up to the whole team_pool (2.5B COVE) out
        // to an arbitrary beneficiary with an arbitrary (possibly instant) vest,
        // is NOT subject to the per-pool withdrawal caps, and has no clawback — so
        // it's a discretionary fund-moving action and belongs at the same tier as
        // move_between_pools / the cap setters / migrate, NOT plain is_admin. (A
        // regular admin must never be able to drain the team pool.)
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(amount > 0, EInvalidAmount);
        // vesting_duration is a per-call param now (was a baked 4yr const), so a
        // new grant can have any schedule without a republish. L3 invariant: a
        // cliff longer than the total vest is broken (it'd all unlock at once).
        assert!(vesting_duration > 0, EInvalidAmount);
        assert!(cliff_duration <= vesting_duration, EInvalidAmount);
        assert!(balance::value(&treasury.team_pool) >= amount, EInsufficientBalance);
        assert!(!table::contains(&registry.schedules, beneficiary), EVestingAlreadyExists);

        let vesting_balance = balance::split(&mut treasury.team_pool, amount);
        let now = clock::timestamp_ms(clock);

        let schedule = VestingSchedule {
            id: object::new(ctx),
            version: VERSION,
            beneficiary,
            total_amount: amount,
            released_amount: 0,
            start_time: now,
            duration: vesting_duration,
            cliff_duration,
            balance: vesting_balance,
            config: bag::new(ctx),
        };
        let schedule_id = object::id(&schedule);

        table::add(&mut registry.schedules, beneficiary, schedule_id);

        event::emit(VestingScheduleCreated {
            beneficiary,
            schedule_id,
            amount,
            start_time: now,
            duration: vesting_duration,
            cliff_duration,
        });

        transfer::share_object(schedule);
    }

    /// Release any newly-vested tokens to the beneficiary. Permissionless —
    /// anyone can call (typical pattern: a keeper or the beneficiary themselves).
    public fun release_vested_tokens(
        schedule: &mut VestingSchedule,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(schedule.version == VERSION, EWrongVersion);
        let now = clock::timestamp_ms(clock);
        assert!(now >= schedule.start_time + schedule.cliff_duration, EVestingNotStarted);

        let elapsed = now - schedule.start_time;
        // Total vested up to now.
        let vested_total = if (elapsed >= schedule.duration) {
            schedule.total_amount
        } else {
            // Linear vesting: vested = total * elapsed / duration.
            // u128 cast prevents intermediate overflow for big amounts.
            ((((schedule.total_amount as u128) * (elapsed as u128))
                / (schedule.duration as u128)) as u64)
        };
        assert!(vested_total > schedule.released_amount, ENoTokensToRelease);

        let to_release = vested_total - schedule.released_amount;
        schedule.released_amount = vested_total;

        let release_balance = balance::split(&mut schedule.balance, to_release);
        let release_coin = coin::from_balance(release_balance, ctx);
        transfer::public_transfer(release_coin, schedule.beneficiary);

        event::emit(VestingReleased {
            beneficiary: schedule.beneficiary,
            schedule_id: object::id(schedule),
            released_now: to_release,
            total_released: schedule.released_amount,
            timestamp: now,
        });
    }

    // ─── Capped admin withdrawals ────────────────────────────────────────────

    /// Withdraw from `presale_pool` (loads `cove::presale` at round init).
    /// Capped per `presale_cap`.
    public fun withdraw_presale(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&treasury.presale_pool) >= amount, EInsufficientBalance);

        check_and_record_admin_withdrawal(
            treasury.presale_cap,
            treasury.admin_window_ms,
            &mut treasury.presale_window_start,
            &mut treasury.presale_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut treasury.presale_pool, amount);

        event::emit(PoolWithdrawn {
            pool: b"presale",
            amount,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
            window_used: treasury.presale_window_used,
        });

        coin::from_balance(withdraw_balance, ctx)
    }

    /// Withdraw from `community_pool` (chunkify payouts, grants).
    /// Capped per `community_cap`.
    public fun withdraw_community_rewards(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(treasury.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: the orchestrator pays worker tier-bonuses + chunkify
        // rewards from the community pool. Still bounded by the per-pool 24h cap.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&treasury.community_pool) >= amount, EInsufficientBalance);

        check_and_record_admin_withdrawal(
            treasury.community_cap,
            treasury.admin_window_ms,
            &mut treasury.community_window_start,
            &mut treasury.community_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut treasury.community_pool, amount);

        event::emit(PoolWithdrawn {
            pool: b"community",
            amount,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
            window_used: treasury.community_window_used,
        });

        coin::from_balance(withdraw_balance, ctx)
    }

    /// Withdraw from `liquidity_pool` (DEX LP provisioning).
    /// Capped per `liquidity_cap`.
    public fun withdraw_liquidity(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&treasury.liquidity_pool) >= amount, EInsufficientBalance);

        check_and_record_admin_withdrawal(
            treasury.liquidity_cap,
            treasury.admin_window_ms,
            &mut treasury.liquidity_window_start,
            &mut treasury.liquidity_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut treasury.liquidity_pool, amount);

        event::emit(PoolWithdrawn {
            pool: b"liquidity",
            amount,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
            window_used: treasury.liquidity_window_used,
        });

        coin::from_balance(withdraw_balance, ctx)
    }

    /// Withdraw from `reserve_pool` ("break-glass" strategic reserve).
    /// Capped per `reserve_cap`.
    public fun withdraw_reserve(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&treasury.reserve_pool) >= amount, EInsufficientBalance);

        check_and_record_admin_withdrawal(
            treasury.reserve_cap,
            treasury.admin_window_ms,
            &mut treasury.reserve_window_start,
            &mut treasury.reserve_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut treasury.reserve_pool, amount);

        event::emit(PoolWithdrawn {
            pool: b"reserve",
            amount,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
            window_used: treasury.reserve_window_used,
        });

        coin::from_balance(withdraw_balance, ctx)
    }

    /// Withdraw from `fee_pool` (long-term accumulated fees).
    /// Capped per `fee_cap`.
    public fun withdraw_fees(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&treasury.fee_pool) >= amount, EInsufficientBalance);

        check_and_record_admin_withdrawal(
            treasury.fee_cap,
            treasury.admin_window_ms,
            &mut treasury.fee_window_start,
            &mut treasury.fee_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut treasury.fee_pool, amount);

        event::emit(PoolWithdrawn {
            pool: b"fee",
            amount,
            recipient: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
            window_used: treasury.fee_window_used,
        });

        coin::from_balance(withdraw_balance, ctx)
    }

    // ─── Cap administration (super-admin only) ───────────────────────────────
    //
    // Each setter takes a `new_cap` and optionally a `new_window_ms` (set to 0 to
    // keep the current window length). On every call, the per-pool window is reset
    // so the change takes effect immediately rather than waiting for the current
    // window to elapse.

    public fun set_presale_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        update_cap(treasury, admin_reg, ctx, new_window_ms);
        treasury.presale_cap = new_cap;
        treasury.presale_window_start = clock::timestamp_ms(clock);
        treasury.presale_window_used = 0;
        emit_cap_updated(b"presale", new_cap, treasury.admin_window_ms, clock);
    }

    public fun set_community_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        update_cap(treasury, admin_reg, ctx, new_window_ms);
        treasury.community_cap = new_cap;
        treasury.community_window_start = clock::timestamp_ms(clock);
        treasury.community_window_used = 0;
        emit_cap_updated(b"community", new_cap, treasury.admin_window_ms, clock);
    }

    public fun set_liquidity_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        update_cap(treasury, admin_reg, ctx, new_window_ms);
        treasury.liquidity_cap = new_cap;
        treasury.liquidity_window_start = clock::timestamp_ms(clock);
        treasury.liquidity_window_used = 0;
        emit_cap_updated(b"liquidity", new_cap, treasury.admin_window_ms, clock);
    }

    public fun set_reserve_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        update_cap(treasury, admin_reg, ctx, new_window_ms);
        treasury.reserve_cap = new_cap;
        treasury.reserve_window_start = clock::timestamp_ms(clock);
        treasury.reserve_window_used = 0;
        emit_cap_updated(b"reserve", new_cap, treasury.admin_window_ms, clock);
    }

    public fun set_fee_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        update_cap(treasury, admin_reg, ctx, new_window_ms);
        treasury.fee_cap = new_cap;
        treasury.fee_window_start = clock::timestamp_ms(clock);
        treasury.fee_window_used = 0;
        emit_cap_updated(b"fee", new_cap, treasury.admin_window_ms, clock);
    }

    /// 2026-06-08 — adjusts the rolling-window length shared by every
    /// per-pool cap. Currently each cap setter accepts a new_window_ms
    /// so this is redundant for them; the explicit setter is useful
    /// when you want to change the window WITHOUT touching any cap
    /// value (e.g. lengthen from 24h to 7d during a vacation).
    /// SUPER-ADMIN ONLY. Window > 0.
    public fun set_admin_window_ms(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(new_window_ms > 0, EInvalidAmount);
        treasury.admin_window_ms = new_window_ms;
        // Don't reset per-pool windows here — those are tied to their
        // caps. Operators can re-set any cap to also reset its window.
        emit_cap_updated(b"admin_window", new_window_ms, new_window_ms, clock);
    }

    /// 2026-06-08 — POST-INIT POOL REBALANCING. Move COVE from one
    /// pool's Balance to another's. SUPER-ADMIN ONLY. Bypasses the
    /// per-pool withdrawal caps (those are for OUTFLOWS, not internal
    /// transfers).
    ///
    /// Use cases:
    ///   - "I sized liquidity at 3B but need 4B" → move 1B from reserve
    ///     to liquidity
    ///   - "Community pool is empty + grants need to land" → move from
    ///     reserve to community
    ///   - Post-launch operational drift
    ///
    /// Pool IDs: 1=presale, 2=team, 3=liquidity, 4=community,
    /// 5=reserve, 6=fee. The frontend's command builder maps these to
    /// friendly names. The fee_pool is included for symmetry though
    /// it's typically only INCREASED via deposit_fees.
    public fun move_between_pools(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        from_pool: u8,
        to_pool: u8,
        amount: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(from_pool != to_pool, EInvalidPool);
        assert!(from_pool >= POOL_PRESALE && from_pool <= POOL_FEE, EInvalidPool);
        assert!(to_pool >= POOL_PRESALE && to_pool <= POOL_FEE, EInvalidPool);

        // Split from source. balance::split aborts ENotEnoughBalance
        // if the source pool doesn't have `amount` available — caller
        // sees the abort directly, no extra check needed.
        let coins = if (from_pool == POOL_PRESALE) {
            balance::split(&mut treasury.presale_pool, amount)
        } else if (from_pool == POOL_TEAM) {
            balance::split(&mut treasury.team_pool, amount)
        } else if (from_pool == POOL_LIQUIDITY) {
            balance::split(&mut treasury.liquidity_pool, amount)
        } else if (from_pool == POOL_COMMUNITY) {
            balance::split(&mut treasury.community_pool, amount)
        } else if (from_pool == POOL_RESERVE) {
            balance::split(&mut treasury.reserve_pool, amount)
        } else {
            balance::split(&mut treasury.fee_pool, amount)
        };

        // Join into destination.
        if (to_pool == POOL_PRESALE) {
            balance::join(&mut treasury.presale_pool, coins);
        } else if (to_pool == POOL_TEAM) {
            balance::join(&mut treasury.team_pool, coins);
        } else if (to_pool == POOL_LIQUIDITY) {
            balance::join(&mut treasury.liquidity_pool, coins);
        } else if (to_pool == POOL_COMMUNITY) {
            balance::join(&mut treasury.community_pool, coins);
        } else if (to_pool == POOL_RESERVE) {
            balance::join(&mut treasury.reserve_pool, coins);
        } else {
            balance::join(&mut treasury.fee_pool, coins);
        };

        event::emit(PoolsRebalanced {
            admin: tx_context::sender(ctx),
            from_pool,
            to_pool,
            amount,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    /// Shared preamble for all set_*_cap functions: version check, super-admin
    /// auth, optional window-length update. Pulled out so the per-pool setters
    /// stay tiny.
    fun update_cap(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        ctx: &TxContext,
        new_window_ms: u64,
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        // Cap mutations are super-admin-only — a regular admin can still execute
        // discretionary withdrawals (subject to caps), but cannot loosen the caps.
        assert!(
            tx_context::sender(ctx) == admin_registry::super_admin(admin_reg),
            ENotSuperAdmin
        );
        if (new_window_ms > 0) {
            treasury.admin_window_ms = new_window_ms;
        };
    }

    fun emit_cap_updated(
        pool: vector<u8>,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
    ) {
        event::emit(AdminCapUpdated {
            pool,
            new_cap,
            new_window_ms,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // ─── Pool inflows (NOT capped — admin INFLOWS are safe) ──────────────────

    /// Add COVE to the community pool. Used during major rebalances (e.g. moving
    /// freed allocations after a sale design change). Admin only. Not capped —
    /// inflows can't drain.
    public fun add_to_community_pool(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        deposit: Coin<COVE_TOKEN>,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        balance::join(&mut treasury.community_pool, coin::into_balance(deposit));
    }

    /// Add COVE to the liquidity pool. Same shape as `add_to_community_pool`.
    public fun add_to_liquidity_pool(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        deposit: Coin<COVE_TOKEN>,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        balance::join(&mut treasury.liquidity_pool, coin::into_balance(deposit));
    }

    /// Deposit COVE into the treasury fee pool. Permissionless inflow; intended
    /// for the admin bridging fees from `pool_escrow.fee_pool`. Not capped —
    /// inflows can't drain. Capped on the way OUT via `withdraw_fees`.
    public fun deposit_fees(
        treasury: &mut Treasury,
        fee_coin: Coin<COVE_TOKEN>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(treasury.version == VERSION, EWrongVersion);
        let amount = coin::value(&fee_coin);
        assert!(amount > 0, EInvalidAmount);

        balance::join(&mut treasury.fee_pool, coin::into_balance(fee_coin));

        event::emit(FeesDeposited {
            amount,
            depositor: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // ─── Migration ───────────────────────────────────────────────────────────

    /// Migrate the Treasury to the current package version after an upgrade.
    public fun migrate_treasury(
        treasury: &mut Treasury,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(treasury.version < VERSION, EWrongVersion);
        treasury.version = VERSION;
    }

    public fun migrate_vesting_registry(
        registry: &mut VestingRegistry,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(registry.version < VERSION, EWrongVersion);
        registry.version = VERSION;
    }

    public fun migrate_vesting_schedule(
        schedule: &mut VestingSchedule,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(schedule.version < VERSION, EWrongVersion);
        schedule.version = VERSION;
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    public fun calculate_platform_fee(amount: u64): u64 {
        // u128 intermediate to prevent overflow on big amounts.
        ((((amount as u128) * (PLATFORM_FEE_BPS as u128)) / (BPS_DENOMINATOR as u128)) as u64)
    }

    // ─── View functions (no version checks; pure reads) ─────────────────────

    public fun presale_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.presale_pool)
    }

    public fun team_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.team_pool)
    }

    public fun liquidity_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.liquidity_pool)
    }

    public fun community_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.community_pool)
    }

    public fun reserve_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.reserve_pool)
    }

    public fun fee_pool_balance(treasury: &Treasury): u64 {
        balance::value(&treasury.fee_pool)
    }

    public fun is_initialized(treasury: &Treasury): bool {
        treasury.initialized
    }

    public fun is_supply_locked(treasury: &Treasury): bool {
        option::is_none(&treasury.treasury_cap)
    }

    public fun platform_fee_bps(): u64 {
        PLATFORM_FEE_BPS
    }

    public fun admin_window_ms(treasury: &Treasury): u64 {
        treasury.admin_window_ms
    }

    /// Returns `(cap, window_start_ms, window_used)` for a given pool name.
    /// Pool keys: "presale", "community", "liquidity", "reserve", "fee".
    /// Returns (0, 0, 0) for unknown keys — caller should check before using.
    public fun cap_status(treasury: &Treasury, pool: vector<u8>): (u64, u64, u64) {
        if (pool == b"presale") {
            (treasury.presale_cap, treasury.presale_window_start, treasury.presale_window_used)
        } else if (pool == b"community") {
            (treasury.community_cap, treasury.community_window_start, treasury.community_window_used)
        } else if (pool == b"liquidity") {
            (treasury.liquidity_cap, treasury.liquidity_window_start, treasury.liquidity_window_used)
        } else if (pool == b"reserve") {
            (treasury.reserve_cap, treasury.reserve_window_start, treasury.reserve_window_used)
        } else if (pool == b"fee") {
            (treasury.fee_cap, treasury.fee_window_start, treasury.fee_window_used)
        } else {
            (0, 0, 0)
        }
    }

    public fun vesting_schedule_for(registry: &VestingRegistry, beneficiary: address): Option<ID> {
        if (table::contains(&registry.schedules, beneficiary)) {
            option::some(*table::borrow(&registry.schedules, beneficiary))
        } else {
            option::none()
        }
    }

    public fun vesting_schedule_total(schedule: &VestingSchedule): u64 {
        schedule.total_amount
    }

    public fun vesting_schedule_released(schedule: &VestingSchedule): u64 {
        schedule.released_amount
    }

    public fun vesting_schedule_beneficiary(schedule: &VestingSchedule): address {
        schedule.beneficiary
    }

    // ─── Test-only helpers ───────────────────────────────────────────────────

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        // Tests call this in place of the COIN_TYPE's create_currency dance.
        // It constructs a Treasury + VestingRegistry with zero balances and the
        // default caps. The TreasuryCap is left as None — tests that need to
        // mint must use cove_token's own test helpers to obtain one and call
        // create_treasury(cap, ctx) directly.
        let treasury = Treasury {
            id: object::new(ctx),
            version: VERSION,
            treasury_cap: option::none(),
            presale_pool: balance::zero(),
            team_pool: balance::zero(),
            liquidity_pool: balance::zero(),
            community_pool: balance::zero(),
            reserve_pool: balance::zero(),
            fee_pool: balance::zero(),

            admin_window_ms: DEFAULT_CAP_WINDOW_MS,
            presale_cap: DEFAULT_PRESALE_CAP,
            presale_window_start: 0,
            presale_window_used: 0,
            community_cap: DEFAULT_COMMUNITY_CAP,
            community_window_start: 0,
            community_window_used: 0,
            liquidity_cap: DEFAULT_LIQUIDITY_CAP,
            liquidity_window_start: 0,
            liquidity_window_used: 0,
            reserve_cap: DEFAULT_RESERVE_CAP,
            reserve_window_start: 0,
            reserve_window_used: 0,
            fee_cap: DEFAULT_FEE_CAP,
            fee_window_start: 0,
            fee_window_used: 0,

            initialized: false,
            config: bag::new(ctx),
        };
        let registry = VestingRegistry {
            id: object::new(ctx),
            version: VERSION,
            schedules: table::new(ctx),
            config: bag::new(ctx),
        };
        transfer::share_object(treasury);
        transfer::share_object(registry);
    }
}
