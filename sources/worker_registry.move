/// Worker Registry for the Cove Decentralized Transcoding Network
///
/// This module manages the lifecycle of transcoding workers (nodes) in the Cove network.
/// Workers register with their hardware capabilities and are organized into tiers based
/// on their COVE token balance, which determines their priority for job assignment.
///
/// Key design decisions:
///   - Multiple Worker objects per wallet, keyed by (wallet, node_id). A single
///     operator wallet can run an arbitrary number of boxes; each box gets its own
///     on-chain Worker carrying that node's hardware capabilities, status, and
///     lifetime stats. This matches the orchestrator's per-(wallet, node_id) state.
///   - `register()` is admin-gated and takes the worker's wallet as a parameter
///     (v2 onwards). The orchestrator signs registrations on behalf of newly-
///     connected agents — operators never expose a wallet private key on a box.
///     `update_worker_tier`, `record_job_completion`, suspend/ban/deregister are
///     all already admin-gated, so register joins the same trust model.
///   - No on-chain staking. The orchestrator verifies each worker's COVE balance off-chain
///     (hourly) and calls `update_worker_tier()` to reflect the result on-chain. This avoids
///     locking user funds while still gating participation on economic commitment.
///   - Tier is per-wallet by nature (derived from one COVE balance), but each
///     Worker object holds its own copy that the orchestrator keeps in sync.
///   - Workers start inactive at TIER_NONE and auto-activate the first time their balance
///     is verified at >= Bronze threshold. They auto-deactivate if their balance drops to
///     TIER_NONE on a subsequent check.
///   - Bans are wallet-level (kicks every node under that wallet). Suspends are
///     per-Worker (one flaky box; wallet's other nodes keep running).
///   - `active_workers` is maintained as an explicit counter that is incremented/decremented
///     at every status transition. Earlier versions derived this count lazily, which caused
///     drift when workers were suspended or deregistered while active.
///   - Reputation uses saturating arithmetic to avoid u8 underflow (0 - 5 would abort).
///   - All shared objects carry a `version` field checked against the package constant so
///     that stale transactions fail cleanly after a package upgrade.
module cove::worker_registry {
    use sui::table::{Self, Table};
    use sui::event;
    use sui::clock::{Self, Clock};
    use cove::admin_registry::{Self, AdminRegistry};

    // ============================= Error Codes ==============================

    const ENotAdmin: u64 = 0;
    const EWorkerAlreadyRegistered: u64 = 1;
    const EWorkerNotRegistered: u64 = 2;
    const EWorkerBanned: u64 = 3;
    const EInvalidTier: u64 = 4;
    /// Raised when a transaction targets an object whose version doesn't match
    /// the current package version. Indicates the object needs migration first.
    const EWrongVersion: u64 = 5;
    /// Invalid status transition (e.g. suspending an already-suspended or banned worker).
    const EInvalidStatusTransition: u64 = 7;
    /// 2026-06-08 — set_tier_thresholds received non-ascending values
    /// (e.g. silver <= bronze) or a zero threshold. Defensive — without
    /// this, calculate_tier could return unexpected tiers depending
    /// on which branch fired first.
    const EInvalidTierThresholds: u64 = 8;
    /// 2026-06-08 — non-super-admin tried to call a super-admin
    /// function. (For now only set_tier_thresholds; we treat ENotAdmin
    /// as the regular-admin gate and ENotSuperAdmin as stricter.)
    const ENotSuperAdmin: u64 = 9;

    // ============================ Version Gate ===============================

    /// Bump this on every package upgrade. All entry points check it so that
    /// in-flight transactions against a stale package version abort cleanly.
    /// v2 (2026-05-28): multi-node-per-wallet redesign — registry re-keyed
    /// on (wallet, node_id), register is admin-gated, Worker gains node_id.
    const VERSION: u64 = 2;

    // ======================== Overflow Protection ============================

    /// Maximum value for u64, used for saturating arithmetic on lifetime counters.
    const MAX_U64: u64 = 18_446_744_073_709_551_615;

    // ===================== Tier Balance Requirements ========================
    // Thresholds use 9 decimal places (COVE smallest unit).
    // Tiers:  None (< 100K) -> Bronze (100K) -> Silver (500K)
    //         -> Gold (2.5M) -> Platinum (10M COVE)
    //
    // Bumped 2026-05-12 (was 10K/50K/100K/500K). Reason: at the new
    // post-launch ~$0.01 USD floor, 10K Bronze was a $100 stake — too
    // trivial to deter sybil farms or signal real operator commitment.
    // Real operators spend $2k-$10k on a single GPU rig; a stake floor
    // of ~$1k aligns operator incentives with hardware investment.
    // 5x ladder between tiers.

    const BRONZE_REQUIREMENT: u64 = 100_000_000_000_000;       // 100,000 COVE  (~$1,000)
    const SILVER_REQUIREMENT: u64 = 500_000_000_000_000;       // 500,000 COVE  (~$5,000)
    const GOLD_REQUIREMENT: u64 = 2_500_000_000_000_000;       // 2,500,000 COVE (~$25,000)
    const PLATINUM_REQUIREMENT: u64 = 10_000_000_000_000_000;  // 10,000,000 COVE (~$100,000)

    // ============================= Tier Enum ================================

    const TIER_NONE: u8 = 0;
    const TIER_BRONZE: u8 = 1;
    const TIER_SILVER: u8 = 2;
    const TIER_GOLD: u8 = 3;
    const TIER_PLATINUM: u8 = 4;

    // =========================== Worker Status ==============================

    const STATUS_INACTIVE: u8 = 0;
    const STATUS_ACTIVE: u8 = 1;
    const STATUS_SUSPENDED: u8 = 2;
    const STATUS_BANNED: u8 = 3;

    // =============================== Structs ================================

    /// Shared singleton that tracks global worker state.
    ///
    /// Created once at module publish via `init` and shared. The `workers` table
    /// is keyed (wallet → node_id → Worker object ID). A single wallet may own
    /// any number of Worker objects, one per box it runs. The `banned` table
    /// is wallet-level — a ban prevents ANY new registration by that wallet.
    public struct WorkerRegistry has key {
        id: UID,
        /// Must equal `VERSION`; checked on every public entry point.
        version: u64,
        /// Lifetime count of currently registered Worker objects across all
        /// wallets (includes inactive/suspended).
        total_workers: u64,
        /// Count of Worker objects whose status is STATUS_ACTIVE right now.
        /// Maintained explicitly at every status transition to avoid drift.
        active_workers: u64,
        /// Nested map: wallet → (node_id → Worker object ID). The inner table
        /// is created lazily on a wallet's first registration and removed when
        /// the wallet's last Worker deregisters, so an empty registry costs
        /// nothing per wallet.
        workers: Table<address, Table<vector<u8>, ID>>,
        /// Permanently banned wallets. Prevents new registrations on the
        /// wallet (existing Worker objects retain their state).
        banned: Table<address, bool>,

        // ─── Mutable tier thresholds (2026-06-08) ───────────────────
        //
        // These were previously const values baked into the bytecode.
        // Now state fields so super-admin can adjust as COVE/USD price
        // moves — at the documented defaults below (100k COVE = ~$1k
        // at the post-launch est), the bronze threshold is fixed in
        // COVE units. If COVE moons 10x, $1k = 10k COVE — operators
        // need to drop the COVE threshold to keep the USD-equivalent
        // constant. Without this, the protocol either:
        //   - Strands honest small operators (price rose, they can't
        //     afford the threshold any more)
        //   - Lets unqualified operators in (price fell)
        //
        // NO FREEZE on these — they need to remain mutable forever.
        // Same super-admin gate + ascending validation as
        // set_tier_thresholds().
        bronze_threshold: u64,
        silver_threshold: u64,
        gold_threshold: u64,
        platinum_threshold: u64,
    }

    /// Per-worker on-chain record, created at registration and shared so that
    /// both the worker and the admin/orchestrator can mutate it.
    ///
    /// The orchestrator updates `tier`, `verified_balance`, and `last_verified`
    /// periodically (roughly hourly). Job stats and reputation are updated by
    /// the orchestrator when a job completes.
    public struct Worker has key, store {
        id: UID,
        /// Must equal `VERSION`; checked on capability updates.
        version: u64,
        /// Operator wallet that owns this node. The on-chain Worker is bound
        /// to (wallet, node_id) — a wallet can run any number of nodes, each
        /// with its own Worker object. Admin-only mutations enforce this
        /// binding (the orchestrator signs all updates).
        wallet: address,
        /// Stable per-node identifier supplied at registration (the same
        /// string the orchestrator uses as NodeID, e.g. "node-1"). Together
        /// with `wallet` this uniquely identifies the on-chain Worker.
        node_id: vector<u8>,
        /// Current tier derived from the most recent balance verification.
        /// Set by `update_worker_tier()`; never modified by the worker itself.
        tier: u8,
        /// One of STATUS_INACTIVE / ACTIVE / SUSPENDED / BANNED.
        status: u8,
        /// Epoch-millis timestamp of the last successful balance verification.
        last_verified: u64,
        /// The COVE balance (with 9 decimals) observed during verification.
        verified_balance: u64,
        /// Epoch-millis timestamp when the worker called `register()`.
        registered_at: u64,
        /// Cumulative number of transcoding jobs completed (success or failure).
        jobs_completed: u64,
        /// Cumulative minutes of media processed across all jobs.
        minutes_processed: u64,
        /// Cumulative COVE earned across all jobs (with 9 decimals).
        total_earnings: u64,
        /// Reputation score in [0, 100]. Starts at 50 (neutral).
        /// +1 per successful job, -5 per failed job, clamped to [0, 100].
        reputation: u8,
        /// Self-reported hardware profile used for job matching.
        capabilities: WorkerCapabilities,
    }

    /// Self-reported hardware profile submitted at registration.
    ///
    /// The orchestrator uses these fields to match incoming transcode jobs to
    /// workers that can handle them (e.g. AV1 encode requires a capable GPU).
    /// Values are not validated on-chain; dishonest reporting leads to job
    /// failures which hurt the worker's reputation score.
    public struct WorkerCapabilities has store, copy, drop {
        /// GPU vendor: 0 = None, 1 = NVIDIA, 2 = AMD, 3 = Intel.
        gpu_type: u8,
        /// Keccak-256 hash of the GPU model name string (e.g. "RTX 4090").
        /// Stored as a hash to keep on-chain storage compact.
        gpu_model_hash: u256,
        /// GPU VRAM in whole gigabytes.
        gpu_memory_gb: u16,
        /// Number of logical CPU cores available.
        cpu_cores: u8,
        /// Primary processing mode: 0 = CPU, 1 = GPU.
        processing_type: u8,
        /// Bitmap of supported codecs: H264(0x01), HEVC(0x02), VP9(0x04), AV1(0x08).
        /// E.g. 0x0B = H264 + HEVC + AV1.
        supported_codecs: u8,
        /// Max number of transcode streams this worker can handle simultaneously.
        max_concurrent: u8,
        /// Numeric region code for geographic job routing.
        region: u16,
    }

    // ============================== Events ==================================

    /// Emitted when a new worker (wallet, node_id) successfully registers.
    public struct WorkerRegistered has copy, drop {
        worker: address,
        node_id: vector<u8>,
        tier: u8,
        timestamp: u64,
    }

    /// Emitted when a worker's status changes (active/inactive/suspended).
    /// Carries node_id because status is per-Worker (one wallet's other
    /// nodes are unaffected when a single box flips status).
    public struct WorkerStatusChanged has copy, drop {
        worker: address,
        node_id: vector<u8>,
        old_status: u8,
        new_status: u8,
    }

    /// Emitted when the orchestrator updates a worker's tier after balance
    /// verification. Tier is wallet-level but the on-chain copy is per-Worker,
    /// so the event carries node_id for unambiguous indexing.
    public struct WorkerTierUpdated has copy, drop {
        worker: address,
        node_id: vector<u8>,
        old_tier: u8,
        new_tier: u8,
        verified_balance: u64,
    }

    /// Emitted when a worker (wallet, node_id) is deregistered.
    public struct WorkerDeregistered has copy, drop {
        worker: address,
        node_id: vector<u8>,
        /// The address that initiated the deregistration (admin in v2+).
        removed_by: address,
    }

    /// Emitted when the orchestrator records a completed job for a worker.
    public struct JobCompleted has copy, drop {
        worker: address,
        node_id: vector<u8>,
        minutes: u64,
        earnings: u64,
    }

    /// Emitted on `set_tier_thresholds`. Tier thresholds are global —
    /// changing them re-tiers every worker on their next
    /// `update_tier_and_balance` call (orchestrator runs this hourly).
    public struct TierThresholdsUpdated has copy, drop {
        admin: address,
        old_bronze: u64,
        new_bronze: u64,
        old_silver: u64,
        new_silver: u64,
        old_gold: u64,
        new_gold: u64,
        old_platinum: u64,
        new_platinum: u64,
        timestamp_ms: u64,
    }

    // ========================= Initialization ===============================

    /// Module initializer. Creates the shared `WorkerRegistry` singleton.
    fun init(ctx: &mut TxContext) {
        let registry = WorkerRegistry {
            id: object::new(ctx),
            version: VERSION,
            total_workers: 0,
            active_workers: 0,
            workers: table::new(ctx),
            banned: table::new(ctx),
            // 2026-06-08 — tier thresholds seeded from the documented
            // const defaults. Mutable forever via set_tier_thresholds()
            // so super-admin can adjust as COVE/USD price moves.
            bronze_threshold:   BRONZE_REQUIREMENT,
            silver_threshold:   SILVER_REQUIREMENT,
            gold_threshold:     GOLD_REQUIREMENT,
            platinum_threshold: PLATINUM_REQUIREMENT,
        };

        transfer::share_object(registry);
    }

    // ======================= Worker Registration ============================

    /// Register a (wallet, node_id) as a transcoding worker.
    ///
    /// Admin-gated (the orchestrator signs every registration on behalf of
    /// agents that have just connected). The orchestrator passes the
    /// `worker_wallet` so the on-chain Worker is correctly bound to the
    /// operator who owns the bearer token, without needing the operator to
    /// expose a wallet private key on a Linux box.
    ///
    /// Creates a new shared `Worker` object and inserts (wallet → node_id →
    /// Worker ID) into the registry. The worker starts at TIER_NONE /
    /// STATUS_INACTIVE and is activated on the first successful balance
    /// verification.
    ///
    /// Preconditions:
    ///   - Caller must be an admin.
    ///   - `worker_wallet` must not be banned.
    ///   - (worker_wallet, node_id) must not already be registered.
    ///
    /// Side effects:
    ///   - Creates the wallet's inner table on first registration for that wallet.
    ///   - Increments `total_workers`.
    ///   - Emits `WorkerRegistered`.
    ///   - The new `Worker` object is shared (not owned) so the orchestrator
    ///     can later mutate its tier and stats.
    public fun register(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker_wallet: address,
        node_id: vector<u8>,
        gpu_type: u8,
        gpu_model_hash: u256,
        gpu_memory_gb: u16,
        cpu_cores: u8,
        processing_type: u8,
        supported_codecs: u8,
        max_concurrent: u8,
        region: u16,
        timestamp: u64,
        ctx: &mut TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: the orchestrator auto-registers workers on connect.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(!table::contains(&registry.banned, worker_wallet), EWorkerBanned);

        // Ensure the wallet's inner (node_id → Worker) table exists.
        if (!table::contains(&registry.workers, worker_wallet)) {
            table::add(&mut registry.workers, worker_wallet, table::new<vector<u8>, ID>(ctx));
        };
        let wallet_nodes = table::borrow_mut(&mut registry.workers, worker_wallet);
        assert!(!table::contains(wallet_nodes, node_id), EWorkerAlreadyRegistered);

        let capabilities = WorkerCapabilities {
            gpu_type,
            gpu_model_hash,
            gpu_memory_gb,
            cpu_cores,
            processing_type,
            supported_codecs,
            max_concurrent,
            region,
        };

        let worker = Worker {
            id: object::new(ctx),
            version: VERSION,
            wallet: worker_wallet,
            node_id: node_id,
            tier: TIER_NONE, // Tier assigned later by orchestrator after balance check
            status: STATUS_INACTIVE,
            last_verified: 0,
            verified_balance: 0,
            registered_at: timestamp,
            jobs_completed: 0,
            minutes_processed: 0,
            total_earnings: 0,
            reputation: 50, // Neutral starting reputation (range 0-100)
            capabilities,
        };

        let worker_id = object::id(&worker);
        table::add(wallet_nodes, worker.node_id, worker_id);
        registry.total_workers = registry.total_workers + 1;

        event::emit(WorkerRegistered {
            worker: worker_wallet,
            node_id: worker.node_id,
            tier: TIER_NONE,
            timestamp,
        });

        transfer::share_object(worker);
    }

    // ===================== Orchestrator / Admin Calls ========================

    /// Update a worker's tier based on their off-chain verified COVE balance.
    ///
    /// Called by the orchestrator roughly once per hour for every registered
    /// worker. The orchestrator reads the worker's on-chain COVE balance,
    /// then calls this function with the observed value so that the tier
    /// is recorded on-chain for job-matching and priority purposes.
    ///
    /// Tier transitions trigger automatic status changes:
    ///   - Inactive worker whose balance reaches Bronze or above -> auto-ACTIVE.
    ///   - Active worker whose balance drops to TIER_NONE        -> auto-INACTIVE.
    ///   - Suspended workers are NOT affected (admin must explicitly reactivate).
    ///
    /// Caller: admin/orchestrator only.
    ///
    /// Side effects:
    ///   - May increment or decrement `active_workers`.
    ///   - Emits `WorkerTierUpdated` if the tier changed.
    ///   - Emits `WorkerStatusChanged` if activation/deactivation occurred.
    public fun update_worker_tier(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        verified_balance: u64,
        timestamp: u64,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        // Guard the Worker object's version too (matches suspend/reactivate/
        // update_capabilities): a stale, un-migrated Worker must fail closed
        // after an upgrade rather than be mutated under old field semantics.
        assert!(worker.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: the orchestrator refreshes a worker's tier when its
        // verified COVE balance changes.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);

        let old_tier = worker.tier;
        let new_tier = calculate_tier(registry, verified_balance);

        worker.tier = new_tier;
        worker.verified_balance = verified_balance;
        worker.last_verified = timestamp;

        // Auto-activate: worker had no qualifying balance before but now does
        if (new_tier >= TIER_BRONZE && worker.status == STATUS_INACTIVE) {
            worker.status = STATUS_ACTIVE;
            registry.active_workers = registry.active_workers + 1;
            event::emit(WorkerStatusChanged {
                worker: worker.wallet,
                node_id: worker.node_id,
                old_status: STATUS_INACTIVE,
                new_status: STATUS_ACTIVE,
            });
        // Auto-deactivate: balance dropped below Bronze while worker was active
        } else if (new_tier == TIER_NONE && worker.status == STATUS_ACTIVE) {
            worker.status = STATUS_INACTIVE;
            registry.active_workers = registry.active_workers - 1;
            event::emit(WorkerStatusChanged {
                worker: worker.wallet,
                node_id: worker.node_id,
                old_status: STATUS_ACTIVE,
                new_status: STATUS_INACTIVE,
            });
        };
        // NOTE: Suspended workers are intentionally skipped. Their status is
        // managed exclusively through suspend_worker / reactivate_worker.

        if (old_tier != new_tier) {
            event::emit(WorkerTierUpdated {
                worker: worker.wallet,
                node_id: worker.node_id,
                old_tier,
                new_tier,
                verified_balance,
            });
        };
    }

    /// Record the outcome of a completed transcoding job for a worker.
    ///
    /// Called by the orchestrator/admin after a job finishes (successfully or not).
    /// Workers cannot call this themselves -- the orchestrator is the source of
    /// truth for job outcomes to prevent workers from inflating their own stats.
    ///
    /// Reputation update rules (asymmetric to penalize failures heavily):
    ///   - Success: +1 (capped at 100)
    ///   - Failure: -5 (floored at 0 via saturating subtraction)
    ///
    /// The saturating subtraction is critical: `reputation` is u8, so a naive
    /// `reputation - 5` would abort with arithmetic underflow if reputation < 5.
    ///
    /// Lifetime counters (`jobs_completed`, `minutes_processed`, `total_earnings`)
    /// use saturating addition to prevent u64 overflow on extremely long-running
    /// workers.
    ///
    /// Caller: admin/orchestrator only.
    ///
    /// Side effects:
    ///   - Increments `jobs_completed`, `minutes_processed`, `total_earnings`.
    ///   - Adjusts `reputation`.
    ///   - Emits `JobCompleted`.
    public fun record_job_completion(
        registry: &WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        minutes: u64,
        earnings: u64,
        success: bool,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);

        // Saturating add for lifetime counters to prevent u64 overflow
        if (worker.jobs_completed < MAX_U64) {
            worker.jobs_completed = worker.jobs_completed + 1;
        };
        if (worker.minutes_processed <= MAX_U64 - minutes) {
            worker.minutes_processed = worker.minutes_processed + minutes;
        } else {
            worker.minutes_processed = MAX_U64;
        };
        if (worker.total_earnings <= MAX_U64 - earnings) {
            worker.total_earnings = worker.total_earnings + earnings;
        } else {
            worker.total_earnings = MAX_U64;
        };

        // Reputation: +1 on success (cap 100), -5 on failure (floor 0)
        if (success) {
            if (worker.reputation < 100) {
                worker.reputation = worker.reputation + 1;
            };
        } else {
            // Saturating subtract to prevent u8 underflow abort
            if (worker.reputation >= 5) {
                worker.reputation = worker.reputation - 5;
            } else {
                worker.reputation = 0;
            };
        };

        event::emit(JobCompleted {
            worker: worker.wallet,
            node_id: worker.node_id,
            minutes,
            earnings,
        });
    }

    // ====================== Capability Updates ==============================

    /// Update a worker's hardware capabilities profile.
    ///
    /// Orchestrator-allowed in v2 (same as `register` / `update_worker_tier`):
    /// the orchestrator is the source of truth for what an agent's hardware
    /// looks like (the verified-hardware probe results stream in via WS), and
    /// the operator's wallet does not sign from the box, so capability updates
    /// are pushed by the orchestrator. It refreshes the profile when a later
    /// probe measures different caps than the first registration (e.g. per-
    /// device concurrency summing now counts a 2nd GPU + the CPU lane), keeping
    /// the on-chain record in sync with reality. A wallet-signed self-update is
    /// not offered; to force a refresh, restart the agent and the probe reruns.
    ///
    /// Caller: admin OR orchestrator.
    public fun update_capabilities(
        registry: &WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        gpu_type: u8,
        gpu_model_hash: u256,
        gpu_memory_gb: u16,
        cpu_cores: u8,
        processing_type: u8,
        supported_codecs: u8,
        max_concurrent: u8,
        region: u16,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        // Orchestrator-allowed: capability refreshes are pushed by the
        // orchestrator on behalf of agents that hold only a bearer token.
        assert!(admin_registry::is_admin_or_orchestrator(admin_reg, tx_context::sender(ctx)), ENotAdmin);

        worker.capabilities = WorkerCapabilities {
            gpu_type,
            gpu_model_hash,
            gpu_memory_gb,
            cpu_cores,
            processing_type,
            supported_codecs,
            max_concurrent,
            region,
        };
    }

    // =================== Admin Moderation Functions =========================

    /// Suspend a worker, preventing them from receiving new jobs.
    ///
    /// Suspended workers keep their registration and stats but are excluded
    /// from job assignment. If the worker was active, `active_workers` is
    /// decremented. Use `reactivate_worker()` to restore them.
    ///
    /// Caller: admin only.
    ///
    /// Side effects:
    ///   - Decrements `active_workers` if worker was active.
    ///   - Emits `WorkerStatusChanged`.
    public fun suspend_worker(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(worker.status != STATUS_SUSPENDED, EInvalidStatusTransition);
        assert!(worker.status != STATUS_BANNED, EInvalidStatusTransition);

        let old_status = worker.status;
        worker.status = STATUS_SUSPENDED;

        // Only decrement if the worker was actually counted as active
        if (old_status == STATUS_ACTIVE) {
            registry.active_workers = registry.active_workers - 1;
        };

        event::emit(WorkerStatusChanged {
            worker: worker.wallet,
            node_id: worker.node_id,
            old_status,
            new_status: STATUS_SUSPENDED,
        });
    }

    /// Reactivate a suspended worker, allowing them to receive jobs again.
    ///
    /// Requires that the worker is currently suspended (not inactive or banned)
    /// and that they still hold at least a Bronze-tier balance. This prevents
    /// reactivating a worker who sold off their COVE while suspended.
    ///
    /// Caller: admin only.
    ///
    /// Side effects:
    ///   - Increments `active_workers`.
    ///   - Emits `WorkerStatusChanged`.
    public fun reactivate_worker(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(worker.status == STATUS_SUSPENDED, EWorkerNotRegistered);
        assert!(worker.tier >= TIER_BRONZE, EInvalidTier);

        worker.status = STATUS_ACTIVE;
        registry.active_workers = registry.active_workers + 1;

        event::emit(WorkerStatusChanged {
            worker: worker.wallet,
            node_id: worker.node_id,
            old_status: STATUS_SUSPENDED,
            new_status: STATUS_ACTIVE,
        });
    }

    /// Permanently ban a worker, marking THIS Worker as banned and adding the
    /// owning wallet to the banned set (preventing any future registrations).
    ///
    /// Bans are wallet-level in intent but per-Worker in implementation
    /// because each Worker is its own shared object: the admin must call
    /// `ban_worker` once per Worker under the offending wallet. The first
    /// call adds the wallet to the `banned` table (idempotent on subsequent
    /// calls), so as soon as one Worker is banned, no NEW registrations are
    /// possible under that wallet — the orchestrator wraps this in a sweep
    /// loop so the operator sees an atomic "wallet kicked" from their side.
    ///
    /// Unlike suspension, banning cannot be reversed through
    /// `reactivate_worker()`.
    ///
    /// Caller: admin only.
    ///
    /// Side effects:
    ///   - Decrements `active_workers` if this worker was active.
    ///   - Adds `worker.wallet` to `banned` table (idempotent).
    ///   - Emits `WorkerStatusChanged` for this (wallet, node_id).
    public fun ban_worker(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(worker.status != STATUS_BANNED, EInvalidStatusTransition);

        let old_status = worker.status;
        worker.status = STATUS_BANNED;

        if (old_status == STATUS_ACTIVE) {
            registry.active_workers = registry.active_workers - 1;
        };

        // Prevent re-registration (idempotent for subsequent ban_worker calls
        // on other Workers owned by this wallet).
        if (!table::contains(&registry.banned, worker.wallet)) {
            table::add(&mut registry.banned, worker.wallet, true);
        };

        event::emit(WorkerStatusChanged {
            worker: worker.wallet,
            node_id: worker.node_id,
            old_status,
            new_status: STATUS_BANNED,
        });
    }

    /// Permanently remove a (wallet, node_id) Worker from the registry.
    ///
    /// Admin-only in v2: the operator's wallet does not sign from the box,
    /// and the orchestrator drives deregistration via the dashboard. The
    /// `Worker` object is destructured and deleted; the wallet's inner
    /// (node_id → ID) table is dropped if this was the wallet's last Worker
    /// so that an empty wallet leaves no storage footprint.
    ///
    /// Caller: admin only.
    ///
    /// Side effects:
    ///   - Decrements `active_workers` if worker was active.
    ///   - Decrements `total_workers`.
    ///   - Removes (wallet, node_id) from the registry's nested table.
    ///   - Drops the wallet's inner table if it becomes empty.
    ///   - Destroys the `Worker` object (cannot be undone).
    ///   - Emits `WorkerDeregistered`.
    public fun deregister(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: Worker,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(worker.version == VERSION, EWrongVersion);
        let sender = tx_context::sender(ctx);
        assert!(admin_registry::is_admin(admin_reg, sender), ENotAdmin);

        if (worker.status == STATUS_ACTIVE) {
            registry.active_workers = registry.active_workers - 1;
        };

        let worker_addr = worker.wallet;
        let worker_node_id = worker.node_id;

        // Remove the (wallet, node_id) entry; drop the wallet's inner table
        // if this was its last Worker. Scope the inner mutable borrow into
        // a block so it ends before we touch `registry.workers` again.
        let inner_empty = {
            let wallet_nodes = table::borrow_mut(&mut registry.workers, worker_addr);
            table::remove(wallet_nodes, worker_node_id);
            table::is_empty(wallet_nodes)
        };
        if (inner_empty) {
            let inner = table::remove(&mut registry.workers, worker_addr);
            table::destroy_empty(inner);
        };

        registry.total_workers = registry.total_workers - 1;

        event::emit(WorkerDeregistered {
            worker: worker_addr,
            node_id: worker_node_id,
            removed_by: sender,
        });

        // Destructure and delete -- all fields are droppable so we discard them
        let Worker {
            id,
            version: _,
            wallet: _,
            node_id: _,
            tier: _,
            status: _,
            last_verified: _,
            verified_balance: _,
            registered_at: _,
            jobs_completed: _,
            minutes_processed: _,
            total_earnings: _,
            reputation: _,
            capabilities: _,
        } = worker;
        object::delete(id);
    }

    // ─── Tier threshold setter (2026-06-08) ─────────────────────────
    //
    // Super-admin replaces the per-tier COVE thresholds. NO FREEZE
    // here — tier thresholds must adapt as COVE/USD price moves
    // (a 10x price move means the old 100k COVE bronze cap is now
    // worth 10x what it was; would either strand honest small
    // operators or let unqualified ones in if thresholds stayed
    // const). Strict ascending validation prevents nonsense input.

    /// Replace the per-tier minimum COVE balance thresholds.
    /// SUPER-ADMIN ONLY. Validates bronze < silver < gold < platinum
    /// and all > 0. Next `update_tier_and_balance` call on each
    /// worker re-tiers them against the new thresholds.
    public fun set_tier_thresholds(
        admin_reg: &admin_registry::AdminRegistry,
        registry: &mut WorkerRegistry,
        new_bronze: u64,
        new_silver: u64,
        new_gold: u64,
        new_platinum: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(
            admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)),
            ENotSuperAdmin
        );
        // Strict-ascending check + no zeros. A 0 bronze would mean
        // every wallet with a non-zero balance instantly becomes
        // bronze, which is not a meaningful tier.
        assert!(new_bronze > 0, EInvalidTierThresholds);
        assert!(new_silver > new_bronze, EInvalidTierThresholds);
        assert!(new_gold > new_silver, EInvalidTierThresholds);
        assert!(new_platinum > new_gold, EInvalidTierThresholds);

        let old_bronze = registry.bronze_threshold;
        let old_silver = registry.silver_threshold;
        let old_gold = registry.gold_threshold;
        let old_platinum = registry.platinum_threshold;

        registry.bronze_threshold = new_bronze;
        registry.silver_threshold = new_silver;
        registry.gold_threshold = new_gold;
        registry.platinum_threshold = new_platinum;

        event::emit(TierThresholdsUpdated {
            admin: tx_context::sender(ctx),
            old_bronze, new_bronze,
            old_silver, new_silver,
            old_gold, new_gold,
            old_platinum, new_platinum,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── State getters ──────────────────────────────────────────────
    // For the dashboard's checklist + tier displays.

    public fun bronze_threshold(registry: &WorkerRegistry): u64 { registry.bronze_threshold }
    public fun silver_threshold(registry: &WorkerRegistry): u64 { registry.silver_threshold }
    public fun gold_threshold(registry: &WorkerRegistry): u64 { registry.gold_threshold }
    public fun platinum_threshold(registry: &WorkerRegistry): u64 { registry.platinum_threshold }

    // ======================== Helper Functions ===============================

    /// Map a raw COVE balance to its corresponding tier.
    /// Checks thresholds from highest to lowest so that the first match wins.
    /// Reads the mutable thresholds from the registry — operator can
    /// adjust via `set_tier_thresholds()` as COVE/USD price moves.
    fun calculate_tier(registry: &WorkerRegistry, balance: u64): u8 {
        if (balance >= registry.platinum_threshold) {
            TIER_PLATINUM
        } else if (balance >= registry.gold_threshold) {
            TIER_GOLD
        } else if (balance >= registry.silver_threshold) {
            TIER_SILVER
        } else if (balance >= registry.bronze_threshold) {
            TIER_BRONZE
        } else {
            TIER_NONE
        }
    }

    // ========================= View Functions ===============================
    // Read-only accessors for off-chain indexers and other modules.

    /// Returns the total number of registered workers (all statuses).
    public fun total_workers(registry: &WorkerRegistry): u64 {
        registry.total_workers
    }

    /// Returns the number of workers currently in STATUS_ACTIVE.
    public fun active_workers(registry: &WorkerRegistry): u64 {
        registry.active_workers
    }

    /// Check whether a wallet has at least one registered `Worker` entry.
    /// True iff the wallet has a non-empty inner (node_id → ID) table.
    public fun is_registered(registry: &WorkerRegistry, addr: address): bool {
        if (!table::contains(&registry.workers, addr)) {
            return false
        };
        !table::is_empty(table::borrow(&registry.workers, addr))
    }

    /// Check whether a specific (wallet, node_id) pair has a registered Worker.
    public fun is_node_registered(
        registry: &WorkerRegistry,
        addr: address,
        node_id: vector<u8>,
    ): bool {
        if (!table::contains(&registry.workers, addr)) {
            return false
        };
        table::contains(table::borrow(&registry.workers, addr), node_id)
    }

    /// Look up the on-chain Worker object ID for a (wallet, node_id) pair.
    /// Aborts with EWorkerNotRegistered if the entry does not exist; callers
    /// that want a non-aborting probe should use `is_node_registered` first.
    public fun get_worker_id(
        registry: &WorkerRegistry,
        addr: address,
        node_id: vector<u8>,
    ): ID {
        assert!(table::contains(&registry.workers, addr), EWorkerNotRegistered);
        let wallet_nodes = table::borrow(&registry.workers, addr);
        assert!(table::contains(wallet_nodes, node_id), EWorkerNotRegistered);
        *table::borrow(wallet_nodes, node_id)
    }

    /// Check whether an address has been permanently banned.
    public fun is_banned(registry: &WorkerRegistry, addr: address): bool {
        table::contains(&registry.banned, addr)
    }

    public fun worker_wallet(worker: &Worker): address {
        worker.wallet
    }

    public fun worker_node_id(worker: &Worker): vector<u8> {
        worker.node_id
    }

    public fun worker_tier(worker: &Worker): u8 {
        worker.tier
    }

    public fun worker_status(worker: &Worker): u8 {
        worker.status
    }

    public fun worker_reputation(worker: &Worker): u8 {
        worker.reputation
    }

    public fun worker_jobs_completed(worker: &Worker): u64 {
        worker.jobs_completed
    }

    public fun worker_minutes_processed(worker: &Worker): u64 {
        worker.minutes_processed
    }

    public fun worker_total_earnings(worker: &Worker): u64 {
        worker.total_earnings
    }

    public fun worker_capabilities(worker: &Worker): &WorkerCapabilities {
        &worker.capabilities
    }

    /// Returns the minimum COVE balance required for a given tier.
    /// Returns 0 for TIER_NONE or any unrecognized value. Reads the
    /// mutable thresholds from the registry — source of truth as
    /// the operator adjusts via `set_tier_thresholds()`.
    public fun tier_requirement(registry: &WorkerRegistry, tier: u8): u64 {
        if (tier == TIER_BRONZE) {
            registry.bronze_threshold
        } else if (tier == TIER_SILVER) {
            registry.silver_threshold
        } else if (tier == TIER_GOLD) {
            registry.gold_threshold
        } else if (tier == TIER_PLATINUM) {
            registry.platinum_threshold
        } else {
            0
        }
    }

    // ==================== Tier Constant Accessors ============================
    // Expose tier/status constants so other modules and PTBs can reference
    // them without hard-coding magic numbers.

    public fun tier_none(): u8 { TIER_NONE }
    public fun tier_bronze(): u8 { TIER_BRONZE }
    public fun tier_silver(): u8 { TIER_SILVER }
    public fun tier_gold(): u8 { TIER_GOLD }
    public fun tier_platinum(): u8 { TIER_PLATINUM }

    public fun status_inactive(): u8 { STATUS_INACTIVE }
    public fun status_active(): u8 { STATUS_ACTIVE }
    public fun status_suspended(): u8 { STATUS_SUSPENDED }
    public fun status_banned(): u8 { STATUS_BANNED }

    // ========================== Codec Flags ==================================
    // Bitmap flags for the `supported_codecs` field in WorkerCapabilities.
    // Combine with bitwise OR: e.g. codec_h264() | codec_av1() = 0x09.

    public fun codec_h264(): u8 { 1 }
    public fun codec_hevc(): u8 { 2 }
    public fun codec_vp9(): u8 { 4 }
    public fun codec_av1(): u8 { 8 }

    /// Test whether a worker's capabilities include a specific codec.
    /// Usage: `has_codec(caps, codec_av1())` returns true if AV1 bit is set.
    public fun has_codec(capabilities: &WorkerCapabilities, codec: u8): bool {
        (capabilities.supported_codecs & codec) != 0
    }

    // === Test Helpers ===

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    // ======================= Migration Functions ============================
    // After a package upgrade, the VERSION constant is bumped. Existing shared
    // objects still carry the old version, so all entry points will abort with
    // EWrongVersion until the admin runs these migration functions to update
    // each object's version field.

    /// Migrate the shared `WorkerRegistry` object to the current package version.
    ///
    /// Must be called once by the admin after every package upgrade, before any
    /// other registry operations can succeed.
    ///
    /// Caller: super admin only (version migrations follow package upgrades).
    public fun migrate_registry(
        registry: &mut WorkerRegistry,
        admin_reg: &AdminRegistry,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(registry.version < VERSION, EWrongVersion);
        registry.version = VERSION;
    }

    /// Migrate a single `Worker` object to the current package version.
    ///
    /// Must be called by the admin for each worker object after a package
    /// upgrade. Workers whose objects have not been migrated will fail on
    /// any operation that checks `worker.version`.
    ///
    /// Caller: super admin only (version migrations follow package upgrades).
    public fun migrate_worker(
        registry: &WorkerRegistry,
        admin_reg: &AdminRegistry,
        worker: &mut Worker,
        ctx: &TxContext
    ) {
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotSuperAdmin);
        assert!(worker.version < VERSION, EWrongVersion);
        worker.version = VERSION;
    }
}
