#[test_only]
module cove::pool_escrow_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};

    use cove::cove_token::{Self, COVE_TOKEN};
    use cove::pool_escrow::{Self, EscrowPool, SettlementBatch};
    use cove::admin_registry::{Self, AdminRegistry};

    // =========================================================================
    // Constants
    // =========================================================================

    const ADMIN: address = @0xAD;
    const CLIENT1: address = @0x1;
    const WORKER1: address = @0x2;
    const CLIENT2: address = @0x3;
    const WORKER2: address = @0x4;
    const NON_ADMIN: address = @0x99;
    const ORCH: address = @0x055; // orchestrator (least-privilege settlement key)

    /// Platform fee: 250 bps = 2.5%.
    const PLATFORM_FEE_BPS: u64 = 250;
    const BPS_DENOMINATOR: u64 = 10000;

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Bootstrap: initialize COVE token, AdminRegistry, and EscrowPool modules, all as ADMIN.
    fun setup_test(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        // Init the COVE coin type (creates TreasuryCap sent to ADMIN).
        cove_token::init_for_testing(ts::ctx(&mut scenario));
        // Init the AdminRegistry (shares the registry, super_admin = ADMIN).
        admin_registry::init_for_testing(ts::ctx(&mut scenario));
        // Init the EscrowPool (shares the pool).
        pool_escrow::init_for_testing(ts::ctx(&mut scenario));
        scenario
    }

    /// Mint `amount` of COVE as a Coin object, using ADMIN's TreasuryCap.
    /// Must be called inside a transaction where ADMIN is the sender.
    fun mint_cove(scenario: &mut Scenario, amount: u64): Coin<COVE_TOKEN> {
        let mut cap = ts::take_from_sender<TreasuryCap<COVE_TOKEN>>(scenario);
        let coin = coin::mint(&mut cap, amount, ts::ctx(scenario));
        ts::return_to_sender(scenario, cap);
        coin
    }

    /// Create a Clock at timestamp 0 for testing.
    fun create_clock(scenario: &mut Scenario): Clock {
        clock::create_for_testing(ts::ctx(scenario))
    }

    // =========================================================================
    // 1. Deposit increases client balance and pool balance
    // =========================================================================

    #[test]
    fun test_deposit_increases_balances() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Admin mints COVE and transfers to CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 1000);
            transfer::public_transfer(coin, CLIENT1);
        };

        // CLIENT1 deposits 1000 into the pool.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);

            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));

            // Verify client ledger balance.
            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 1000, 0);
            // Verify aggregate pool balance.
            assert!(pool_escrow::pool_balance(&pool) == 1000, 1);
            // Verify lifetime stats.
            assert!(pool_escrow::total_deposited(&pool) == 1000, 2);

            ts::return_shared(pool);
        };

        // CLIENT1 deposits again (additive).
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 500);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);

            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));

            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 1500, 3);
            assert!(pool_escrow::pool_balance(&pool) == 1500, 4);
            assert!(pool_escrow::total_deposited(&pool) == 1500, 5);

            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 2. Withdraw returns coins and decreases balance
    // =========================================================================

    #[test]
    fun test_withdraw_decreases_balance() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Mint and send COVE to CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 1000);
            transfer::public_transfer(coin, CLIENT1);
        };

        // CLIENT1 deposits.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // CLIENT1 withdraws 400.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            pool_escrow::withdraw(&mut pool, 400, &clock, ts::ctx(&mut scenario));

            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 600, 0);
            assert!(pool_escrow::pool_balance(&pool) == 600, 1);
            assert!(pool_escrow::total_withdrawn(&pool) == 400, 2);

            ts::return_shared(pool);
        };

        // Verify CLIENT1 received the withdrawn coin.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let coin = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            assert!(coin::value(&coin) == 400, 3);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 3. Withdraw blocked during settlement (ESettlementInProgress)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::ESettlementInProgress)]
    fun test_withdraw_blocked_during_settlement() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Mint and deposit for CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 1000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Admin starts settlement, transferring batch to ADMIN using the test helper.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::transfer_batch_for_testing(batch, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // CLIENT1 tries to withdraw -- should abort with ESettlementInProgress.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            pool_escrow::withdraw(&mut pool, 100, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 4. Full settlement cycle: start -> deduct -> pay_worker -> finalize
    // =========================================================================

    #[test]
    fun test_full_settlement_cycle() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund CLIENT1 with 10000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Run full settlement in one transaction.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::is_settlement_in_progress(&pool), 0);
            assert!(pool_escrow::current_cycle(&pool) == 1, 1);

            // Pay WORKER1 gross 4000 (fee = 4000*250/10000 = 100, net = 3900).
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 4000, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::batch_total_paid(&batch) == 3900, 4);
            assert!(pool_escrow::batch_fees_collected(&batch) == 100, 5);
            assert!(pool_escrow::batch_workers_paid(&batch) == 1, 6);

            // Finalize.
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );

            assert!(!pool_escrow::is_settlement_in_progress(&pool), 7);
            assert!(pool_escrow::total_paid_workers(&pool) == 3900, 8);
            assert!(pool_escrow::total_fees_collected(&pool) == 100, 9);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Verify WORKER1 received net payment.
        ts::next_tx(&mut scenario, WORKER1);
        {
            let coin = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            assert!(coin::value(&coin) == 3900, 10);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// HIGH-A regression: the ORCHESTRATOR key (not a full admin) must be able to
    /// run the ENTIRE settlement flow — start, pay_worker, finalize. This proves
    /// the orchestrator (a least-privilege key, not a full admin) can drive a
    /// complete settlement cycle.
    #[test]
    fun test_orchestrator_can_run_full_settlement() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Super-admin (ADMIN) grants the least-privilege orchestrator role.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            admin_registry::add_orchestrator(&mut admin_reg, ORCH, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
        };

        // ORCH (NOT an admin) runs the full settlement, INCLUDING deduct.
        ts::next_tx(&mut scenario, ORCH);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 4000, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );
            assert!(pool_escrow::total_paid_workers(&pool) == 3900, 2);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // L1 rolling payout cap (set_payout_cap / EPayoutCapExceeded)
    // =========================================================================

    /// A gross payout exceeding the rolling cap must abort EPayoutCapExceeded.
    #[test]
    #[expected_failure(abort_code = pool_escrow::EPayoutCapExceeded)]
    fun test_payout_cap_blocks_excessive_payout() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };
        // Super-admin sets a tight cap of 3000 (window unchanged).
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_payout_cap(&mut pool, &admin_reg, 3000, 0, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut batch = pool_escrow::start_batch_settlement(&mut pool, &admin_reg, &clock, ts::ctx(&mut scenario));
            // 4000 gross > 3000 cap → abort.
            pool_escrow::pay_worker(&mut pool, &admin_reg, &mut batch, WORKER1, 4000, &clock, ts::ctx(&mut scenario));
            pool_escrow::finalize_batch_settlement(&mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// A payout within the cap succeeds and records window usage.
    #[test]
    fun test_payout_cap_allows_within_and_records() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_payout_cap(&mut pool, &admin_reg, 5000, 0, &clock, ts::ctx(&mut scenario));
            let mut batch = pool_escrow::start_batch_settlement(&mut pool, &admin_reg, &clock, ts::ctx(&mut scenario));
            pool_escrow::pay_worker(&mut pool, &admin_reg, &mut batch, WORKER1, 4000, &clock, ts::ctx(&mut scenario));
            pool_escrow::finalize_batch_settlement(&mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario));
            // window_used == the GROSS just paid (cap counts gross).
            let (cap, _win, _start, used) = pool_escrow::payout_cap_status(&pool);
            assert!(cap == 5000, 0);
            assert!(used == 4000, 1);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool_escrow::ENotSuperAdmin)]
    fun test_set_payout_cap_non_super_admin_fails() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_payout_cap(&mut pool, &admin_reg, 1000, 0, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // Tunable platform fee (set_platform_fee_bps / EFeeTooHigh)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::EFeeTooHigh)]
    fun test_set_platform_fee_bps_rejects_above_max() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // 501 bps > MAX_FEE_BPS (500) → abort.
            pool_escrow::set_platform_fee_bps(&mut pool, &admin_reg, 501, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Retuning the fee actually changes what pay_worker withholds.
    #[test]
    fun test_set_platform_fee_bps_retune_changes_net() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // Retune to the 5% ceiling.
            pool_escrow::set_platform_fee_bps(&mut pool, &admin_reg, 500, &clock, ts::ctx(&mut scenario));
            assert!(pool_escrow::platform_fee_bps(&pool) == 500, 0);

            let mut batch = pool_escrow::start_batch_settlement(&mut pool, &admin_reg, &clock, ts::ctx(&mut scenario));
            // 1000 gross @ 5% → fee 50, net 950 (vs the 25/975 at the 250 default).
            pool_escrow::pay_worker(&mut pool, &admin_reg, &mut batch, WORKER1, 1000, &clock, ts::ctx(&mut scenario));
            assert!(pool_escrow::batch_fees_collected(&batch) == 50, 1);
            assert!(pool_escrow::batch_total_paid(&batch) == 950, 2);
            pool_escrow::finalize_batch_settlement(&mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = pool_escrow::ENotSuperAdmin)]
    fun test_set_platform_fee_bps_non_super_admin_fails() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_platform_fee_bps(&mut pool, &admin_reg, 100, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 5. pay_worker correctly splits 2.5% fee
    // =========================================================================

    #[test]
    fun test_pay_worker_fee_split() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund CLIENT1 with 100_000 to cover worker payments.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 100_000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );

            let pool_before = pool_escrow::pool_balance(&pool);
            let fee_before = pool_escrow::fee_pool_balance(&pool);

            // Pay WORKER1 gross 10_000.
            //   fee = 10_000 * 250 / 10_000 = 250
            //   net = 10_000 - 250 = 9_750
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 10_000, &clock, ts::ctx(&mut scenario)
            );

            let expected_fee = (10_000 * PLATFORM_FEE_BPS) / BPS_DENOMINATOR; // 250
            let expected_net = 10_000 - expected_fee; // 9750

            // fee_pool increased by fee amount.
            assert!(pool_escrow::fee_pool_balance(&pool) == fee_before + expected_fee, 0);
            // pool decreased by full gross amount.
            assert!(pool_escrow::pool_balance(&pool) == pool_before - 10_000, 1);
            // Batch stats.
            assert!(pool_escrow::batch_total_paid(&batch) == expected_net, 2);
            assert!(pool_escrow::batch_fees_collected(&batch) == expected_fee, 3);

            // Pay WORKER2 gross 1_000.
            //   fee = 1_000 * 250 / 10_000 = 25
            //   net = 1_000 - 25 = 975
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER2, 1_000, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::batch_fees_collected(&batch) == expected_fee + 25, 4);
            assert!(pool_escrow::batch_total_paid(&batch) == expected_net + 975, 5);
            assert!(pool_escrow::batch_workers_paid(&batch) == 2, 6);

            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Verify WORKER1 received 9750.
        ts::next_tx(&mut scenario, WORKER1);
        {
            let coin = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            assert!(coin::value(&coin) == 9750, 7);
            ts::return_to_sender(&scenario, coin);
        };

        // Verify WORKER2 received 975.
        ts::next_tx(&mut scenario, WORKER2);
        {
            let coin = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            assert!(coin::value(&coin) == 975, 8);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 7. finalize_batch_settlement consumes and deletes the batch object
    // =========================================================================

    #[test]
    fun test_finalize_deletes_batch() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund pool so we can run a settlement.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 5000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Start, pay, finalize -- all in one transaction.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 1000, &clock, ts::ctx(&mut scenario)
            );

            // batch is consumed by value -- after this call it no longer exists.
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );

            // Pool should be unlocked.
            assert!(!pool_escrow::is_settlement_in_progress(&pool), 0);
            assert!(pool_escrow::current_cycle(&pool) == 1, 1);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // After finalize, no SettlementBatch object should exist in the scenario.
        ts::next_tx(&mut scenario, ADMIN);
        {
            assert!(!ts::has_most_recent_shared<SettlementBatch>(), 2);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 8. abort_settlement rolls back cycle counter
    // =========================================================================

    #[test]
    fun test_abort_settlement_rolls_back_cycle() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            assert!(pool_escrow::current_cycle(&pool) == 0, 0);

            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            assert!(pool_escrow::current_cycle(&pool) == 1, 1);
            assert!(pool_escrow::is_settlement_in_progress(&pool), 2);

            pool_escrow::abort_settlement(
                &mut pool, &admin_reg, batch, ts::ctx(&mut scenario)
            );

            // Cycle should revert to 0.
            assert!(pool_escrow::current_cycle(&pool) == 0, 3);
            // Pool should be unlocked.
            assert!(!pool_escrow::is_settlement_in_progress(&pool), 4);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Verify a new settlement can start after abort (reuses cycle 1).
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            assert!(pool_escrow::current_cycle(&pool) == 1, 5);
            assert!(pool_escrow::batch_cycle(&batch) == 1, 6);

            pool_escrow::abort_settlement(
                &mut pool, &admin_reg, batch, ts::ctx(&mut scenario)
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 9. withdraw_fees extracts from fee_pool
    // =========================================================================

    #[test]
    fun test_withdraw_fees() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        let fee_recipient: address = @0xFEE;

        // Fund pool with 10000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 10000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Run a settlement to generate fees, then withdraw some.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            // Pay WORKER1 gross 8000 => fee = 200, net = 7800.
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 8000, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::fee_pool_balance(&pool) == 200, 0);

            // Withdraw 150 of the 200 fees to fee_recipient.
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 150, fee_recipient, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::fee_pool_balance(&pool) == 50, 1);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Verify fee_recipient received 150.
        ts::next_tx(&mut scenario, fee_recipient);
        {
            let coin = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            assert!(coin::value(&coin) == 150, 2);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 10. Non-admin cannot start settlement
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::ENotAdmin)]
    fun test_non_admin_cannot_start_settlement() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // This call will abort before returning a batch, so no cleanup needed.
            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            // Unreachable: use test helper for batch disposal.
            pool_escrow::transfer_batch_for_testing(batch, NON_ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 11. Cannot start settlement while one is in progress
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::ESettlementInProgress)]
    fun test_cannot_start_settlement_while_in_progress() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );

            // Try starting a second settlement -- should abort.
            let batch2 = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );

            // Unreachable cleanup.
            pool_escrow::transfer_batch_for_testing(batch, ADMIN);
            pool_escrow::transfer_batch_for_testing(batch2, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 12. Withdraw more than balance fails
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::EWithdrawExceedsAvailable)]
    fun test_withdraw_exceeds_available() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // CLIENT1 deposits 500.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 500);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // CLIENT1 tries to withdraw 501 -- should abort.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            pool_escrow::withdraw(&mut pool, 501, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 14. Non-admin cannot pay worker
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::ENotAdmin)]
    fun test_non_admin_cannot_pay_worker() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Deposit for CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 5000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Admin starts settlement and sends batch to NON_ADMIN.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::transfer_batch_for_testing(batch, NON_ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // NON_ADMIN tries to pay a worker -- should abort with ENotAdmin.
        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut batch = ts::take_from_sender<SettlementBatch>(&scenario);
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 1000, &clock, ts::ctx(&mut scenario)
            );
            ts::return_to_sender(&scenario, batch);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 15. Non-admin cannot withdraw fees
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::ENotAdmin)]
    fun test_non_admin_cannot_withdraw_fees() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, NON_ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 1, NON_ADMIN, &clock, ts::ctx(&mut scenario)
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 17. Multiple clients and workers in one settlement
    // =========================================================================

    #[test]
    fun test_multi_client_multi_worker_settlement() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund CLIENT1 with 5000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin1 = mint_cove(&mut scenario, 5000);
            transfer::public_transfer(coin1, CLIENT1);
        };

        // Fund CLIENT2 with 3000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin2 = mint_cove(&mut scenario, 3000);
            transfer::public_transfer(coin2, CLIENT2);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        ts::next_tx(&mut scenario, CLIENT2);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Settlement: pay both workers.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            assert!(pool_escrow::pool_balance(&pool) == 8000, 0);

            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );

            // Pay WORKER1 gross 1500 => fee=37, net=1463.
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 1500, &clock, ts::ctx(&mut scenario)
            );
            // Pay WORKER2 gross 1000 => fee=25, net=975.
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER2, 1000, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::batch_workers_paid(&batch) == 2, 3);
            assert!(pool_escrow::batch_fees_collected(&batch) == 37 + 25, 4);
            assert!(pool_escrow::batch_total_paid(&batch) == 1463 + 975, 5);

            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );

            // Client deposit balances are untouched by payouts (the off-chain
            // ledger is authoritative for client usage; pay_worker draws from
            // the pool, not from individual client balances).
            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 5000, 6);
            assert!(pool_escrow::client_balance(&pool, CLIENT2) == 3000, 7);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 18. Deposit during settlement is allowed
    // =========================================================================

    #[test]
    fun test_deposit_during_settlement_allowed() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Start settlement and transfer batch to ADMIN for later cleanup.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::transfer_batch_for_testing(batch, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Mint and give COVE to CLIENT1.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 2000);
            transfer::public_transfer(coin, CLIENT1);
        };

        // CLIENT1 deposits during settlement -- this should succeed.
        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);

            assert!(pool_escrow::is_settlement_in_progress(&pool), 0);

            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 2000, 1);

            ts::return_shared(pool);
        };

        // Clean up: abort the settlement.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let batch = ts::take_from_sender<SettlementBatch>(&scenario);
            pool_escrow::abort_settlement(&mut pool, &admin_reg, batch, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 19. Withdraw with no prior deposit fails (EInsufficientBalance)
    // =========================================================================

    #[test]
    #[expected_failure(abort_code = pool_escrow::EInsufficientBalance)]
    fun test_withdraw_no_deposit_fails() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            pool_escrow::withdraw(&mut pool, 1, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 20. Settlement lifetime stats accumulate across cycles
    // =========================================================================

    #[test]
    fun test_lifetime_stats_accumulate() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Fund CLIENT1 with 20_000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let coin = mint_cove(&mut scenario, 20_000);
            transfer::public_transfer(coin, CLIENT1);
        };

        ts::next_tx(&mut scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(&scenario);
            pool_escrow::deposit(&mut pool, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(pool);
        };

        // Settlement cycle 1: pay WORKER1 gross 4000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            // gross 4000 => fee=100, net=3900
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, 4000, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        // Settlement cycle 2: pay WORKER2 gross 2000.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, &clock, ts::ctx(&mut scenario)
            );
            // gross 2000 => fee=50, net=1950
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER2, 2000, &clock, ts::ctx(&mut scenario)
            );
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, &clock, ts::ctx(&mut scenario)
            );

            assert!(pool_escrow::current_cycle(&pool) == 2, 0);
            // Lifetime totals: net paid = 3900+1950=5850, fees = 100+50=150.
            assert!(pool_escrow::total_paid_workers(&pool) == 5850, 1);
            assert!(pool_escrow::total_fees_collected(&pool) == 150, 2);
            assert!(pool_escrow::total_deposited(&pool) == 20_000, 3);

            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // =========================================================================
    // 21. View functions return correct initial values
    // =========================================================================

    #[test]
    fun test_initial_pool_state() {
        let mut scenario = setup_test();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let pool = ts::take_shared<EscrowPool>(&scenario);

            assert!(pool_escrow::pool_balance(&pool) == 0, 0);
            assert!(pool_escrow::fee_pool_balance(&pool) == 0, 1);
            assert!(pool_escrow::current_cycle(&pool) == 0, 2);
            assert!(pool_escrow::last_settlement(&pool) == 0, 3);
            assert!(!pool_escrow::is_settlement_in_progress(&pool), 4);
            assert!(pool_escrow::total_deposited(&pool) == 0, 5);
            assert!(pool_escrow::total_withdrawn(&pool) == 0, 6);
            assert!(pool_escrow::total_paid_workers(&pool) == 0, 7);
            assert!(pool_escrow::total_fees_collected(&pool) == 0, 8);
            // Client with no deposit returns 0.
            assert!(pool_escrow::client_balance(&pool, CLIENT1) == 0, 9);
            // Cap state initialised with the default 100k COVE / 24h.
            let (cap, window_ms, _start, used) = pool_escrow::fee_cap_status(&pool);
            assert!(cap == 100_000_000_000_000, 10);
            assert!(window_ms == 86_400_000, 11);
            assert!(used == 0, 12);

            ts::return_shared(pool);
        };

        ts::end(scenario);
    }

    // =========================================================================
    // 22. Admin-withdrawal cap behavior on withdraw_fees
    // =========================================================================
    //
    // The cap mirrors treasury's implementation; this proves it's wired
    // through pool_escrow's withdraw_fees correctly. Treasury's cap test
    // suite covers the algorithmic edge cases (window rolling, accumulation,
    // super-admin gating) — here we focus on the integration points
    // specific to pool_escrow.

    /// Helper: seed `gross_worker` base units of worker-payment through a
    /// synthetic settlement, depositing enough from CLIENT1 to cover it. The
    /// resulting fee_pool ends up with ~2.5% × gross_worker — caller computes
    /// the expected fee with `treasury::calculate_platform_fee(gross_worker)`
    /// if needed.
    fun seed_fees(scenario: &mut Scenario, clock: &Clock, gross_worker: u64) {
        // Client deposit must cover the gross worker payment. pay_worker pulls
        // `gross_worker` from the main pool, so we deposit at least that.
        ts::next_tx(scenario, ADMIN);
        {
            let coin = mint_cove(scenario, gross_worker);
            transfer::public_transfer(coin, CLIENT1);
        };
        ts::next_tx(scenario, CLIENT1);
        {
            let mut pool = ts::take_shared<EscrowPool>(scenario);
            let payment = ts::take_from_sender<Coin<COVE_TOKEN>>(scenario);
            pool_escrow::deposit(&mut pool, payment, clock, ts::ctx(scenario));
            ts::return_shared(pool);
        };
        ts::next_tx(scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(scenario);
            let mut batch = pool_escrow::start_batch_settlement(
                &mut pool, &admin_reg, clock, ts::ctx(scenario),
            );
            pool_escrow::pay_worker(
                &mut pool, &admin_reg, &mut batch, WORKER1, gross_worker, clock, ts::ctx(scenario),
            );
            pool_escrow::finalize_batch_settlement(
                &mut pool, &admin_reg, batch, clock, ts::ctx(scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
    }

    /// Withdrawal exactly equal to the cap must succeed. Uses a small test
    /// cap (1000 base units) so we don't have to seed huge fee balances.
    #[test]
    fun test_withdraw_fees_at_cap_succeeds() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);

        // Seed: pay 40k worker => 2.5% fee = 1000 base units accumulates.
        seed_fees(&mut scenario, &clock, 40_000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // Set a small test cap. Super-admin = ADMIN in test setup.
            pool_escrow::set_fee_cap(
                &mut pool, &admin_reg, 1000, 0, &clock, ts::ctx(&mut scenario),
            );
            // 1000 base units of fees should now be available.
            assert!(pool_escrow::fee_pool_balance(&pool) == 1000, 1100);

            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 1000, ADMIN, &clock, ts::ctx(&mut scenario),
            );
            let (_, _, _, used) = pool_escrow::fee_cap_status(&pool);
            assert!(used == 1000, 1101);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// One base-unit over the cap must abort. We have to seed enough fees
    /// that the balance check passes — otherwise the in-function assertion
    /// order would surface EInsufficientBalance before EAdminWithdrawalCapExceeded.
    #[test]
    #[expected_failure(abort_code = pool_escrow::EAdminWithdrawalCapExceeded)]
    fun test_withdraw_fees_exceeds_cap_aborts() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        // Pay 80k worker => fee = 2.5% × 80k = 2000 base units accumulate.
        // Cap will be 1000; an attempt to withdraw 1001 has the fees
        // available (so balance check passes) but exceeds the cap.
        seed_fees(&mut scenario, &clock, 80_000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_fee_cap(
                &mut pool, &admin_reg, 1000, 0, &clock, ts::ctx(&mut scenario),
            );
            // Try 1001 — one base unit over the 1000 cap, fees available.
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 1001, ADMIN, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Setting cap = 0 pauses every subsequent withdraw_fees call.
    #[test]
    #[expected_failure(abort_code = pool_escrow::EAdminWithdrawalsPaused)]
    fun test_withdraw_fees_when_paused_aborts() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        seed_fees(&mut scenario, &clock, 40_000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::set_fee_cap(
                &mut pool, &admin_reg, 0, 0, &clock, ts::ctx(&mut scenario),
            );
            // Any withdrawal now aborts with EAdminWithdrawalsPaused.
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 1, ADMIN, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Super-admin can raise the cap; subsequent over-default withdrawal succeeds.
    #[test]
    fun test_super_admin_can_raise_fee_cap() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        seed_fees(&mut scenario, &clock, 40_000); // 1000 fees in pool

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // Set a moderate cap so we can withdraw 500 base units cleanly.
            pool_escrow::set_fee_cap(
                &mut pool, &admin_reg, 1000, 0, &clock, ts::ctx(&mut scenario),
            );
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 500, ADMIN, &clock, ts::ctx(&mut scenario),
            );
            let (cap, _, _, used) = pool_escrow::fee_cap_status(&pool);
            assert!(cap == 1000, 1200);
            assert!(used == 500, 1201);
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Withdrawing zero must abort with EInvalidAmount before any cap logic.
    #[test]
    #[expected_failure(abort_code = pool_escrow::EInvalidAmount)]
    fun test_withdraw_fees_zero_amount_aborts() {
        let mut scenario = setup_test();
        let clock = create_clock(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut pool = ts::take_shared<EscrowPool>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            pool_escrow::withdraw_fees(
                &mut pool, &admin_reg, 0, ADMIN, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(pool);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
