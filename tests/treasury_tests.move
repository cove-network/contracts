#[test_only]
module cove::treasury_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};
    use cove::treasury::{Self, Treasury, VestingSchedule, VestingRegistry};
    use cove::cove_token::{Self, COVE_TOKEN};
    use cove::admin_registry::{Self, AdminRegistry};

    // ─── Addresses ──────────────────────────────────────────────────────────

    const ADMIN: address = @0xAD;
    const USER1: address = @0x1;
    const USER2: address = @0x2;
    /// The orchestrator's least-privilege role -- may withdraw community
    /// rewards for worker bonuses, but NOT touch any other treasury pool.
    const ORCHESTRATOR: address = @0x0B;

    // ─── Pool allocations (9 decimals) ──────────────────────────────────────

    const PRESALE_AMOUNT:   u64 = 2_500_000_000_000_000_000; // 2.5B
    const TEAM_AMOUNT:      u64 = 2_500_000_000_000_000_000; // 2.5B
    const LIQUIDITY_AMOUNT: u64 = 3_000_000_000_000_000_000; // 3.0B
    const COMMUNITY_AMOUNT: u64 = 1_000_000_000_000_000_000; // 1.0B
    const RESERVE_AMOUNT:   u64 = 1_000_000_000_000_000_000; // 1.0B

    // ─── Cap defaults (must match treasury.move constants) ──────────────────

    const DEFAULT_CAP_WINDOW_MS:  u64 = 86_400_000;
    const DEFAULT_PRESALE_CAP:    u64 = 1_000_000_000_000;       // 1k COVE
    const DEFAULT_COMMUNITY_CAP:  u64 = 100_000_000_000_000;     // 100k COVE
    const DEFAULT_LIQUIDITY_CAP:  u64 = 10_000_000_000_000;      // 10k COVE
    const DEFAULT_RESERVE_CAP:    u64 = 1_000_000_000_000;       // 1k COVE
    const DEFAULT_FEE_CAP:        u64 = 50_000_000_000_000;      // 50k COVE

    // ─── Vesting timing ─────────────────────────────────────────────────────

    const ONE_YEAR_MS:   u64 = 31_536_000_000;
    const FOUR_YEARS_MS: u64 = 126_230_400_000;

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// Bring up a fully-initialized treasury. Caller continues from the
    /// next ts::next_tx after this returns.
    fun setup_initialized_treasury(): Scenario {
        let mut scenario = ts::begin(ADMIN);

        ts::next_tx(&mut scenario, ADMIN);
        {
            cove_token::init_for_testing(ts::ctx(&mut scenario));
            admin_registry::init_for_testing(ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury_cap = ts::take_from_sender<TreasuryCap<COVE_TOKEN>>(&scenario);
            treasury::create_treasury(treasury_cap, ts::ctx(&mut scenario));
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::initialize_distribution(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };

        scenario
    }

    /// Raise the cap for one pool to a huge value so the test can withdraw
    /// freely without fighting the default tight caps. Super-admin only.
    fun raise_all_caps(scenario: &mut Scenario, ts_ms: u64) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(scenario);
            let mut clock = clock::create_for_testing(ts::ctx(scenario));
            clock::set_for_testing(&mut clock, ts_ms);

            let huge: u64 = 10_000_000_000_000_000_000; // 10B — bigger than any pool

            treasury::set_presale_cap   (&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(scenario));
            treasury::set_community_cap (&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(scenario));
            treasury::set_liquidity_cap (&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(scenario));
            treasury::set_reserve_cap   (&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(scenario));
            treasury::set_fee_cap       (&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(scenario));

            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
    }

    // ════════════════════════════════════════════════════════════════════════
    //   Distribution / supply
    // ════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_initialize_distribution_v07_pool_amounts() {
        let mut scenario = setup_initialized_treasury();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);

            assert!(treasury::is_initialized(&treasury), 100);
            assert!(treasury::presale_pool_balance(&treasury) == PRESALE_AMOUNT, 101);
            assert!(treasury::team_pool_balance(&treasury) == TEAM_AMOUNT, 102);
            assert!(treasury::liquidity_pool_balance(&treasury) == LIQUIDITY_AMOUNT, 103);
            assert!(treasury::community_pool_balance(&treasury) == COMMUNITY_AMOUNT, 104);
            assert!(treasury::reserve_pool_balance(&treasury) == RESERVE_AMOUNT, 105);
            assert!(treasury::fee_pool_balance(&treasury) == 0, 106);

            // Sum to exactly 10B (no public_sale anymore).
            let total = PRESALE_AMOUNT + TEAM_AMOUNT + LIQUIDITY_AMOUNT
                + COMMUNITY_AMOUNT + RESERVE_AMOUNT;
            assert!(total == 10_000_000_000_000_000_000, 107);

            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidAmount)]
    fun test_cannot_initialize_twice() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::initialize_distribution(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ENotAdmin)]
    fun test_non_admin_cannot_initialize() {
        let mut scenario = ts::begin(ADMIN);
        ts::next_tx(&mut scenario, ADMIN);
        {
            cove_token::init_for_testing(ts::ctx(&mut scenario));
            admin_registry::init_for_testing(ts::ctx(&mut scenario));
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<TreasuryCap<COVE_TOKEN>>(&scenario);
            treasury::create_treasury(cap, ts::ctx(&mut scenario));
        };
        // USER1 tries to initialize — should abort.
        ts::next_tx(&mut scenario, USER1);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::initialize_distribution(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_lock_supply_freezes_cap() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            assert!(!treasury::is_supply_locked(&treasury), 110);
            treasury::lock_supply(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            assert!(treasury::is_supply_locked(&treasury), 111);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ESupplyAlreadyLocked)]
    fun test_lock_supply_twice_aborts() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::lock_supply(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            treasury::lock_supply(&mut treasury, &admin_reg, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════════════════
    //   Vesting
    // ════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_create_team_vesting_locks_tokens() {
        let mut scenario = setup_initialized_treasury();
        let amount: u64 = 1_000_000_000_000_000_000; // 1B
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut registry = ts::take_shared<VestingRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let team_before = treasury::team_pool_balance(&treasury);
            treasury::create_team_vesting(
                &mut treasury, &mut registry, &admin_reg,
                USER1, amount, ONE_YEAR_MS, &clock, ts::ctx(&mut scenario),
            );
            assert!(treasury::team_pool_balance(&treasury) == team_before - amount, 200);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(registry);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EVestingNotStarted)]
    fun test_release_before_cliff_aborts() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut registry = ts::take_shared<VestingRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 0);
            treasury::create_team_vesting(
                &mut treasury, &mut registry, &admin_reg,
                USER1, 1_000_000_000_000_000_000, ONE_YEAR_MS, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(registry);
            ts::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        ts::next_tx(&mut scenario, USER1);
        {
            let mut schedule = ts::take_shared<VestingSchedule>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, ONE_YEAR_MS / 2); // before cliff
            treasury::release_vested_tokens(&mut schedule, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(schedule);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_release_after_full_vesting_releases_all() {
        let mut scenario = setup_initialized_treasury();
        let amount: u64 = 1_000_000_000_000_000_000; // 1B
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut registry = ts::take_shared<VestingRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 0);
            treasury::create_team_vesting(
                &mut treasury, &mut registry, &admin_reg,
                USER1, amount, ONE_YEAR_MS, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(registry);
            ts::return_shared(treasury);
            clock::destroy_for_testing(clock);
        };
        ts::next_tx(&mut scenario, USER1);
        {
            let mut schedule = ts::take_shared<VestingSchedule>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, FOUR_YEARS_MS + 1); // past full vest
            treasury::release_vested_tokens(&mut schedule, &clock, ts::ctx(&mut scenario));
            assert!(treasury::vesting_schedule_released(&schedule) == amount, 210);
            clock::destroy_for_testing(clock);
            ts::return_shared(schedule);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EVestingAlreadyExists)]
    fun test_one_schedule_per_beneficiary() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let mut registry = ts::take_shared<VestingRegistry>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::create_team_vesting(
                &mut treasury, &mut registry, &admin_reg,
                USER1, 1_000_000_000_000, ONE_YEAR_MS, &clock, ts::ctx(&mut scenario),
            );
            treasury::create_team_vesting(
                &mut treasury, &mut registry, &admin_reg,
                USER1, 1_000_000_000_000, ONE_YEAR_MS, &clock, ts::ctx(&mut scenario),
            );
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(registry);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════════════════
    //   Withdrawal caps
    // ════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_withdraw_within_cap_succeeds() {
        let mut scenario = setup_initialized_treasury();
        // Withdraw 50k from community pool — well within the 100k default cap.
        let amount: u64 = 50_000_000_000_000;
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let coin = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            assert!(coin::value(&coin) == amount, 300);
            // Window used should now equal amount.
            let (_, _, used) = treasury::cap_status(&treasury, b"community");
            assert!(used == amount, 301);
            transfer::public_transfer(coin, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // The orchestrator (an ORCHESTRATOR, not an admin) pays worker bonuses from the
    // community pool. It must be able to call withdraw_community_rewards...
    #[test]
    fun test_orchestrator_can_withdraw_community_rewards() {
        let mut scenario = setup_initialized_treasury();
        let amount: u64 = 50_000_000_000_000; // 50k, within the 100k cap

        // Super admin promotes ORCHESTRATOR into the orchestrator set.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);
            admin_registry::add_orchestrator(&mut admin_reg, ORCHESTRATOR, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
        };

        ts::next_tx(&mut scenario, ORCHESTRATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let coin = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            assert!(coin::value(&coin) == amount, 0);
            transfer::public_transfer(coin, ORCHESTRATOR);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // ...but it must NOT be able to touch any OTHER pool. Least privilege: an
    // orchestrator pulling from the liquidity pool aborts ENotAdmin.
    #[test]
    #[expected_failure(abort_code = treasury::ENotAdmin)]
    fun test_orchestrator_cannot_withdraw_other_pools() {
        let mut scenario = setup_initialized_treasury();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);
            admin_registry::add_orchestrator(&mut admin_reg, ORCHESTRATOR, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
        };

        ts::next_tx(&mut scenario, ORCHESTRATOR);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            // Liquidity pool is admin-only -- orchestrator has no business here.
            let coin = treasury::withdraw_liquidity(
                &mut treasury, &admin_reg, 1_000_000_000, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin, ORCHESTRATOR);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EAdminWithdrawalCapExceeded)]
    fun test_withdraw_exceeding_cap_aborts() {
        let mut scenario = setup_initialized_treasury();
        // Try to pull 200k from community pool — 2× the 100k default cap.
        let amount: u64 = 200_000_000_000_000;
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let coin = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_multiple_withdrawals_accumulate_against_cap() {
        let mut scenario = setup_initialized_treasury();
        let amount: u64 = 40_000_000_000_000; // 40k each — two = 80k under 100k cap
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c1 = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            let c2 = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            let (_, _, used) = treasury::cap_status(&treasury, b"community");
            assert!(used == 2 * amount, 310);
            transfer::public_transfer(c1, ADMIN);
            transfer::public_transfer(c2, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EAdminWithdrawalCapExceeded)]
    fun test_second_withdrawal_crosses_cap_aborts() {
        let mut scenario = setup_initialized_treasury();
        let big: u64 = 60_000_000_000_000; // 60k each — two = 120k > 100k cap
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c1 = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, big, &clock, ts::ctx(&mut scenario),
            );
            // Second withdrawal pushes us over — aborts.
            let c2 = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, big, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(c1, ADMIN);
            transfer::public_transfer(c2, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_window_rolls_after_expiry() {
        let mut scenario = setup_initialized_treasury();
        let amount: u64 = 80_000_000_000_000; // 80k — under cap

        // First withdrawal at t=0.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 0);
            let c = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(c, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };

        // Second withdrawal 25 hours later — window rolled, fresh 100k available.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, DEFAULT_CAP_WINDOW_MS + 3_600_000); // 25h
            let c = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            // After the roll, used should equal just this latest withdrawal.
            let (_, _, used) = treasury::cap_status(&treasury, b"community");
            assert!(used == amount, 320);
            transfer::public_transfer(c, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EAdminWithdrawalsPaused)]
    fun test_cap_zero_pauses_withdrawals() {
        let mut scenario = setup_initialized_treasury();
        // Super-admin sets cap to 0 (pause).
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::set_community_cap(&mut treasury, &admin_reg, 0, 0, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        // Any withdrawal now aborts.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, 1, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(c, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_super_admin_can_raise_cap() {
        let mut scenario = setup_initialized_treasury();
        let huge: u64 = 500_000_000_000_000_000; // 500M — way over default

        // Raise cap.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::set_presale_cap(&mut treasury, &admin_reg, huge, 0, &clock, ts::ctx(&mut scenario));
            let (cap, _, used) = treasury::cap_status(&treasury, b"presale");
            assert!(cap == huge, 330);
            assert!(used == 0, 331); // counter reset on cap change
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };

        // Now a big withdrawal succeeds (would have aborted at default 1k cap).
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c = treasury::withdraw_presale(
                &mut treasury, &admin_reg, 100_000_000_000_000_000, &clock, ts::ctx(&mut scenario),
            );
            assert!(coin::value(&c) == 100_000_000_000_000_000, 332);
            transfer::public_transfer(c, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::ENotSuperAdmin)]
    fun test_regular_admin_cannot_change_cap() {
        let mut scenario = setup_initialized_treasury();

        // Make USER1 a regular admin.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            admin_registry::add_admin(&mut admin_reg, USER1, b"user1", &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
        };

        // USER1 (regular admin, not super) tries to change cap — aborts.
        ts::next_tx(&mut scenario, USER1);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            treasury::set_community_cap(&mut treasury, &admin_reg, 1, 0, &clock, ts::ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_default_cap_constants_match_module() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let treasury = ts::take_shared<Treasury>(&scenario);
            assert!(treasury::admin_window_ms(&treasury) == DEFAULT_CAP_WINDOW_MS, 340);
            let (presale_cap, _, _) = treasury::cap_status(&treasury, b"presale");
            assert!(presale_cap == DEFAULT_PRESALE_CAP, 341);
            let (community_cap, _, _) = treasury::cap_status(&treasury, b"community");
            assert!(community_cap == DEFAULT_COMMUNITY_CAP, 342);
            let (liquidity_cap, _, _) = treasury::cap_status(&treasury, b"liquidity");
            assert!(liquidity_cap == DEFAULT_LIQUIDITY_CAP, 343);
            let (reserve_cap, _, _) = treasury::cap_status(&treasury, b"reserve");
            assert!(reserve_cap == DEFAULT_RESERVE_CAP, 344);
            let (fee_cap, _, _) = treasury::cap_status(&treasury, b"fee");
            assert!(fee_cap == DEFAULT_FEE_CAP, 345);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════════════════
    //   Inflows (NOT capped)
    // ════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_add_to_community_pool_inflow() {
        let mut scenario = setup_initialized_treasury();
        // Raise caps so we can pull from presale, then return it as a community add.
        raise_all_caps(&mut scenario, 1);

        let amount: u64 = 100_000_000_000_000_000; // 100M

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            let community_before = treasury::community_pool_balance(&treasury);

            // Pull a chunk from presale (caps raised so this works).
            let coin = treasury::withdraw_presale(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            // Now deposit it into community pool — no cap, inflow.
            treasury::add_to_community_pool(&mut treasury, &admin_reg, coin, ts::ctx(&mut scenario));

            assert!(
                treasury::community_pool_balance(&treasury) == community_before + amount,
                400,
            );

            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_deposit_fees() {
        let mut scenario = setup_initialized_treasury();
        raise_all_caps(&mut scenario, 1);
        let amount: u64 = 10_000_000_000_000_000; // 10M

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));

            // Pull fees-shaped balance from presale (any source coin works for this test).
            let coin = treasury::withdraw_presale(
                &mut treasury, &admin_reg, amount, &clock, ts::ctx(&mut scenario),
            );
            treasury::deposit_fees(&mut treasury, coin, &clock, ts::ctx(&mut scenario));
            assert!(treasury::fee_pool_balance(&treasury) == amount, 401);

            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    // ════════════════════════════════════════════════════════════════════════
    //   Negative paths
    // ════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = treasury::ENotAdmin)]
    fun test_non_admin_cannot_withdraw_community() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, USER2);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, 1, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(c, USER2);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = treasury::EInvalidAmount)]
    fun test_withdraw_zero_amount_aborts() {
        let mut scenario = setup_initialized_treasury();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut treasury = ts::take_shared<Treasury>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let clock = clock::create_for_testing(ts::ctx(&mut scenario));
            let c = treasury::withdraw_community_rewards(
                &mut treasury, &admin_reg, 0, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(c, ADMIN);
            clock::destroy_for_testing(clock);
            ts::return_shared(admin_reg);
            ts::return_shared(treasury);
        };
        ts::end(scenario);
    }

    #[test]
    fun test_calculate_platform_fee() {
        // 2.5% of 10,000 base units = 250 base units.
        assert!(treasury::calculate_platform_fee(10_000) == 250, 500);
        // Large amount sanity check — no u64 overflow due to u128 intermediate.
        assert!(treasury::calculate_platform_fee(1_000_000_000_000_000_000) == 25_000_000_000_000_000, 501);
    }
}
