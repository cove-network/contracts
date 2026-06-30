/// Pool Escrow - Pooled payment escrow for the Cove decentralized transcoding network
///
/// This module replaces per-job escrow with a pooled model, dramatically reducing
/// on-chain transaction overhead. Instead of requiring ~4 transactions per job
/// (create escrow, fund, release, close), the pooled model requires only ~1 transaction
/// per settlement batch, regardless of how many jobs were completed.
///
/// ## How it works
///
/// 1. **Deposit**: Clients deposit COVE tokens into a shared `EscrowPool`. Their
///    balances are tracked in a `Table<address, u64>` ledger, while the actual tokens
///    are held in a single `Balance<COVE_TOKEN>`.
///
/// 2. **Off-chain tracking**: The orchestrator tracks job submissions, completions,
///    and costs off-chain. No on-chain transactions occur during job execution.
///
/// 3. **Batch settlement** (~every 24 hours): The orchestrator settles all accumulated
///    payments in a single batch:
///
///    ```
///    start_batch_settlement()          -- Lock the pool, create a SettlementBatch
///      -> pay_worker()           x M   -- Pay each worker (minus the platform fee)
///    finalize_batch_settlement()       -- Unlock the pool, record stats
///    ```
///
///    If something goes wrong mid-settlement, `abort_settlement()` rolls back the
///    cycle counter and destroys the batch object so the pool can be used again.
///
/// ## Settlement state machine
///
/// The `settlement_in_progress` flag acts as a mutex. While true:
/// - Client withdrawals are blocked (prevents race conditions with balance deductions)
/// - No other settlement can start
/// - Only `finalize_batch_settlement()` or `abort_settlement()` can clear the flag
///
/// ## Platform fee architecture
///
/// A 2.5% fee (250 basis points) is deducted from each worker payment during settlement.
/// Fees accumulate in the pool_escrow's own `fee_pool` and can be withdrawn by the admin
/// at any time via `withdraw_fees()`.
///
/// **Design decision**: pool_escrow and treasury maintain **separate** fee pools:
///
/// - **pool_escrow.fee_pool** – collects fees in real time during batch settlements.
///   This is the operational fee pool that accumulates revenue from each `pay_worker()`.
///   The admin withdraws from here to fund operations or redistribute.
///
/// - **treasury.fee_pool** – long-term reserve for protocol fee revenue. Receives
///   deposits via `treasury::deposit_fees()` (permissionless). This pool is suitable
///   for on-chain governance, buyback-and-burn programs, or staking rewards.
///
/// The pools are kept separate to decouple operational settlement (high frequency,
/// admin-managed) from treasury governance (low frequency, potentially DAO-managed).
/// The admin can bridge fees from pool_escrow → treasury by withdrawing from one
/// and depositing into the other as needed.
///
/// ## Upgrade safety
///
/// Both `EscrowPool` and `SettlementBatch` carry a `version` field. All mutating
/// functions assert `version == VERSION`. After a package upgrade, the admin calls
/// `migrate()` to bump the pool's version, gating access until migration is complete.
module cove::pool_escrow {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::bag::{Self, Bag};
    use sui::event;
    use cove::cove_token::COVE_TOKEN;
    use cove::admin_registry::{Self, AdminRegistry};

    // =========================================================================
    // Error codes
    // =========================================================================

    const ENotAdmin: u64 = 0;
    const EInsufficientBalance: u64 = 1;
    const EInsufficientPoolBalance: u64 = 2;
    /// A settlement is already running; cannot start another or withdraw funds.
    const ESettlementInProgress: u64 = 3;
    /// No settlement is running; cannot deduct, pay, finalize, or abort.
    const ENoSettlementInProgress: u64 = 4;
    const EInvalidAmount: u64 = 5;
    /// Client tried to withdraw more than their tracked balance.
    const EWithdrawExceedsAvailable: u64 = 6;
    /// Object version does not match the current package version. Call `migrate()` first.
    const EWrongVersion: u64 = 7;
    /// Caller is not the super-admin (required for cap mutations).
    const ENotSuperAdmin: u64 = 8;
    /// Discretionary fee withdrawals are paused (cap is 0).
    const EAdminWithdrawalsPaused: u64 = 9;
    /// Fee withdrawal would push cumulative outflow past the per-window cap.
    const EAdminWithdrawalCapExceeded: u64 = 10;
    /// set_platform_fee_bps was given a value above MAX_FEE_BPS.
    const EFeeTooHigh: u64 = 11;
    /// pay_worker payout would push the rolling window past the payout cap.
    const EPayoutCapExceeded: u64 = 13;

    // =========================================================================
    // Constants
    // =========================================================================

    /// Package version. Bumped when shared-object layout changes.
    const VERSION: u64 = 3;

    /// Default platform fee in basis points (1 bp = 0.01%). 250 = 2.5%. This is
    /// only the genesis SEED — the live rate is the tunable `platform_fee_bps`
    /// field on EscrowPool, changed via `set_platform_fee_bps` (super-admin).
    const DEFAULT_PLATFORM_FEE_BPS: u64 = 250;
    const BPS_DENOMINATOR: u64 = 10000;
    /// Hard ceiling on the tunable platform fee. A fee above this (and certainly
    /// a fee > BPS_DENOMINATOR, which would underflow `gross - fee` and abort
    /// every settlement) is rejected by `set_platform_fee_bps`. 500 bps = 5%.
    const MAX_FEE_BPS: u64 = 500;

    /// Maximum u64 value, used for saturating arithmetic on lifetime counters.
    const MAX_U64: u64 = 18_446_744_073_709_551_615;

    // ─── Cap defaults + bounds ──────────────────────────────────────────────

    /// 24-hour rolling window.
    const DEFAULT_CAP_WINDOW_MS: u64 = 86_400_000;
    /// 100k COVE / 24h default for `withdraw_fees`.
    const DEFAULT_FEE_CAP: u64 = 100_000_000_000_000;
    /// Settlement payout cap default. 0 = DISABLED (unlimited). Operators ENABLE
    /// it before mainnet via `set_payout_cap`, sized to ~2-3x peak daily payout
    /// volume — it bounds how much COVE can leave the pool to workers per window,
    /// so a compromised settlement key can't drain the whole pool at once. We
    /// default OFF (not 0=paused) because pausing worker payouts is catastrophic.
    const DEFAULT_PAYOUT_CAP: u64 = 0;

    // =========================================================================
    // Core structs
    // =========================================================================

    /// The shared escrow pool that holds all client COVE deposits.
    ///
    /// Created once at module init and shared. All client funds live in `pool`,
    /// with individual balances tracked in the `client_balances` ledger.
    /// Platform fees accumulate separately in `fee_pool`.
    ///
    /// The `settlement_in_progress` flag acts as a mutex: when true, client
    /// withdrawals are blocked and no new settlement can start.
    public struct EscrowPool has key {
        id: UID,
        /// Object version for upgrade safety; must equal `VERSION` on all mutations.
        version: u64,
        /// Aggregate balance of all client deposits (minus withdrawals and payouts).
        pool: Balance<COVE_TOKEN>,
        /// Per-client balance ledger. Maps client address -> available COVE amount.
        /// Updated on deposit and withdraw. (Off-chain Postgres is authoritative
        /// for per-job usage; the chain only tracks deposits/withdrawals.)
        client_balances: Table<address, u64>,
        /// Platform fees withheld from worker payments, pending admin withdrawal.
        fee_pool: Balance<COVE_TOKEN>,
        /// Monotonically increasing settlement cycle counter.
        /// Incremented on start_batch_settlement, decremented on abort_settlement.
        current_cycle: u64,
        /// Timestamp (ms) of the most recent finalized settlement.
        last_settlement: u64,
        /// True while a settlement batch is being processed. Acts as a mutex
        /// to prevent client withdrawals and concurrent settlements.
        settlement_in_progress: bool,
        // --- Lifetime statistics ---
        /// Total COVE deposited by all clients, all-time.
        total_deposited: u64,
        /// Total COVE withdrawn by clients, all-time.
        total_withdrawn: u64,
        /// Total net COVE paid to workers (after fees), all-time.
        total_paid_workers: u64,
        /// Total platform fees collected, all-time.
        total_fees_collected: u64,

        // --- Admin-withdrawal cap state ---
        //
        // Caps `withdraw_fees` only. Settlement payouts (`pay_worker`) are NOT
        // capped — they're bounded by chunk.amount in the settlement batch,
        // not by admin discretion. Cap=0 = paused. Super-admin can retune
        // via `set_fee_cap`.

        /// Rolling-window length for the cap. 24h default.
        fee_window_ms: u64,
        /// Max fee outflow per window.
        fee_cap: u64,
        /// Timestamp (ms) when the current window opened.
        fee_window_start: u64,
        /// Cumulative `withdraw_fees` outflow in the current window.
        fee_window_used: u64,

        // --- Settlement payout cap state (L1) ---
        //
        // Bounds COVE leaving the pool to workers per rolling window. 0 = the
        // cap is DISABLED (unlimited). >0 = enforced. Super-admin tunes via
        // `set_payout_cap`. Distinct from fee_cap so the two flows are bounded
        // independently.
        /// Max worker payout per window. 0 = disabled.
        payout_cap: u64,
        /// Rolling-window length for the payout cap.
        payout_window_ms: u64,
        /// Timestamp (ms) when the current payout window opened.
        payout_window_start: u64,
        /// Cumulative gross payout in the current window.
        payout_window_used: u64,

        /// Live platform fee in basis points, applied by `pay_worker`. Tunable
        /// via `set_platform_fee_bps` (super-admin, ≤ MAX_FEE_BPS). Seeded from
        /// DEFAULT_PLATFORM_FEE_BPS at genesis.
        platform_fee_bps: u64,

        /// Forward-compat: future pool-level state (new caps, fee tiers, flags)
        /// attaches here as a compatible upgrade — NEVER add struct fields after
        /// publish. Keyed by a `vector<u8>` name. See contracts/UPGRADE.md.
        config: Bag,
    }

    /// A per-cycle settlement batch object, created at the start of each settlement
    /// and used to accumulate stats as workers are paid.
    ///
    /// This is a separate shared object so the orchestrator can pass it by mutable
    /// reference alongside the pool during pay_worker calls. It is marked `finalized`
    /// on successful completion, or destructured and deleted on abort.
    public struct SettlementBatch has key {
        id: UID,
        /// Object version for upgrade safety.
        version: u64,
        /// Which settlement cycle this batch belongs to.
        cycle: u64,
        /// Timestamp (ms) when start_batch_settlement was called.
        started_at: u64,
        /// Running total of net COVE paid to workers in this batch.
        total_paid: u64,
        /// Running total of platform fees collected in this batch.
        fees_collected: u64,
        /// Number of distinct workers paid in this batch.
        workers_paid: u64,
        /// Set to true by finalize_batch_settlement; prevents further pay_worker calls.
        finalized: bool,
        /// Forward-compat: future per-batch state attaches here (created empty,
        /// destroyed empty in finalize/abort). NEVER add struct fields.
        config: Bag,
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// Emitted when a client deposits COVE into the pool.
    public struct ClientDeposit has copy, drop {
        client: address,
        amount: u64,
        new_balance: u64,
        timestamp: u64,
    }

    /// Emitted when a client withdraws COVE from the pool.
    public struct ClientWithdraw has copy, drop {
        client: address,
        amount: u64,
        remaining_balance: u64,
        timestamp: u64,
    }

    /// Emitted when a new settlement batch begins.
    public struct SettlementStarted has copy, drop {
        cycle: u64,
        timestamp: u64,
    }

    /// Emitted for each worker payment during settlement.
    public struct WorkerPaid has copy, drop {
        cycle: u64,
        worker: address,
        /// Net amount after platform fee deduction.
        amount: u64,
    }

    /// Emitted when a settlement batch is finalized successfully.
    public struct SettlementFinalized has copy, drop {
        cycle: u64,
        total_paid: u64,
        fees_collected: u64,
        workers_paid: u64,
        timestamp: u64,
    }

    /// Emitted when a settlement batch is aborted. Preserves on-chain audit trail
    /// of any partial payments that were already made before the abort.
    public struct SettlementAborted has copy, drop {
        cycle: u64,
        /// Net COVE paid to workers before the abort (these payments are NOT reversed).
        total_paid: u64,
        /// Platform fees collected before the abort.
        fees_collected: u64,
        /// Number of workers paid before the abort.
        workers_paid: u64,
    }

    /// Emitted when the admin withdraws accumulated platform fees.
    public struct FeesWithdrawn has copy, drop {
        amount: u64,
        recipient: address,
        timestamp: u64,
    }

    /// Emitted when the super-admin retunes the fee-withdrawal cap.
    public struct FeeCapUpdated has copy, drop {
        new_cap: u64,
        new_window_ms: u64,
        timestamp: u64,
    }

    /// Emitted when the super-admin retunes the settlement payout cap.
    public struct PayoutCapUpdated has copy, drop {
        new_cap: u64,
        new_window_ms: u64,
        timestamp: u64,
    }

    /// Emitted when the super-admin changes the live platform fee.
    public struct PlatformFeeUpdated has copy, drop {
        old_bps: u64,
        new_bps: u64,
        timestamp: u64,
    }


    // =========================================================================
    // Initialization
    // =========================================================================

    /// Creates the shared `EscrowPool` at module publish time.
    fun init(ctx: &mut TxContext) {
        let pool = EscrowPool {
            id: object::new(ctx),
            version: VERSION,
            pool: balance::zero(),
            client_balances: table::new(ctx),
            fee_pool: balance::zero(),
            current_cycle: 0,
            last_settlement: 0,
            settlement_in_progress: false,
            total_deposited: 0,
            total_withdrawn: 0,
            total_paid_workers: 0,
            total_fees_collected: 0,

            // Caps default to a 100k COVE / 24h window. window_start = 0 so the
            // first `withdraw_fees` rolls into a fresh window starting at that
            // tx's clock value.
            fee_window_ms: DEFAULT_CAP_WINDOW_MS,
            fee_cap: DEFAULT_FEE_CAP,
            fee_window_start: 0,
            fee_window_used: 0,

            // Payout cap defaults to DISABLED (0) — enable via set_payout_cap
            // before mainnet, sized to volume.
            payout_cap: DEFAULT_PAYOUT_CAP,
            payout_window_ms: DEFAULT_CAP_WINDOW_MS,
            payout_window_start: 0,
            payout_window_used: 0,

            platform_fee_bps: DEFAULT_PLATFORM_FEE_BPS,
            config: bag::new(ctx),
        };

        transfer::share_object(pool);
    }

    // ─── Withdrawal cap helper (private) ────────────────────────────────────
    //
    // Called by every capped withdraw before mutating its balance. Aborts on
    // cap=0 (paused) or cap exceeded. Rolls the window if expired.

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
        // AN-07 fix: backwards-clock guard. Reset window if Clock is
        // observed earlier than the stored window_start.
        if (now < *window_start) {
            *window_start = now;
            *window_used = 0;
        };
        if (now >= *window_start + window_ms) {
            *window_start = now;
            *window_used = 0;
        };
        assert!(*window_used + amount <= cap, EAdminWithdrawalCapExceeded);
        *window_used = *window_used + amount;
    }

    // ─── Settlement payout-cap helper (private) ─────────────────────────────
    //
    // Called by pay_worker ONLY when payout_cap > 0 (cap==0 = disabled). Rolls
    // the window and enforces the per-window ceiling. Distinct error from the
    // admin-withdrawal cap so monitoring can tell a payout-cap hit (abnormal,
    // possible key compromise) from a fee-withdrawal-cap hit.
    fun check_and_record_payout(
        cap: u64,
        window_ms: u64,
        window_start: &mut u64,
        window_used: &mut u64,
        amount: u64,
        clock: &Clock,
    ) {
        let now = clock::timestamp_ms(clock);
        if (now < *window_start) {
            *window_start = now;
            *window_used = 0;
        };
        if (now >= *window_start + window_ms) {
            *window_start = now;
            *window_used = 0;
        };
        assert!(*window_used + amount <= cap, EPayoutCapExceeded);
        *window_used = *window_used + amount;
    }

    // =========================================================================
    // Client operations
    // =========================================================================

    /// Deposit COVE tokens into the escrow pool.
    ///
    /// This is the primary client-initiated on-chain action. The deposited amount
    /// is added to the caller's ledger balance and the tokens are merged into the
    /// shared pool. Can be called at any time, even during an active settlement.
    ///
    /// **Caller**: Any address holding COVE tokens.
    /// **Preconditions**: `amount > 0`, pool version matches.
    /// **Side effects**: Emits `ClientDeposit`.
    public fun deposit(
        pool: &mut EscrowPool,
        payment: Coin<COVE_TOKEN>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        let client = tx_context::sender(ctx);
        let amount = coin::value(&payment);
        assert!(amount > 0, EInvalidAmount);

        // Merge the coin into the shared pool balance
        balance::join(&mut pool.pool, coin::into_balance(payment));

        // Credit the client's ledger entry (create if first deposit)
        if (table::contains(&pool.client_balances, client)) {
            let balance = table::borrow_mut(&mut pool.client_balances, client);
            *balance = *balance + amount;
        } else {
            table::add(&mut pool.client_balances, client, amount);
        };

        if (pool.total_deposited <= MAX_U64 - amount) {
            pool.total_deposited = pool.total_deposited + amount;
        } else {
            pool.total_deposited = MAX_U64;
        };

        let new_balance = *table::borrow(&pool.client_balances, client);

        event::emit(ClientDeposit {
            client,
            amount,
            new_balance,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// Withdraw unused COVE from the pool back to the caller's wallet.
    ///
    /// Blocked while a settlement is in progress to prevent race conditions with
    /// the pool accounting that settlement mutates.
    ///
    /// **Caller**: Any client with a positive ledger balance.
    /// **Preconditions**: No active settlement, sufficient balance, pool version matches.
    /// **Side effects**: Transfers a `Coin<COVE_TOKEN>` to the caller. Emits `ClientWithdraw`.
    ///
    /// Note: The `self_transfer` lint is suppressed because transferring to `tx_context::sender`
    /// is the correct behavior for a withdrawal function.
    #[allow(lint(self_transfer))]
    public fun withdraw(
        pool: &mut EscrowPool,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        // Block withdrawals during settlement to avoid races with payout accounting
        assert!(!pool.settlement_in_progress, ESettlementInProgress);

        let client = tx_context::sender(ctx);
        assert!(table::contains(&pool.client_balances, client), EInsufficientBalance);

        let balance = table::borrow_mut(&mut pool.client_balances, client);
        assert!(*balance >= amount, EWithdrawExceedsAvailable);

        *balance = *balance - amount;
        let remaining = *balance;

        // Split the requested amount from the pool and send it to the client
        let withdraw_balance = balance::split(&mut pool.pool, amount);
        let withdraw_coin = coin::from_balance(withdraw_balance, ctx);
        transfer::public_transfer(withdraw_coin, client);

        if (pool.total_withdrawn <= MAX_U64 - amount) {
            pool.total_withdrawn = pool.total_withdrawn + amount;
        } else {
            pool.total_withdrawn = MAX_U64;
        };

        event::emit(ClientWithdraw {
            client,
            amount,
            remaining_balance: remaining,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // =========================================================================
    // Settlement operations (admin/orchestrator only)
    // =========================================================================
    //
    // Settlement lifecycle:
    //   1. start_batch_settlement()       -- lock the pool, create batch
    //   2. pay_worker() x M               -- pay workers, withhold platform fees
    //   3. finalize_batch_settlement()    -- unlock the pool, record stats
    //
    // If anything fails mid-flight, call abort_settlement() to roll back.

    /// Begin a new settlement batch.
    ///
    /// Locks the pool (sets `settlement_in_progress = true`), increments the cycle
    /// counter, and returns a fresh `SettlementBatch` object to track batch stats.
    /// Only one settlement can be active at a time.
    ///
    /// **Caller**: Admin only.
    /// **Preconditions**: No active settlement, pool version matches.
    /// **Side effects**: Emits `SettlementStarted`. Returns a `SettlementBatch` (shared object).
    public fun start_batch_settlement(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ): SettlementBatch {
        assert!(pool.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: the orchestrator runs settlement every cycle.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(!pool.settlement_in_progress, ESettlementInProgress);

        let timestamp = clock::timestamp_ms(clock);
        pool.settlement_in_progress = true;
        pool.current_cycle = pool.current_cycle + 1;

        event::emit(SettlementStarted {
            cycle: pool.current_cycle,
            timestamp,
        });

        SettlementBatch {
            id: object::new(ctx),
            version: VERSION,
            cycle: pool.current_cycle,
            started_at: timestamp,
            total_paid: 0,
            fees_collected: 0,
            workers_paid: 0,
            finalized: false,
            config: bag::new(ctx),
        }
    }

    /// Pay a worker from the pool, withholding the platform fee.
    ///
    /// Splits `gross_amount` into a 2.5% platform fee (routed to `fee_pool`) and
    /// a net payment (transferred directly to the worker's address as a Coin).
    /// Updates the batch's running totals.
    ///
    /// **Caller**: Admin only, during an active settlement, before finalization.
    /// **Preconditions**: Settlement in progress, batch not finalized, pool has
    ///   sufficient balance for `gross_amount`, pool version matches.
    /// **Side effects**: Transfers `Coin<COVE_TOKEN>` to `worker`. Emits `WorkerPaid`.
    public fun pay_worker(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        batch: &mut SettlementBatch,
        worker: address,
        gross_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(batch.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: settlement pays each worker their earned amount.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(pool.settlement_in_progress, ENoSettlementInProgress);
        assert!(!batch.finalized, ESettlementInProgress);

        if (gross_amount == 0) {
            return
        };

        // Platform fee from the TUNABLE rate (super-admin-set, ≤ MAX_FEE_BPS).
        // u128 intermediate prevents overflow for large payments.
        let fee = ((((gross_amount as u128) * (pool.platform_fee_bps as u128)) / (BPS_DENOMINATOR as u128)) as u64);
        let net_payment = gross_amount - fee;

        assert!(balance::value(&pool.pool) >= gross_amount, EInsufficientPoolBalance);

        // ── L1 protection: rolling per-window payout cap (when enabled) ──────
        //     Bounds total COVE leaving the pool to workers per window, so a
        //     stolen settlement key can't drain the whole pool in one window.
        //     0 = disabled.
        if (pool.payout_cap > 0) {
            check_and_record_payout(
                pool.payout_cap,
                pool.payout_window_ms,
                &mut pool.payout_window_start,
                &mut pool.payout_window_used,
                gross_amount,
                clock,
            );
        };

        // Route fee to the platform fee pool
        let fee_balance = balance::split(&mut pool.pool, fee);
        balance::join(&mut pool.fee_pool, fee_balance);

        // Send net payment to the worker
        let payment_balance = balance::split(&mut pool.pool, net_payment);
        let payment_coin = coin::from_balance(payment_balance, ctx);
        transfer::public_transfer(payment_coin, worker);

        // Update batch running totals (saturating add — mirrors the lifetime
        // counter pattern at line 615. Bounded by pool.pool in practice but
        // hardening keeps the per-batch counter from wedging a cycle if a
        // future change widens the per-batch loop).
        if (batch.total_paid <= MAX_U64 - net_payment) {
            batch.total_paid = batch.total_paid + net_payment;
        } else {
            batch.total_paid = MAX_U64;
        };
        if (batch.fees_collected <= MAX_U64 - fee) {
            batch.fees_collected = batch.fees_collected + fee;
        } else {
            batch.fees_collected = MAX_U64;
        };
        if (batch.workers_paid < MAX_U64) {
            batch.workers_paid = batch.workers_paid + 1;
        };

        event::emit(WorkerPaid {
            cycle: batch.cycle,
            worker,
            amount: net_payment,
        });
    }

    /// Finalize the current settlement batch.
    ///
    /// Consumes and deletes the `SettlementBatch` object, unlocks the pool for
    /// client withdrawals, and rolls up the batch totals into the pool's
    /// lifetime counters.
    ///
    /// The batch is taken by value (not `&mut`) because `SettlementBatch` has
    /// only the `key` ability — it cannot be dropped or transferred. If it were
    /// taken by reference, the unhandled object would cause the PTB to abort.
    ///
    /// **Caller**: Admin only, during an active settlement.
    /// **Preconditions**: Settlement in progress, batch not already finalized, pool version matches.
    /// **Side effects**: Unlocks the pool (`settlement_in_progress = false`).
    ///   Updates `last_settlement`, `total_paid_workers`, `total_fees_collected`.
    ///   Emits `SettlementFinalized`. Deletes the batch object.
    public fun finalize_batch_settlement(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        batch: SettlementBatch,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(batch.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: settlement closes the batch and clears the lock.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(pool.settlement_in_progress, ENoSettlementInProgress);
        assert!(!batch.finalized, ESettlementInProgress);

        let timestamp = clock::timestamp_ms(clock);

        pool.settlement_in_progress = false;
        pool.last_settlement = timestamp;

        // Roll batch stats into lifetime counters (saturating add)
        if (pool.total_paid_workers <= MAX_U64 - batch.total_paid) {
            pool.total_paid_workers = pool.total_paid_workers + batch.total_paid;
        } else {
            pool.total_paid_workers = MAX_U64;
        };
        if (pool.total_fees_collected <= MAX_U64 - batch.fees_collected) {
            pool.total_fees_collected = pool.total_fees_collected + batch.fees_collected;
        } else {
            pool.total_fees_collected = MAX_U64;
        };

        event::emit(SettlementFinalized {
            cycle: batch.cycle,
            total_paid: batch.total_paid,
            fees_collected: batch.fees_collected,
            workers_paid: batch.workers_paid,
            timestamp,
        });

        // Destructure and delete the batch object
        let SettlementBatch {
            id,
            version: _,
            cycle: _,
            started_at: _,
            total_paid: _,
            fees_collected: _,
            workers_paid: _,
            finalized: _,
            config,
        } = batch;
        bag::destroy_empty(config);
        object::delete(id);
    }

    /// Abort the current settlement, rolling back the cycle counter.
    ///
    /// Use this if the orchestrator encounters an error mid-settlement (e.g., an
    /// unexpected balance shortfall after some workers have already been paid).
    /// Unlocks the pool and destroys the `SettlementBatch` object.
    ///
    /// Note: This decrements `current_cycle` because the batch never completed,
    /// so the next successful settlement will reuse this cycle number. Any worker
    /// payments already made during the aborted batch are NOT reversed -- the
    /// orchestrator must account for them in the next cycle.
    ///
    /// **Caller**: Admin only, during an active settlement.
    /// **Preconditions**: Settlement in progress, pool version matches.
    /// **Side effects**: Unlocks the pool, decrements cycle counter, deletes the batch object.
    public fun abort_settlement(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        batch: SettlementBatch,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(batch.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(pool.settlement_in_progress, ENoSettlementInProgress);

        pool.settlement_in_progress = false;
        // Revert cycle counter since this batch never finalized. Guard the
        // subtraction (it's >=1 here in normal flow since start_batch increments
        // before setting the flag, but never underflow on a future refactor).
        if (pool.current_cycle > 0) {
            pool.current_cycle = pool.current_cycle - 1;
        };

        // Emit audit trail of partial payments before destroying the batch
        event::emit(SettlementAborted {
            cycle: batch.cycle,
            total_paid: batch.total_paid,
            fees_collected: batch.fees_collected,
            workers_paid: batch.workers_paid,
        });

        // Destructure and delete the batch object
        let SettlementBatch {
            id,
            version: _,
            cycle: _,
            started_at: _,
            total_paid: _,
            fees_collected: _,
            workers_paid: _,
            finalized: _,
            config,
        } = batch;
        bag::destroy_empty(config);
        object::delete(id);
    }

    // =========================================================================
    // Fee management
    // =========================================================================

    /// Withdraw accumulated platform fees to a designated recipient address.
    ///
    /// Fees are collected during settlement via `pay_worker()` and accumulate in
    /// `fee_pool`. This function can be called at any time (not gated by settlement
    /// state) to sweep some or all accumulated fees.
    ///
    /// **Caller**: Admin only.
    /// **Preconditions**: `fee_pool` has at least `amount` available, pool version matches.
    /// **Side effects**: Transfers `Coin<COVE_TOKEN>` to `recipient`. Emits `FeesWithdrawn`.
    public fun withdraw_fees(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(amount > 0, EInvalidAmount);
        assert!(balance::value(&pool.fee_pool) >= amount, EInsufficientBalance);

        // Cap check happens AFTER the version/admin gates but BEFORE any state
        // mutation, so a cap-exceeded tx leaves the pool untouched.
        check_and_record_admin_withdrawal(
            pool.fee_cap,
            pool.fee_window_ms,
            &mut pool.fee_window_start,
            &mut pool.fee_window_used,
            amount,
            clock,
        );

        let withdraw_balance = balance::split(&mut pool.fee_pool, amount);
        let withdraw_coin = coin::from_balance(withdraw_balance, ctx);
        transfer::public_transfer(withdraw_coin, recipient);

        event::emit(FeesWithdrawn {
            amount,
            recipient,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // ─── Cap administration (super-admin only) ──────────────────────────────

    /// Retune the fee-withdrawal cap. Super-admin only — regular admins can
    /// execute capped withdrawals but cannot loosen the cap. Setting
    /// `new_cap = 0` pauses all admin fee withdrawals. Setting `new_window_ms
    /// = 0` keeps the current window length.
    ///
    /// The window counter resets on every cap update so changes take effect
    /// immediately (rather than waiting for the current window to elapse).
    public fun set_fee_cap(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(
            tx_context::sender(ctx) == admin_registry::super_admin(admin_reg),
            ENotSuperAdmin
        );
        // 0 is allowed (= paused). The cap is a Ledger-only setter that emits an
        // event; we deliberately don't hard-bound the value (a too-tight const
        // would itself need a republish to loosen).
        pool.fee_cap = new_cap;
        if (new_window_ms > 0) {
            pool.fee_window_ms = new_window_ms;
        };
        pool.fee_window_start = clock::timestamp_ms(clock);
        pool.fee_window_used = 0;

        event::emit(FeeCapUpdated {
            new_cap,
            new_window_ms: pool.fee_window_ms,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// Retune the settlement payout cap (L1). Super-admin only. `new_cap = 0`
    /// DISABLES the cap (unlimited payouts — NOT a pause; pausing payouts would
    /// brick settlement). `new_window_ms = 0` keeps the current window. Bounded
    /// so a fat-finger can't set an absurd cap/window. Enable this before
    /// mainnet, sized to ~2-3x peak daily payout volume.
    public fun set_payout_cap(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(
            tx_context::sender(ctx) == admin_registry::super_admin(admin_reg),
            ENotSuperAdmin
        );
        pool.payout_cap = new_cap;
        if (new_window_ms > 0) {
            pool.payout_window_ms = new_window_ms;
        };
        pool.payout_window_start = clock::timestamp_ms(clock);
        pool.payout_window_used = 0;

        event::emit(PayoutCapUpdated {
            new_cap,
            new_window_ms: pool.payout_window_ms,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    /// Change the live platform fee (basis points) applied by `pay_worker`.
    /// Super-admin only — it's a revenue parameter; the hot orchestrator key
    /// must NOT reach it. Hard-capped at MAX_FEE_BPS (5%) so a fat-finger or a
    /// compromised key can't set a fee > 100% (which would underflow
    /// `gross - fee` and abort every settlement).
    public fun set_platform_fee_bps(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        new_bps: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(pool.version == VERSION, EWrongVersion);
        assert!(
            tx_context::sender(ctx) == admin_registry::super_admin(admin_reg),
            ENotSuperAdmin
        );
        assert!(new_bps <= MAX_FEE_BPS, EFeeTooHigh);
        let old_bps = pool.platform_fee_bps;
        pool.platform_fee_bps = new_bps;

        event::emit(PlatformFeeUpdated {
            old_bps,
            new_bps,
            timestamp: clock::timestamp_ms(clock),
        });
    }


    // =========================================================================
    // Migration
    // =========================================================================

    /// Migrate the pool to the current package version after an upgrade.
    ///
    /// After publishing a new package version (with an incremented `VERSION` constant),
    /// the admin must call this to bump the pool's stored version. Until migration,
    /// all mutating functions will revert with `EWrongVersion`.
    ///
    /// **Caller**: Super admin only (version migrations follow package upgrades).
    /// **Preconditions**: `pool.version < VERSION` (i.e., pool is behind current package).
    public fun migrate(
        pool: &mut EscrowPool,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(pool.version < VERSION, EWrongVersion);
        pool.version = VERSION;
    }

    // =========================================================================
    // View functions
    // =========================================================================
    //
    // Read-only accessors for off-chain consumers and composing modules.
    // None of these require version checks since they don't mutate state.

    /// Returns the COVE balance for a given client, or 0 if they have never deposited.
    public fun client_balance(pool: &EscrowPool, client: address): u64 {
        if (table::contains(&pool.client_balances, client)) {
            *table::borrow(&pool.client_balances, client)
        } else {
            0
        }
    }

    /// Returns the total COVE held in the main pool (all client funds combined).
    public fun pool_balance(pool: &EscrowPool): u64 {
        balance::value(&pool.pool)
    }

    /// Returns the accumulated platform fees available for withdrawal.
    public fun fee_pool_balance(pool: &EscrowPool): u64 {
        balance::value(&pool.fee_pool)
    }

    /// Returns the current fee-withdrawal cap state as
    /// `(cap, window_ms, window_start_ms, window_used)`. For monitoring
    /// dashboards + the cove-admin-watch alerter.
    public fun fee_cap_status(pool: &EscrowPool): (u64, u64, u64, u64) {
        (pool.fee_cap, pool.fee_window_ms, pool.fee_window_start, pool.fee_window_used)
    }

    /// Returns the settlement payout-cap state as
    /// `(cap, window_ms, window_start_ms, window_used)`. `cap == 0` = disabled.
    public fun payout_cap_status(pool: &EscrowPool): (u64, u64, u64, u64) {
        (pool.payout_cap, pool.payout_window_ms, pool.payout_window_start, pool.payout_window_used)
    }

    /// Returns the live platform fee in basis points (the value pay_worker uses).
    public fun platform_fee_bps(pool: &EscrowPool): u64 {
        pool.platform_fee_bps
    }


    /// Returns the current (or most recently completed) settlement cycle number.
    public fun current_cycle(pool: &EscrowPool): u64 {
        pool.current_cycle
    }

    /// Returns the timestamp (ms) of the last finalized settlement, or 0 if none.
    public fun last_settlement(pool: &EscrowPool): u64 {
        pool.last_settlement
    }

    /// Returns true if a settlement batch is currently being processed.
    public fun is_settlement_in_progress(pool: &EscrowPool): bool {
        pool.settlement_in_progress
    }

    /// Returns the total COVE deposited by all clients, all-time.
    public fun total_deposited(pool: &EscrowPool): u64 {
        pool.total_deposited
    }

    /// Returns the total COVE withdrawn by clients, all-time.
    public fun total_withdrawn(pool: &EscrowPool): u64 {
        pool.total_withdrawn
    }

    /// Returns the total net COVE paid to workers (after fees), all-time.
    public fun total_paid_workers(pool: &EscrowPool): u64 {
        pool.total_paid_workers
    }

    /// Returns the total platform fees collected, all-time.
    public fun total_fees_collected(pool: &EscrowPool): u64 {
        pool.total_fees_collected
    }

    // --- Batch view functions ---

    /// Returns which settlement cycle this batch belongs to.
    public fun batch_cycle(batch: &SettlementBatch): u64 {
        batch.cycle
    }

    /// Returns the total net COVE paid to workers so far in this batch.
    public fun batch_total_paid(batch: &SettlementBatch): u64 {
        batch.total_paid
    }

    /// Returns the total platform fees collected so far in this batch.
    public fun batch_fees_collected(batch: &SettlementBatch): u64 {
        batch.fees_collected
    }

    /// Returns the number of distinct workers paid so far in this batch.
    public fun batch_workers_paid(batch: &SettlementBatch): u64 {
        batch.workers_paid
    }

    /// Returns true if this batch has been finalized.
    public fun batch_is_finalized(batch: &SettlementBatch): bool {
        batch.finalized
    }


    // === Test Helpers ===

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    #[test_only]
    /// Transfer a SettlementBatch to an address for testing purposes.
    /// Needed because SettlementBatch has only `key` (no `store`), so
    /// `transfer::transfer` cannot be called from outside this module.
    public fun transfer_batch_for_testing(batch: SettlementBatch, recipient: address) {
        transfer::transfer(batch, recipient)
    }
}
