#[test_only]
module cove::worker_registry_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock;
    use cove::worker_registry::{Self, WorkerRegistry, Worker};
    use cove::admin_registry::{Self, AdminRegistry};

    // ========================== Test Addresses ===============================

    const ADMIN: address = @0xAD;
    const WORKER1: address = @0x1;
    const WORKER2: address = @0x2;
    /// The orchestrator's least-privilege role -- not an admin.
    const ORCHESTRATOR: address = @0x0B;
    /// A wallet with no admin or orchestrator privileges at all.
    const STRANGER: address = @0xBAD;

    // ============================= Node IDs =================================

    fun node_a(): vector<u8> { b"node-a" }
    fun node_b(): vector<u8> { b"node-b" }

    // ======================== Tier Thresholds ================================
    // Mirror the constants in worker_registry.move. Bumped 2026-05-12 along
    // with the contract: 10K/50K → 100K/500K (5× ladder, ~$1k/$5k at $0.01 COVE).

    const BRONZE_REQUIREMENT: u64 = 100_000_000_000_000;
    const SILVER_REQUIREMENT: u64 = 500_000_000_000_000;

    // ====================== Default Capability Args =========================
    // Reusable capability values for worker registration helpers.

    const GPU_TYPE: u8 = 1;             // NVIDIA
    const GPU_MODEL_HASH: u256 = 0xABCD;
    const GPU_MEMORY_GB: u16 = 24;
    const CPU_CORES: u8 = 16;
    const PROCESSING_TYPE: u8 = 1;      // GPU
    const SUPPORTED_CODECS: u8 = 0x0F;  // All codecs
    const MAX_CONCURRENT: u8 = 4;
    const REGION: u16 = 1;
    const TIMESTAMP: u64 = 1_700_000_000;

    // ======================== Helper Functions ===============================

    /// Bootstraps a scenario: ADMIN creates the WorkerRegistry and AdminRegistry.
    fun setup_registry(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            worker_registry::init_for_testing(ts::ctx(scenario));
            admin_registry::init_for_testing(ts::ctx(scenario));
        };
    }

    /// Register a (wallet, node_id) with default capabilities.
    /// Caller must have already called `ts::next_tx(scenario, ADMIN)`.
    fun register_node(scenario: &mut Scenario, wallet: address, node_id: vector<u8>) {
        let mut registry = ts::take_shared<WorkerRegistry>(scenario);
        let admin_reg = ts::take_shared<AdminRegistry>(scenario);
        worker_registry::register(
            &mut registry,
            &admin_reg,
            wallet,
            node_id,
            GPU_TYPE,
            GPU_MODEL_HASH,
            GPU_MEMORY_GB,
            CPU_CORES,
            PROCESSING_TYPE,
            SUPPORTED_CODECS,
            MAX_CONCURRENT,
            REGION,
            TIMESTAMP,
            ts::ctx(scenario),
        );
        ts::return_shared(registry);
        ts::return_shared(admin_reg);
    }

    /// Look up the on-chain Worker object ID for (wallet, node_id) via the
    /// registry. Used by tests that share a wallet across multiple nodes so
    /// the scenario knows which Worker to take_shared_by_id.
    fun lookup_worker_id(
        scenario: &Scenario,
        wallet: address,
        node_id: vector<u8>,
    ): sui::object::ID {
        let registry = ts::take_shared<WorkerRegistry>(scenario);
        let id = worker_registry::get_worker_id(&registry, wallet, node_id);
        ts::return_shared(registry);
        id
    }

    // ========================== Test Cases ===================================

    // -----------------------------------------------------------------
    // 1. Register a worker -- starts inactive, tier none, reputation 50
    // -----------------------------------------------------------------
    #[test]
    fun test_register_worker() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // Admin registers WORKER1's first node
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Verify worker state
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let worker = ts::take_shared<Worker>(&scenario);

            assert!(worker_registry::total_workers(&registry) == 1, 0);
            assert!(worker_registry::active_workers(&registry) == 0, 1);
            assert!(worker_registry::is_registered(&registry, WORKER1), 2);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_a()), 3);

            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_none(), 4);
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_inactive(), 5);
            assert!(worker_registry::worker_reputation(&worker) == 50, 6);
            assert!(worker_registry::worker_jobs_completed(&worker) == 0, 7);
            assert!(worker_registry::worker_minutes_processed(&worker) == 0, 8);
            assert!(worker_registry::worker_total_earnings(&worker) == 0, 9);
            assert!(worker_registry::worker_wallet(&worker) == WORKER1, 10);

            ts::return_shared(registry);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 2. Cannot register the same (wallet, node_id) twice
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EWorkerAlreadyRegistered)]
    fun test_cannot_register_same_wallet_node_twice() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // First registration succeeds
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Same (wallet, node_id) again must abort
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 2b. Same wallet, different node_id is fine (multi-node-per-wallet)
    // -----------------------------------------------------------------
    #[test]
    fun test_register_same_wallet_different_nodes() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_b());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            assert!(worker_registry::total_workers(&registry) == 2, 0);
            assert!(worker_registry::is_registered(&registry, WORKER1), 1);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_a()), 2);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_b()), 3);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 3. update_worker_tier auto-activates at Bronze threshold
    // -----------------------------------------------------------------
    #[test]
    fun test_update_tier_auto_activates_at_bronze() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Admin verifies balance at Bronze threshold
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_worker_tier(
                &mut registry,
                &admin_reg,
                &mut worker,
                BRONZE_REQUIREMENT,
                TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_bronze(), 0);
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_active(), 1);
            assert!(worker_registry::active_workers(&registry) == 1, 2);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 4. update_worker_tier auto-deactivates when balance drops to TIER_NONE
    // -----------------------------------------------------------------
    #[test]
    fun test_update_tier_auto_deactivates_at_none() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate first
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_worker_tier(
                &mut registry,
                &admin_reg,
                &mut worker,
                BRONZE_REQUIREMENT,
                TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_status(&worker) == worker_registry::status_active(), 0);
            assert!(worker_registry::active_workers(&registry) == 1, 1);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Now balance drops to zero -> auto-deactivate
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_worker_tier(
                &mut registry,
                &admin_reg,
                &mut worker,
                0, // balance dropped
                TIMESTAMP + 7200,
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_none(), 2);
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_inactive(), 3);
            assert!(worker_registry::active_workers(&registry) == 0, 4);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 5a. record_job_completion: success adds +1 reputation
    // -----------------------------------------------------------------
    #[test]
    fun test_record_job_success_increases_reputation() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Record a successful job
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::record_job_completion(
                &registry,
                &admin_reg,
                &mut worker,
                10,     // minutes
                1000,   // earnings
                true,   // success
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_reputation(&worker) == 51, 0); // 50 + 1
            assert!(worker_registry::worker_jobs_completed(&worker) == 1, 1);
            assert!(worker_registry::worker_minutes_processed(&worker) == 10, 2);
            assert!(worker_registry::worker_total_earnings(&worker) == 1000, 3);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 5b. record_job_completion: failure subtracts 5 reputation
    // -----------------------------------------------------------------
    #[test]
    fun test_record_job_failure_decreases_reputation() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::record_job_completion(
                &registry,
                &admin_reg,
                &mut worker,
                5, 0, false,
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_reputation(&worker) == 45, 0); // 50 - 5
            assert!(worker_registry::worker_jobs_completed(&worker) == 1, 1);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 5c. record_job_completion: reputation saturates at 0
    // -----------------------------------------------------------------
    #[test]
    fun test_record_job_failure_reputation_saturates_at_zero() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Drive reputation from 50 down to 0 across 10 failures, then one more.
        let mut i = 0;
        while (i < 10) {
            ts::next_tx(&mut scenario, ADMIN);
            {
                let registry = ts::take_shared<WorkerRegistry>(&scenario);
                let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
                let mut worker = ts::take_shared<Worker>(&scenario);

                worker_registry::record_job_completion(
                    &registry, &admin_reg, &mut worker,
                    1, 0, false,
                    ts::ctx(&mut scenario),
                );

                ts::return_shared(registry);
                ts::return_shared(admin_reg);
                ts::return_shared(worker);
            };
            i = i + 1;
        };

        // Reputation is now 0. One more failure must stay at 0, not underflow.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::record_job_completion(
                &registry, &admin_reg, &mut worker,
                1, 0, false,
                ts::ctx(&mut scenario),
            );

            assert!(worker_registry::worker_reputation(&worker) == 0, 0);
            assert!(worker_registry::worker_jobs_completed(&worker) == 11, 1);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 6. suspend_worker rejects already-suspended workers
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EInvalidStatusTransition)]
    fun test_suspend_already_suspended_worker_fails() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate so we can suspend from a valid state
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // First suspend succeeds
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Second suspend must abort
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 7. suspend_worker rejects banned workers
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EInvalidStatusTransition)]
    fun test_suspend_banned_worker_fails() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Ban the worker first
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Now trying to suspend the banned worker must abort
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 8. ban_worker sets BANNED status and populates banned table
    // -----------------------------------------------------------------
    #[test]
    fun test_ban_worker_sets_status_and_populates_banned_table() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate first
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            assert!(worker_registry::active_workers(&registry) == 1, 0);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Ban the active worker
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            assert!(worker_registry::worker_status(&worker) == worker_registry::status_banned(), 1);
            assert!(worker_registry::is_banned(&registry, WORKER1), 2);
            assert!(worker_registry::active_workers(&registry) == 0, 3);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 8b. Banning ONE node of a wallet blocks all NEW registrations for
    //     that wallet (the ban is wallet-level)
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EWorkerBanned)]
    fun test_ban_one_node_blocks_new_registrations_for_wallet() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // Register node_a only; ban it
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Trying to register node_b under the same banned wallet must abort
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_b());

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 9. Banned wallet cannot re-register after deregister
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EWorkerBanned)]
    fun test_banned_worker_cannot_reregister() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Ban
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Admin deregisters the banned Worker object
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let worker = ts::take_shared<Worker>(&scenario);
            worker_registry::deregister(&mut registry, &admin_reg, worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
        };

        // Re-registration must abort EWorkerBanned
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 10a. reactivate_worker requires SUSPENDED status
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EWorkerNotRegistered)]
    fun test_reactivate_requires_suspended_status() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate the worker (status = ACTIVE, not SUSPENDED)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Attempting to reactivate an ACTIVE worker must fail
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::reactivate_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 10b. reactivate_worker requires tier >= BRONZE
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EInvalidTier)]
    fun test_reactivate_requires_bronze_tier() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Suspend an inactive worker (INACTIVE -> SUSPENDED is valid)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            assert!(worker_registry::worker_status(&worker) == worker_registry::status_suspended(), 0);
            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_none(), 1);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Reactivation must fail because tier < BRONZE
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::reactivate_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 10c. reactivate_worker succeeds when suspended + tier >= BRONZE
    // -----------------------------------------------------------------
    #[test]
    fun test_reactivate_suspended_worker_with_bronze_tier() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate at Bronze
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Suspend
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_suspended(), 0);
            assert!(worker_registry::active_workers(&registry) == 0, 1);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Reactivate
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::reactivate_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_active(), 2);
            assert!(worker_registry::active_workers(&registry) == 1, 3);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 11. deregister by admin (only path in v2)
    // -----------------------------------------------------------------
    #[test]
    fun test_deregister_by_admin() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate so we exercise the active_workers decrement path
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            assert!(worker_registry::active_workers(&registry) == 1, 0);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Admin deregisters; wallet's last Worker => inner table dropped
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let worker = ts::take_shared<Worker>(&scenario);
            worker_registry::deregister(&mut registry, &admin_reg, worker, ts::ctx(&mut scenario));

            assert!(worker_registry::total_workers(&registry) == 0, 1);
            assert!(worker_registry::active_workers(&registry) == 0, 2);
            assert!(!worker_registry::is_registered(&registry, WORKER1), 3);
            assert!(!worker_registry::is_node_registered(&registry, WORKER1, node_a()), 4);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 11b. Deregistering ONE node of a multi-node wallet leaves the other
    //      node registered (inner table not dropped).
    // -----------------------------------------------------------------
    #[test]
    fun test_deregister_one_of_two_nodes_keeps_wallet_inner_table() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // Register two nodes for WORKER1
        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_b());

        // Look up node_a's Worker ID so we know which one to deregister
        ts::next_tx(&mut scenario, ADMIN);
        let node_a_id = lookup_worker_id(&scenario, WORKER1, node_a());

        // Deregister just node_a
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let worker = ts::take_shared_by_id<Worker>(&scenario, node_a_id);
            worker_registry::deregister(&mut registry, &admin_reg, worker, ts::ctx(&mut scenario));

            assert!(worker_registry::total_workers(&registry) == 1, 0);
            assert!(worker_registry::is_registered(&registry, WORKER1), 1);
            assert!(!worker_registry::is_node_registered(&registry, WORKER1, node_a()), 2);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_b()), 3);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 12. Non-admin cannot register
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_register() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // WORKER1 tries to register themselves -- must fail (v2 admin-gated)
        ts::next_tx(&mut scenario, WORKER1);
        register_node(&mut scenario, WORKER1, node_a());

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 13a. Non-admin cannot call update_worker_tier
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_update_tier() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // WORKER1 tries to update their own tier -- must fail
        ts::next_tx(&mut scenario, WORKER1);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 13b. Non-admin cannot call record_job_completion
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_record_job() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, WORKER1);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::record_job_completion(
                &registry, &admin_reg, &mut worker,
                10, 1000, true,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 13c. Non-admin cannot call suspend_worker
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_suspend() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, WORKER2);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 13d. Non-admin cannot call ban_worker
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_ban() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, WORKER2);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 13e. Non-admin (even the worker's own wallet) cannot deregister
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_deregister() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // The owning wallet itself tries to deregister -- must fail in v2
        ts::next_tx(&mut scenario, WORKER1);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let worker = ts::take_shared<Worker>(&scenario);
            worker_registry::deregister(&mut registry, &admin_reg, worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 14. Suspend an inactive worker (valid transition: INACTIVE -> SUSPENDED)
    // -----------------------------------------------------------------
    #[test]
    fun test_suspend_inactive_worker() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));

            assert!(worker_registry::worker_status(&worker) == worker_registry::status_suspended(), 0);
            assert!(worker_registry::active_workers(&registry) == 0, 1);

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 15. Tier upgrade to Silver
    // -----------------------------------------------------------------
    #[test]
    fun test_tier_upgrade_to_silver() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                SILVER_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_silver(), 0);
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_active(), 1);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 16. ban_worker rejects already-banned workers
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EInvalidStatusTransition)]
    fun test_ban_already_banned_worker_fails() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::ban_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 17. Admin can update capabilities (v2 — agent has no wallet key)
    // -----------------------------------------------------------------
    #[test]
    fun test_admin_can_update_capabilities() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);

            worker_registry::update_capabilities(
                &registry,
                &admin_reg,
                &mut worker,
                2,          // AMD GPU
                0xDEAD,     // new model hash
                48,         // 48 GB
                32,         // 32 cores
                1,          // GPU processing
                0x0B,       // H264 + HEVC + AV1
                8,          // max concurrent
                2,          // new region
                ts::ctx(&mut scenario),
            );

            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 18. Non-admin cannot update_capabilities
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_non_admin_cannot_update_capabilities() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Even the worker's own wallet (WORKER1) cannot do this in v2
        ts::next_tx(&mut scenario, WORKER1);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_capabilities(
                &registry, &admin_reg, &mut worker,
                2, 0xDEAD, 48, 32, 1, 0x0B, 8, 2,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 19. Multiple workers can register independently
    // -----------------------------------------------------------------
    #[test]
    fun test_multiple_workers_register() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER2, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            assert!(worker_registry::total_workers(&registry) == 2, 0);
            assert!(worker_registry::is_registered(&registry, WORKER1), 1);
            assert!(worker_registry::is_registered(&registry, WORKER2), 2);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 20. Suspend active worker decrements active_workers
    // -----------------------------------------------------------------
    #[test]
    fun test_suspend_active_worker_decrements_active_count() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            assert!(worker_registry::active_workers(&registry) == 1, 0);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_suspended(), 1);
            assert!(worker_registry::active_workers(&registry) == 0, 2);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 21. Suspended worker's tier update does NOT change status
    // -----------------------------------------------------------------
    #[test]
    fun test_tier_update_does_not_affect_suspended_worker_status() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        // Activate at Bronze
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                BRONZE_REQUIREMENT, TIMESTAMP + 3600,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Suspend
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::suspend_worker(&mut registry, &admin_reg, &mut worker, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        // Update tier to Silver -- status must stay SUSPENDED
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = ts::take_shared<WorkerRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut worker = ts::take_shared<Worker>(&scenario);
            worker_registry::update_worker_tier(
                &mut registry, &admin_reg, &mut worker,
                SILVER_REQUIREMENT, TIMESTAMP + 10800,
                ts::ctx(&mut scenario),
            );
            assert!(worker_registry::worker_tier(&worker) == worker_registry::tier_silver(), 0);
            assert!(worker_registry::worker_status(&worker) == worker_registry::status_suspended(), 1);
            assert!(worker_registry::active_workers(&registry) == 0, 2);
            ts::return_shared(registry);
            ts::return_shared(admin_reg);
            ts::return_shared(worker);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 22. is_node_registered + get_worker_id round-trip on multi-node wallet
    // -----------------------------------------------------------------
    #[test]
    fun test_node_lookup_helpers() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        register_node(&mut scenario, WORKER1, node_b());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);

            // Both nodes are findable, third node is not
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_a()), 0);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_b()), 1);
            assert!(!worker_registry::is_node_registered(&registry, WORKER1, b"node-missing"), 2);
            // Unknown wallet returns false without aborting
            assert!(!worker_registry::is_node_registered(&registry, WORKER2, node_a()), 3);
            assert!(!worker_registry::is_registered(&registry, WORKER2), 4);

            let id_a = worker_registry::get_worker_id(&registry, WORKER1, node_a());
            let id_b = worker_registry::get_worker_id(&registry, WORKER1, node_b());
            assert!(id_a != id_b, 5);

            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // 23. get_worker_id aborts for unknown wallet
    // -----------------------------------------------------------------
    #[test]
    #[expected_failure(abort_code = worker_registry::EWorkerNotRegistered)]
    fun test_get_worker_id_aborts_for_unknown_wallet() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            let _id = worker_registry::get_worker_id(&registry, WORKER1, node_a());
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------
    // Orchestrator role: the orchestrator registers workers as a least-
    // privilege ORCHESTRATOR, not as an admin.
    // -----------------------------------------------------------------

    /// The super admin promotes ORCHESTRATOR into the orchestrator set.
    fun grant_orchestrator(scenario: &mut Scenario, who: address) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut admin_reg = ts::take_shared<AdminRegistry>(scenario);
            let mut clk = clock::create_for_testing(ts::ctx(scenario));
            clock::set_for_testing(&mut clk, 1000);
            admin_registry::add_orchestrator(&mut admin_reg, who, &clk, ts::ctx(scenario));
            clock::destroy_for_testing(clk);
            ts::return_shared(admin_reg);
        };
    }

    #[test]
    fun test_orchestrator_can_register_worker() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);
        grant_orchestrator(&mut scenario, ORCHESTRATOR);

        // ORCHESTRATOR (not an admin) registers WORKER1 -- the orchestrator's path.
        ts::next_tx(&mut scenario, ORCHESTRATOR);
        register_node(&mut scenario, WORKER1, node_a());

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<WorkerRegistry>(&scenario);
            assert!(worker_registry::is_registered(&registry, WORKER1), 0);
            assert!(worker_registry::is_node_registered(&registry, WORKER1, node_a()), 1);
            ts::return_shared(registry);
        };

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = worker_registry::ENotAdmin)]
    fun test_stranger_cannot_register_worker() {
        let mut scenario = ts::begin(ADMIN);
        setup_registry(&mut scenario);

        // STRANGER is neither admin nor orchestrator -- register must abort.
        ts::next_tx(&mut scenario, STRANGER);
        register_node(&mut scenario, WORKER1, node_a());

        ts::end(scenario);
    }
}
