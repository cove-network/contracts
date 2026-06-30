#[test_only]
module cove::presale_tests {
    use sui::test_scenario::{Self as ts, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use cove::cove_token::{Self, COVE_TOKEN};
    use cove::presale::{Self, Presale, PurchaseRegistry};
    use cove::admin_registry::{Self, AdminRegistry};

    // === Address Constants ===

    const ADMIN: address = @0xAD;
    const BUYER1: address = @0x1;
    const BUYER2: address = @0x2;


    // Error codes are referenced via presale::EXxx in #[expected_failure] attributes.

    // === Presale Constants (mirrored for test calculations) ===

    const TOKENS_PER_STAGE: u64 = 500_000_000_000_000_000;       // 500M * 1e9
    // 2026-06-08 — tightened cap (50M → 5M) to match the contract.
    const MAX_PER_WALLET_PER_STAGE: u64 = 5_000_000_000_000_000;  // 5M * 1e9
    #[allow(unused_const)]
    const NUM_STAGES: u8 = 5;
    const TOTAL_PRESALE_TOKENS: u64 = 2_500_000_000_000_000_000;  // 5 * 500M * 1e9
    const VESTING_DURATION_MS: u64 = 7_776_000_000;                // 90 days in ms
    const PRICE_SCALE: u64 = 1_000_000_000_000_000_000;           // 1e18
    // 2026-06-08 — bonding curve updated to $0.00350 → $0.05000 across
    // 5 stages (avg ~$0.01215, ~$30M fully sold). See presale.move
    // STAGE_*_PRICE constants for the full ladder.
    const STAGE_1_START_PRICE: u64 = 3_500_000_000_000_000;       // 0.00350
    const STAGE_1_END_PRICE:   u64 = 4_500_000_000_000_000;       // 0.00450

    // === Helpers ===

    /// Initialize COVE token module (creates TreasuryCap) and admin_registry,
    /// then return scenario positioned after init.
    fun setup(): Scenario {
        let mut scenario = ts::begin(ADMIN);
        {
            cove_token::init_for_testing(ts::ctx(&mut scenario));
            admin_registry::init_for_testing(ts::ctx(&mut scenario));
        };
        scenario
    }

    /// Mint `amount` of COVE tokens using the TreasuryCap and return as a Coin.
    fun mint_cove(scenario: &mut Scenario, amount: u64): Coin<COVE_TOKEN> {
        let mut treasury_cap = ts::take_from_sender<TreasuryCap<COVE_TOKEN>>(scenario);
        let coin = coin::mint(&mut treasury_cap, amount, ts::ctx(scenario));
        ts::return_to_sender(scenario, treasury_cap);
        coin
    }

    /// Create a Clock for testing, starting at timestamp 0.
    fun create_clock(ctx: &mut TxContext): Clock {
        clock::create_for_testing(ctx)
    }

    /// Full presale setup: init token, mint full allocation, initialize presale.
    /// Returns scenario positioned after initialization, with shared Presale and
    /// PurchaseRegistry available.
    fun setup_presale(): (Scenario, Clock) {
        let mut scenario = setup();

        // Mint COVE and initialize presale
        ts::next_tx(&mut scenario, ADMIN);
        let cove_coin = mint_cove(&mut scenario, TOTAL_PRESALE_TOKENS);
        let mut clock = create_clock(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 1000); // start at t=1000ms
        let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
        presale::initialize(&admin_reg, cove_coin, &clock, ts::ctx(&mut scenario));
        ts::return_shared(admin_reg);

        (scenario, clock)
    }

    /// Helper: compute expected tokens for a given SUI payment at the start of
    /// stage 1 (when stage_sold == 0). Uses the same integrated pricing logic
    /// as the contract: tokens = payment * PRICE_SCALE / start_price (initial
    /// estimate), then actual_cost = tokens * avg(start_price, price_after) /
    /// PRICE_SCALE.
    fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        let a_128 = (a as u128);
        let b_128 = (b as u128);
        let c_128 = (c as u128);
        let result = (a_128 * b_128) / c_128;
        (result as u64)
    }

    /// Calculate the current price on the bonding curve given sold tokens.
    fun calculate_price(start_price: u64, end_price: u64, sold: u64): u64 {
        let price_range = end_price - start_price;
        let progress = safe_mul_div(sold, PRICE_SCALE, TOKENS_PER_STAGE);
        start_price + safe_mul_div(price_range, progress, PRICE_SCALE)
    }

    // -----------------------------------------------------------------------
    // 1. Initialize validates token amount -- fails with less than 2.5B COVE
    // -----------------------------------------------------------------------


    #[test]
    #[expected_failure(abort_code = presale::EInsufficientTokens)]
    fun test_initialize_fails_with_insufficient_tokens() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            // Mint only half the required amount (1.25B instead of 2.5B)
            let insufficient_amount = TOTAL_PRESALE_TOKENS / 2;
            let cove_coin = mint_cove(&mut scenario, insufficient_amount);
            let mut clock = create_clock(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::initialize(&admin_reg, cove_coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);

            clock::destroy_for_testing(clock);
        };

        ts::end(scenario);
    }


    #[test]
    fun test_initialize_succeeds_with_exact_amount() {
        let mut scenario = setup();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cove_coin = mint_cove(&mut scenario, TOTAL_PRESALE_TOKENS);
            let mut clock = create_clock(ts::ctx(&mut scenario));
            clock::set_for_testing(&mut clock, 1000);

            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::initialize(&admin_reg, cove_coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);

            clock::destroy_for_testing(clock);
        };

        // Verify presale was created correctly
        ts::next_tx(&mut scenario, ADMIN);
        {
            let presale = ts::take_shared<Presale>(&scenario);

            assert!(presale::current_stage(&presale) == 1, 0);
            assert!(presale::is_active(&presale) == true, 1);
            assert!(presale::sui_raised(&presale) == 0, 2);
            assert!(presale::tokens_remaining(&presale) == TOTAL_PRESALE_TOKENS, 4);

            ts::return_shared(presale);
        };

        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 2. Basic purchase at stage 1 start price
    // -----------------------------------------------------------------------


    #[test]
    fun test_basic_purchase_stage_1() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 purchases with a small SUI payment
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Send 1 SUI (1e9 base units) to buy tokens at start of stage 1
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));

            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Buyer should have purchased some tokens
            let total = presale::get_user_total_purchase(&registry, BUYER1);
            assert!(total > 0, 0);

            // SUI should have been collected
            assert!(presale::sui_raised(&presale) > 0, 1);

            // Stage should still be 1 (small purchase)
            assert!(presale::current_stage(&presale) == 1, 2);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 3. Integrated pricing: cost uses average of start and end price
    // -----------------------------------------------------------------------


    #[test]
    fun test_integrated_pricing_uses_average_price() {
        let (mut scenario, clock) = setup_presale();

        // Buy a meaningful amount so the price moves noticeably along the curve
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Send a large payment to buy tokens
            let payment_amount: u64 = 100_000_000_000; // 100 SUI
            let payment = coin::mint_for_testing<SUI>(payment_amount, ts::ctx(&mut scenario));

            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let tokens_bought = presale::get_user_total_purchase(&registry, BUYER1);
            let sui_paid = presale::sui_raised(&presale);

            // The cost using spot price at start would be:
            //   cost_at_spot = tokens * start_price / PRICE_SCALE
            let cost_at_spot = safe_mul_div(tokens_bought, STAGE_1_START_PRICE, PRICE_SCALE);

            // The actual cost should be HIGHER than spot-only pricing because
            // integrated (average) pricing accounts for the price rising as
            // tokens are sold along the bonding curve.
            assert!(sui_paid > cost_at_spot, 0);

            // Also verify the price after purchase has moved up from start
            let price_after = calculate_price(
                STAGE_1_START_PRICE,
                STAGE_1_END_PRICE,
                tokens_bought,
            );
            assert!(price_after > STAGE_1_START_PRICE, 1);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 4. Purchase refunds excess SUI
    // -----------------------------------------------------------------------


    #[test]
    fun test_purchase_refunds_excess_sui() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 sends way more SUI than needed to hit the wallet limit
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Send a very large payment that exceeds what 50M tokens would cost
            // At stage 1 start price of 0.0001, 50M tokens costs ~5000 SUI
            // Send 100_000 SUI to ensure excess
            let overpayment: u64 = 100_000_000_000_000; // 100k SUI
            let payment = coin::mint_for_testing<SUI>(overpayment, ts::ctx(&mut scenario));

            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Buyer should have been capped at MAX_PER_WALLET_PER_STAGE
            let total = presale::get_user_total_purchase(&registry, BUYER1);
            assert!(total == MAX_PER_WALLET_PER_STAGE, 0);

            // The SUI raised should be less than the overpayment (excess refunded)
            let raised = presale::sui_raised(&presale);
            assert!(raised < overpayment, 1);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 5. Per-wallet limit enforcement (50M per stage)
    // -----------------------------------------------------------------------


    #[test]
    fun test_wallet_limit_caps_at_max_per_stage() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 sends far more SUI than needed -- purchase is capped at max per wallet
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Send enough SUI to buy max tokens (excess is refunded)
            let payment = coin::mint_for_testing<SUI>(100_000_000_000_000, ts::ctx(&mut scenario));

            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let total = presale::get_user_total_purchase(&registry, BUYER1);
            assert!(total == MAX_PER_WALLET_PER_STAGE, 0);

            // Stage should still be 1 (only 50M of 500M sold)
            assert!(presale::current_stage(&presale) == 1, 1);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // NOTE: Buying again in the same stage past the per-wallet cap is
        // capped-and-refunded (not aborted). That case is covered by
        // test_wallet_limit_refunds_after_cap_reached.

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }


    // AN-06 fix: when a buyer has already maxed the per-stage cap and tries
    // to buy more, the contract now refunds the full payment and returns
    // cleanly rather than aborting. This test asserts the new behavior:
    // the second purchase succeeds (no abort) AND the buyer ends up with
    // the full SUI payment back in their wallet.
    #[test]
    fun test_wallet_limit_refunds_after_cap_reached() {
        let (mut scenario, clock) = setup_presale();

        // First purchase: max out the wallet for the current stage.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(100_000_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Second purchase in same stage with a fresh 1 SUI payment: must
        // NOT abort, must refund the full 1 SUI back to the buyer.
        let refund_amount: u64 = 1_000_000_000;
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(refund_amount, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Confirm the buyer received the full SUI back as a separate coin.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let refund = ts::take_from_address<Coin<SUI>>(&scenario, BUYER1);
            assert!(coin::value(&refund) == refund_amount, 0);
            ts::return_to_address(BUYER1, refund);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 6. Weighted average vesting time across multiple purchases
    // -----------------------------------------------------------------------


    #[test]
    fun test_weighted_average_purchase_time() {
        let (mut scenario, mut clock) = setup_presale();

        // First purchase at T1 = 1000ms (the presale start time)
        let t1: u64 = 1000;
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Buy a small amount at T1
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let tokens_after_first = presale::get_user_total_purchase(&registry, BUYER1);
            assert!(tokens_after_first > 0, 0);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Second purchase at T2 = 5000ms (4 seconds later)
        let t2: u64 = 5000;
        clock::set_for_testing(&mut clock, t2);
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let tokens_before = presale::get_user_total_purchase(&registry, BUYER1);

            // Buy a similar amount at T2
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let tokens_after = presale::get_user_total_purchase(&registry, BUYER1);
            let second_batch = tokens_after - tokens_before;
            assert!(second_batch > 0, 1);

            // The purchase_time should be a weighted average between T1 and T2,
            // NOT simply T1 or T2. We verify via the vesting status: if the
            // purchase_time were exactly T1 (=1000), then at time T2 (=5000)
            // we'd have elapsed = 4000ms. If it were T2, elapsed = 0ms.
            // The weighted average means elapsed is between 0 and 4000.
            //
            // We can check by querying vesting status at T2: the claimable_now
            // should reflect a weighted-average start time.
            let (total, released, _claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );
            assert!(total == tokens_after, 2);
            assert!(released == 0, 3);

            // If purchase_time were exactly T1, elapsed at T2 would be 4000ms
            // yielding some vesting. If T2, elapsed = 0. The weighted avg
            // means purchase_time is between T1 and T2.
            // We verify the purchase_time is strictly between T1 and T2 by
            // checking the claimable amount at T2. With a purely T1 start,
            // the claimable would be maximum; with T2 start, it would be 25%
            // (immediate only, no vesting elapsed). The actual should be
            // between these extremes.

            // Calculate what 25% immediate would be (minimum claimable if
            // purchase_time == T2, so elapsed == 0)
            let immediate_only = (tokens_after * 25) / 100;

            // Calculate max claimable if purchase_time == T1 (elapsed = 4000ms)
            let vesting_portion = (tokens_after * 75) / 100;
            let max_vested_at_t2 = (vesting_portion * (t2 - t1)) / VESTING_DURATION_MS;
            let max_claimable_if_t1 = immediate_only + max_vested_at_t2;

            // The actual claimable should be >= immediate (always) and
            // <= max_claimable_if_t1 (since weighted avg pushes purchase_time
            // forward from T1)
            assert!(_claimable >= immediate_only, 4);
            assert!(_claimable <= max_claimable_if_t1, 5);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 7. claim_vested: 25% immediately, 100% after 90 days
    // -----------------------------------------------------------------------


    #[test]
    fun test_claim_vested_25_percent_immediate() {
        let (mut scenario, mut clock) = setup_presale();

        // BUYER1 makes a purchase
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // BUYER1 claims vested tokens immediately (no time elapsed since purchase)
        // clock is still at purchase time, so elapsed = 0 from BUYER1's perspective
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let (total_purchased, _, claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );

            // 25% should be available immediately
            let expected_immediate = (total_purchased * 25) / 100;
            assert!(claimable == expected_immediate, 1);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            // After claiming, tokens_released should equal the immediate amount
            let (_, released, remaining_claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );
            assert!(released == expected_immediate, 2);
            assert!(remaining_claimable == 0, 3);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }


    #[test]
    fun test_claim_vested_100_percent_after_90_days() {
        let (mut scenario, mut clock) = setup_presale();
        let purchase_time: u64 = 1000;

        // BUYER1 makes a purchase
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Advance clock past 90 days from purchase time
        clock::set_for_testing(&mut clock, purchase_time + VESTING_DURATION_MS + 1);

        // BUYER1 claims -- should get 100%
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let (total_purchased, _, claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );

            // After 90 days, 100% should be claimable (allow 1-unit rounding
            // from separate integer divisions: T*25/100 + T*75/100 <= T)
            assert!(total_purchased - claimable <= 1, 0);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            let (total, released, remaining) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );
            // Allow 1-unit rounding loss from separate integer divisions
            assert!(total - released <= 1, 1);
            assert!(remaining == 0, 2);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 8. claim_vested underflow guard -- no abort on rounding edge cases
    // -----------------------------------------------------------------------


    #[test]
    fun test_claim_vested_underflow_guard() {
        let (mut scenario, mut clock) = setup_presale();
        let purchase_time: u64 = 1000;

        // BUYER1 makes a purchase
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Claim at an intermediate time point (partial vesting)
        let mid_time = purchase_time + VESTING_DURATION_MS / 3;
        clock::set_for_testing(&mut clock, mid_time);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Claim again at a slightly later time -- should not abort even if
        // rounding means total_claimable == tokens_released (the underflow
        // guard should return 0 and hit ENoTokensToVest, not arithmetic abort)
        let slightly_later = mid_time + 1; // 1ms later
        clock::set_for_testing(&mut clock, slightly_later);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let (_, _, claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );

            // The important thing is that this call does not abort due to
            // underflow. If claimable > 0 we can claim; if 0, we verify the
            // guard works by confirming the view function returns 0 without
            // aborting.
            if (claimable > 0) {
                presale::claim_vested(
                    &mut presale,
                    &mut registry,
                    &clock,
                    ts::ctx(&mut scenario),
                );
            };
            // If claimable == 0, the underflow guard correctly prevented
            // a subtraction underflow and returned 0 instead.

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Finally, claim everything at full vesting
        clock::set_for_testing(&mut clock, purchase_time + VESTING_DURATION_MS + 1);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            // All tokens released (allow 1-unit rounding loss)
            let (total, released, remaining) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );
            assert!(total - released <= 1, 0);
            assert!(remaining == 0, 1);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }


    #[test]
    #[expected_failure(abort_code = presale::ENoTokensToVest)]
    fun test_claim_vested_twice_at_same_time_aborts() {
        let (mut scenario, mut clock) = setup_presale();

        // BUYER1 purchase
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Advance time and claim
        clock::set_for_testing(&mut clock, 1000 + VESTING_DURATION_MS / 2);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Try claiming again at the same time -- should abort ENoTokensToVest
            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 10. Cannot purchase when presale is not active
    // -----------------------------------------------------------------------


    #[test]
    #[expected_failure(abort_code = presale::EPresaleNotActive)]
    fun test_cannot_purchase_after_finalization() {
        let (mut scenario, clock) = setup_presale();

        // Admin finalizes the presale
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::finalize_presale(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // BUYER1 tries to purchase -- should fail with EPresaleNotActive
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 10b. set_vesting_terms — fat-finger ceiling on vesting duration.
    //      The terms freeze on first purchase and can never be re-set, so an
    //      absurd duration would permanently strand buyers. The upper bound
    //      (MAX_VESTING_DURATION_MS = 5y) blocks that NON-recoverable state.
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = presale::EInvalidBounds)]
    fun test_set_vesting_terms_rejects_excessive_duration() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN); // ADMIN = super-admin in setup
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // 5 years + 1 ms — just over the ceiling. Must abort EInvalidBounds.
            presale::set_vesting_terms(
                &admin_reg, &mut presale, 25, 157_680_000_001, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_set_vesting_terms_accepts_max_duration() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // Exactly the ceiling (5y) is allowed; a normal 90d would be too.
            presale::set_vesting_terms(
                &admin_reg, &mut presale, 25, 157_680_000_000, &clock, ts::ctx(&mut scenario),
            );
            assert!(presale::vesting_duration_ms(&presale) == 157_680_000_000, 0);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = presale::EInvalidBounds)]
    fun test_set_vesting_terms_rejects_zero_duration() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // duration 0 is rejected (lower bound).
            presale::set_vesting_terms(
                &admin_reg, &mut presale, 25, 0, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// set_stage_prices rejects a ladder that steps DOWN between stages
    /// (stage i end > stage i+1 start) — the cross-stage continuity guard.
    #[test]
    #[expected_failure(abort_code = presale::EInvalidBounds)]
    fun test_set_stage_prices_rejects_cross_stage_step_down() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // stage0 end (2500) > stage1 start (2000) → cross-stage step down.
            let starts = vector[1000u64, 2000, 3000, 4000, 5000];
            let ends = vector[2500u64, 2500, 3500, 4500, 5500];
            presale::set_stage_prices(&admin_reg, &mut presale, starts, ends, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// A monotonic ladder (each stage end ≤ next stage start) is accepted.
    #[test]
    fun test_set_stage_prices_accepts_monotonic_ladder() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let starts = vector[1000u64, 2000, 3000, 4000, 5000];
            let ends = vector[2000u64, 3000, 4000, 5000, 6000];
            presale::set_stage_prices(&admin_reg, &mut presale, starts, ends, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// BUYER PROTECTION: once the first purchase lands, parameters_frozen flips
    /// true and EVERY pre-freeze setter must abort EParametersFrozen — buyers are
    /// guaranteed the terms they bought under can't be retroactively changed,
    /// even by the super-admin.
    #[test]
    #[expected_failure(abort_code = presale::EParametersFrozen)]
    fun test_setters_frozen_after_first_purchase() {
        let (mut scenario, clock) = setup_presale();
        // BUYER1 purchases → freezes parameters.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(&mut presale, &mut registry, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(registry);
            ts::return_shared(presale);
        };
        // Super-admin retune must now abort — params are frozen.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::set_max_per_wallet_per_stage(
                &admin_reg, &mut presale, 1_000_000_000_000_000, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// set_stage_prices rejects a wrong-length vector (must be NUM_STAGES=5).
    #[test]
    #[expected_failure(abort_code = presale::EInvalidStagePrices)]
    fun test_set_stage_prices_rejects_wrong_length() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            // Only 4 entries (need 5) → abort.
            let starts = vector[1000u64, 2000, 3000, 4000];
            let ends = vector[2000u64, 3000, 4000, 5000];
            presale::set_stage_prices(&admin_reg, &mut presale, starts, ends, &clock, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    /// Only super-admin may set the per-wallet cap.
    #[test]
    #[expected_failure(abort_code = presale::ENotSuperAdmin)]
    fun test_set_max_per_wallet_non_super_admin_fails() {
        let (mut scenario, clock) = setup_presale();
        ts::next_tx(&mut scenario, BUYER1); // not an admin
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::set_max_per_wallet_per_stage(
                &admin_reg, &mut presale, 1_000_000_000_000_000, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 11. advance_stage works and enforces admin-only
    // -----------------------------------------------------------------------


    #[test]
    fun test_advance_stage() {
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            assert!(presale::current_stage(&presale) == 1, 0);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            assert!(presale::current_stage(&presale) == 2, 1);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            assert!(presale::current_stage(&presale) == 3, 2);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            assert!(presale::current_stage(&presale) == 4, 3);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            assert!(presale::current_stage(&presale) == 5, 4);

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }


    #[test]
    #[expected_failure(abort_code = presale::EInvalidStage)]
    fun test_advance_stage_beyond_5_fails() {
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            // Advance to stage 5
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));

            assert!(presale::current_stage(&presale) == 5, 0);

            // Advancing beyond stage 5 should fail
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }


    #[test]
    #[expected_failure(abort_code = presale::ENotAdmin)]
    fun test_advance_stage_non_admin_fails() {
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 12. Event emits correct stage (not next stage after auto-advance)
    // -----------------------------------------------------------------------


    #[test]
    fun test_event_emits_correct_stage_on_auto_advance() {
        let (mut scenario, clock) = setup_presale();

        // Fill stage 1 by having multiple buyers purchase up to the limit.
        // We need 500M tokens sold. Each wallet can do 50M per stage.
        // We need 10 buyers to fill a stage, but we only have BUYER1 and BUYER2.
        // Instead, use admin to advance the stage and verify the purchase records
        // the correct stage.

        // Manually advance to stage 2 after a purchase in stage 1
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            assert!(presale::current_stage(&presale) == 1, 0);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Verify tokens were recorded in stage 1 (index 0)
            let stage1_bought = presale::get_user_stage_purchase(&registry, BUYER1, 0);
            assert!(stage1_bought > 0, 1);

            // Stage 1 tokens should be sold
            let stage1_sold = presale::stage_sold(&presale, 1);
            assert!(stage1_sold == stage1_bought, 2);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Admin advances to stage 2
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            assert!(presale::current_stage(&presale) == 2, 3);

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // BUYER1 purchases in stage 2 -- tokens should be recorded under stage 2
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Stage 2 (index 1) should have tokens purchased
            let stage2_bought = presale::get_user_stage_purchase(&registry, BUYER1, 1);
            assert!(stage2_bought > 0, 4);

            // Stage 2 sold counter should reflect the purchase
            let stage2_sold = presale::stage_sold(&presale, 2);
            assert!(stage2_sold == stage2_bought, 5);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // 14. withdraw_raised_sui admin-only
    // -----------------------------------------------------------------------


    #[test]
    fun test_withdraw_raised_sui_admin_only() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 makes a purchase to generate some SUI in the pool
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Admin withdraws raised SUI
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let raised_before = presale::sui_raised(&presale);
            assert!(raised_before > 0, 1);

            // Pentest L1 (2026-06-05): amount=0 is no longer valid.
            // Pull the explicit amount instead. (Old AN-05 drain-all
            // semantics removed — caller must size against the cap.)
            let withdrawn_coin = presale::withdraw_raised_sui(
                &admin_reg,
                &mut presale,
                raised_before,
                &clock,
                ts::ctx(&mut scenario),
            );

            assert!(coin::value(&withdrawn_coin) == raised_before, 2);
            assert!(presale::sui_raised(&presale) == 0, 3);

            // Clean up the withdrawn coin
            transfer::public_transfer(withdrawn_coin, ADMIN);

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
    #[test]
    #[expected_failure(abort_code = presale::ENotAdmin)]
    fun test_withdraw_raised_sui_non_admin_fails() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 makes a purchase
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // BUYER1 (not admin) tries to withdraw
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            let coin = presale::withdraw_raised_sui(
                &admin_reg,
                &mut presale,
                0,
                &clock,
                ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin, BUYER1);

            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 14b. PENTEST L1 (2026-06-05): withdraw_raised_sui must reject
    //      amount=0 (drain-all shortcut removed) and enforce the
    //      rolling-window cap. Mirrors the treasury cap pattern.
    // -----------------------------------------------------------------------

    #[test]
    #[expected_failure(abort_code = presale::EZeroWithdrawAmount)]
    fun test_l1_withdraw_raised_sui_rejects_zero() {
        let (mut scenario, clock) = setup_presale();

        // Seed some SUI in sui_raised via a real purchase.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Admin attempts amount=0 → REJECT.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale, 0, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = presale::ESuiWithdrawCapExceeded)]
    fun test_l1_withdraw_raised_sui_caps_at_window_limit() {
        let (mut scenario, clock) = setup_presale();

        // Seed enough SUI to exceed the default 1k SUI cap. 2k SUI of
        // payment goes in; later we'll try to pull more than the cap.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            // 2_000 SUI = 2_000 × 1e9 base units.
            let payment = coin::mint_for_testing<SUI>(2_000_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // First withdraw — at the cap, succeeds.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale,
                1_000_000_000_000, // 1k SUI, == default cap
                &clock,
                ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Second withdraw in the same window — even 1 base unit is
        // over the cap. Must abort ESuiWithdrawCapExceeded.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale, 1, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = presale::ESuiWithdrawsPaused)]
    fun test_l1_withdraw_raised_sui_paused_when_cap_zero() {
        let (mut scenario, mut clock) = setup_presale();

        // Seed SUI.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale, &mut registry, payment, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Super-admin (ADMIN, who is the deployer/super_admin in tests)
        // pauses by setting cap = 0.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::set_sui_withdraw_cap(
                &admin_reg, &mut presale,
                0,                       // PAUSE
                86_400_000,
                &clock,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Advance clock so the rolling window check doesn't masquerade
        // a fresh-window slot pass.
        clock::increment_for_testing(&mut clock, 1);

        // Any withdraw attempt now → ESuiWithdrawsPaused.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale, 1, &clock, ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_l1_withdraw_raised_sui_window_rolls() {
        let (mut scenario, mut clock) = setup_presale();

        // Seed enough SUI for two-window-cap worth of withdraws.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(2_500_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale, &mut registry, payment, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // First withdraw fills the window.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale,
                1_000_000_000_000, // at cap
                &clock,
                ts::ctx(&mut scenario),
            );
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Advance past the 24h window.
        clock::increment_for_testing(&mut clock, 86_400_001);

        // Second withdraw is now in a fresh window — should succeed.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale,
                1_000_000_000_000,
                &clock,
                ts::ctx(&mut scenario),
            );
            assert!(coin::value(&coin_out) == 1_000_000_000_000, 0);
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_l1_set_sui_withdraw_cap_raises_ceiling() {
        // Sanity: after super_admin raises the cap, a larger single
        // withdraw goes through that would have been blocked under the
        // default. Pentest L1 escape hatch verification.
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(5_000_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale, &mut registry, payment, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Raise cap to 4k SUI.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::set_sui_withdraw_cap(
                &admin_reg, &mut presale,
                4_000_000_000_000, // 4k SUI
                86_400_000,
                &clock,
                ts::ctx(&mut scenario),
            );
            assert!(presale::sui_withdraw_cap(&presale) == 4_000_000_000_000, 0);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Withdraw 3k SUI — would have been over default 1k cap,
        // succeeds under raised 4k cap.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            let coin_out = presale::withdraw_raised_sui(
                &admin_reg, &mut presale,
                3_000_000_000_000,
                &clock,
                ts::ctx(&mut scenario),
            );
            assert!(coin::value(&coin_out) == 3_000_000_000_000, 1);
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 15. finalize_presale admin-only
    // -----------------------------------------------------------------------


    #[test]
    #[expected_failure(abort_code = presale::ENotAdmin)]
    fun test_finalize_presale_non_admin_fails() {
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::finalize_presale(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 15b. PENTEST C1 (2026-06-05): withdraw_unsold_tokens MUST NOT drain
    //      buyer-owed COVE from the pool. Prior to the fix, an admin call
    //      after finalize_presale split the entire token_pool balance,
    //      leaving claim_vested() to abort on a now-empty pool. The fix
    //      tracks `outstanding_obligations` and only withdraws the slack.
    // -----------------------------------------------------------------------

    #[test]
    fun test_c1_withdraw_unsold_preserves_buyer_obligations() {
        let (mut scenario, mut clock) = setup_presale();

        // BUYER1 buys some tokens in stage 1.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let payment = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario)); // 10 SUI
            presale::purchase(&mut presale, &mut registry, payment, &clock, ts::ctx(&mut scenario));
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Capture the buyer's purchase amount so we can assert the pool
        // retains exactly that much after the admin's withdraw.
        let bought: u64;
        {
            ts::next_tx(&mut scenario, BUYER1);
            let registry = ts::take_shared<PurchaseRegistry>(&scenario);
            bought = presale::get_user_total_purchase(&registry, BUYER1);
            ts::return_shared(registry);
        };
        assert!(bought > 0, 0);

        // Admin finalizes and immediately withdraws unsold.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);

            // Sanity: pool should have TOTAL_PRESALE - bought; obligations = bought.
            let pool_before = presale::tokens_remaining(&presale);
            let obligations = presale::outstanding_obligations(&presale);
            assert!(pool_before == TOTAL_PRESALE_TOKENS, 1);
            assert!(obligations == bought, 2);
            assert!(presale::withdrawable_unsold(&presale) == pool_before - bought, 3);

            presale::finalize_presale(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            let coin_out = presale::withdraw_unsold_tokens(&admin_reg, &mut presale, ts::ctx(&mut scenario));

            // Withdrawn amount = pool_before - obligations.
            assert!(coin::value(&coin_out) == pool_before - bought, 4);
            // Pool retains EXACTLY the buyer's obligation.
            assert!(presale::tokens_remaining(&presale) == bought, 5);
            assert!(presale::outstanding_obligations(&presale) == bought, 6);

            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Fast-forward past the 90-day vesting window and confirm the
        // buyer can still claim their FULL purchase — proving the admin's
        // withdraw did not impair the buyer's vesting schedule.
        clock::increment_for_testing(&mut clock, 91 * 24 * 60 * 60 * 1000);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            presale::claim_vested(&mut presale, &mut registry, &clock, ts::ctx(&mut scenario));
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Buyer should now hold their purchased amount in COVE (within 1
        // unit of rounding from the 25% + 75% integer split). The point of
        // this assertion is that the admin's withdraw did NOT impair
        // claim_vested — the buyer got essentially their full purchase.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let claimed = ts::take_from_address<Coin<COVE_TOKEN>>(&scenario, BUYER1);
            let got = coin::value(&claimed);
            let diff = if (got > bought) { got - bought } else { bought - got };
            assert!(diff <= 1, 7);
            ts::return_to_address(BUYER1, claimed);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = presale::EInsufficientTokens)]
    fun test_c1_withdraw_unsold_aborts_when_pool_fully_obligated() {
        // Edge case: buyer purchases consume the entire pool (or close
        // enough that withdrawable == 0). withdraw_unsold_tokens must
        // abort rather than mint a 0-coin or underflow.
        let (mut scenario, clock) = setup_presale();

        // Inject a synthetic max-cap purchase to drive obligations all the
        // way up against the pool. Using insert_purchase_for_testing here
        // is much faster than walking through 5 real stages.
        let max_total = MAX_PER_WALLET_PER_STAGE * 5;
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Reduce the pool to match the obligation exactly so
            // withdrawable_unsold == 0 and withdraw_unsold aborts.
            // We can't drain the pool directly so instead we inject a
            // synthetic purchase equal to the full pool balance.
            let pool_now = presale::tokens_remaining(&presale);
            presale::insert_purchase_for_testing(
                &mut presale,
                &mut registry,
                BUYER1,
                pool_now,
                1000,
            );

            assert!(presale::withdrawable_unsold(&presale) == 0, 0);

            // Finalize + attempt withdraw — must abort EInsufficientTokens.
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::finalize_presale(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            let coin_out = presale::withdraw_unsold_tokens(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            // Unreachable — assertion above must have aborted. Drop the
            // coin so the move-checker is happy in the unreachable path.
            transfer::public_transfer(coin_out, ADMIN);
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // unreachable; appease the linter.
        let _max_total = max_total;
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 16. Insufficient payment (too small to buy any tokens)
    // -----------------------------------------------------------------------


    #[test]
    // AN-06 fix: a 0-SUI purchase used to abort with EInsufficientPayment.
    // Now the contract refunds the 0-value coin and returns cleanly.
    // Keeping the test to lock in the no-crash behavior.
    fun test_zero_sui_purchase_refunds_without_abort() {
        let (mut scenario, clock) = setup_presale();

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(0, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // The 0-value SUI coin is refunded to the buyer (sanity-check that
        // the tx didn't abort and the coin object exists).
        ts::next_tx(&mut scenario, BUYER1);
        {
            let refund = ts::take_from_address<Coin<SUI>>(&scenario, BUYER1);
            assert!(coin::value(&refund) == 0, 0);
            ts::return_to_address(BUYER1, refund);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 17. Multiple buyers in same stage
    // -----------------------------------------------------------------------


    #[test]
    fun test_multiple_buyers_same_stage() {
        let (mut scenario, clock) = setup_presale();

        // BUYER1 purchases
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // BUYER2 purchases
        ts::next_tx(&mut scenario, BUYER2);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(2_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Both buyers should have purchases
            let buyer1_total = presale::get_user_total_purchase(&registry, BUYER1);
            let buyer2_total = presale::get_user_total_purchase(&registry, BUYER2);
            assert!(buyer1_total > 0, 0);
            assert!(buyer2_total > 0, 1);

            // BUYER2 paid more SUI, so should have more tokens (or equal due
            // to curve, but at least non-zero)
            assert!(buyer2_total > buyer1_total, 2);

            // Total stage sold should equal both purchases combined
            let stage_sold = presale::stage_sold(&presale, 1);
            assert!(stage_sold == buyer1_total + buyer2_total, 3);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 18. Partial vesting at midpoint (50% elapsed => 25% + 37.5% = 62.5%)
    // -----------------------------------------------------------------------


    #[test]
    fun test_partial_vesting_at_midpoint() {
        let (mut scenario, mut clock) = setup_presale();
        let purchase_time: u64 = 1000;

        // BUYER1 purchases
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Advance to 50% of vesting period
        let midpoint = purchase_time + VESTING_DURATION_MS / 2;
        clock::set_for_testing(&mut clock, midpoint);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let presale = ts::take_shared<Presale>(&scenario);
            let registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let (total, _, claimable) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );

            // Expected: 25% immediate + 50% * 75% vested = 25% + 37.5% = 62.5%
            let immediate = (total * 25) / 100;
            let vesting_portion = (total * 75) / 100;
            // Use safe_mul_div to avoid u64 overflow in intermediate product
            let vested_so_far = safe_mul_div(vesting_portion, VESTING_DURATION_MS / 2, VESTING_DURATION_MS);
            let expected = immediate + vested_so_far;

            assert!(claimable == expected, 0);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 19. Purchase across stages (buy in stage 1, advance, buy in stage 2)
    // -----------------------------------------------------------------------


    #[test]
    fun test_purchase_across_stages() {
        let (mut scenario, clock) = setup_presale();

        // Purchase in stage 1
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Admin advances to stage 2
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // Purchase in stage 2
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Should have purchases in both stage 1 and stage 2
            let stage1 = presale::get_user_stage_purchase(&registry, BUYER1, 0);
            let stage2 = presale::get_user_stage_purchase(&registry, BUYER1, 1);
            assert!(stage1 > 0, 0);
            assert!(stage2 > 0, 1);

            // Total should be the sum
            let total = presale::get_user_total_purchase(&registry, BUYER1);
            assert!(total == stage1 + stage2, 2);

            // Stage 2 tokens should be fewer per SUI (higher price)
            // With same SUI payment but higher price, fewer tokens
            assert!(stage2 < stage1, 3);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 20. View function: get_current_price reflects bonding curve progress
    // -----------------------------------------------------------------------


    #[test]
    fun test_get_current_price_reflects_progress() {
        let (mut scenario, clock) = setup_presale();

        // Price at start should be STAGE_1_START_PRICE
        ts::next_tx(&mut scenario, BUYER1);
        {
            let presale = ts::take_shared<Presale>(&scenario);

            let price_before = presale::get_current_price(&presale);
            assert!(price_before == STAGE_1_START_PRICE, 0);

            ts::return_shared(presale);
        };

        // Make a purchase to move the price up
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(10_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let price_after = presale::get_current_price(&presale);
            assert!(price_after > STAGE_1_START_PRICE, 1);
            assert!(price_after <= STAGE_1_END_PRICE, 2);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 21. Wallet limit resets across stages
    // -----------------------------------------------------------------------


    #[test]
    fun test_wallet_limit_resets_in_new_stage() {
        let (mut scenario, clock) = setup_presale();

        // Max out wallet in stage 1
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(100_000_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let stage1 = presale::get_user_stage_purchase(&registry, BUYER1, 0);
            assert!(stage1 == MAX_PER_WALLET_PER_STAGE, 0);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Advance to stage 2
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let admin_reg = ts::take_shared<AdminRegistry>(&scenario);
            presale::advance_stage(&admin_reg, &mut presale, ts::ctx(&mut scenario));
            ts::return_shared(admin_reg);
            ts::return_shared(presale);
        };

        // BUYER1 should be able to buy again in stage 2
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            let stage2 = presale::get_user_stage_purchase(&registry, BUYER1, 1);
            assert!(stage2 > 0, 1);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // 22. tokens_remaining decreases after vesting claims
    // -----------------------------------------------------------------------


    #[test]
    fun test_tokens_remaining_decreases_after_claim() {
        let (mut scenario, mut clock) = setup_presale();

        // BUYER1 purchases
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let payment = coin::mint_for_testing<SUI>(1_000_000_000, ts::ctx(&mut scenario));
            presale::purchase(
                &mut presale,
                &mut registry,
                payment,
                &clock,
                ts::ctx(&mut scenario),
            );

            // Tokens remaining should still be full (tokens not released on purchase)
            assert!(presale::tokens_remaining(&presale) == TOTAL_PRESALE_TOKENS, 0);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };


        // Full vesting
        clock::set_for_testing(&mut clock, 1000 + VESTING_DURATION_MS + 1);

        // Claim vested tokens
        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            let remaining_before = presale::tokens_remaining(&presale);

            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            let remaining_after = presale::tokens_remaining(&presale);
            let (total, released, _) = presale::get_user_vesting_status(
                &presale,
                &registry,
                BUYER1,
                &clock,
            );

            // Pool should have decreased by the released amount
            assert!(remaining_after == remaining_before - released, 1);
            // Allow 1-unit rounding loss from separate integer divisions
            assert!(total - released <= 1, 2);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // -----------------------------------------------------------------------
    // Regression: AN-01 — claim_vested at the per-wallet cap maximum.
    //
    // A buyer who maxes the per-wallet cap in all 5 stages owns 250M COVE
    // (= 2.5e17 base units). The vesting math `total_purchased * 75 / 100`
    // overflowed u64 in earlier versions (1.875e19 > 1.844e19), aborting
    // the claim and permanently locking the buyer's tokens.
    //
    // Fix: u128 intermediate casts on every distribution multiplication in
    // both claim_vested and get_user_vesting_status. This test asserts the
    // function returns 100% claimable at day-90 for a maxed-out buyer.
    // -----------------------------------------------------------------------
    #[test]
    fun test_claim_vested_at_max_cap_does_not_overflow() {
        let (mut scenario, mut clock) = setup_presale();
        let purchase_time: u64 = 1000;

        // Inject a synthetic buyer record at the per-wallet maximum and seed
        // the presale pool with enough COVE to cover the claim. Bypasses the
        // normal purchase() path — the regression we're guarding is purely
        // in the claim math, not in the stage-progression code.
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);
            let mut cap = ts::take_from_address<TreasuryCap<COVE_TOKEN>>(&scenario, ADMIN);

            let max_total = MAX_PER_WALLET_PER_STAGE * 5; // 250M COVE
            presale::insert_purchase_for_testing(
                &mut presale,
                &mut registry,
                BUYER1,
                max_total,
                purchase_time,
            );
            let seed = coin::mint(&mut cap, max_total, ts::ctx(&mut scenario));
            presale::seed_pool_for_testing(&mut presale, seed);

            ts::return_to_address(ADMIN, cap);
            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Day 90 — full unlock window elapsed.
        clock::set_for_testing(&mut clock, purchase_time + VESTING_DURATION_MS + 1);

        ts::next_tx(&mut scenario, BUYER1);
        {
            let mut presale = ts::take_shared<Presale>(&scenario);
            let mut registry = ts::take_shared<PurchaseRegistry>(&scenario);

            // Pre-claim view: must return without aborting. Earlier versions
            // aborted here on the same overflow as claim_vested.
            let (total, _, claimable) = presale::get_user_vesting_status(
                &presale,
                &registry, BUYER1, &clock,
            );
            assert!(total == MAX_PER_WALLET_PER_STAGE * 5, 100);
            // Full window elapsed → all 250M claimable (modulo 1-unit rounding).
            assert!(total - claimable <= 1, 101);

            // The real assertion: this used to abort. With the fix it
            // succeeds and transfers the buyer's tokens.
            presale::claim_vested(
                &mut presale,
                &mut registry,
                &clock,
                ts::ctx(&mut scenario),
            );

            let (total_after, released_after, remaining_after) =
                presale::get_user_vesting_status(
                &presale,
                &registry, BUYER1, &clock);
            assert!(total_after - released_after <= 1, 102);
            assert!(remaining_after == 0, 103);

            ts::return_shared(presale);
            ts::return_shared(registry);
        };

        // Buyer received the full 250M coin.
        ts::next_tx(&mut scenario, BUYER1);
        {
            let coin = ts::take_from_address<Coin<COVE_TOKEN>>(&scenario, BUYER1);
            // Allow 1-unit rounding off the cap from integer division.
            assert!(MAX_PER_WALLET_PER_STAGE * 5 - coin::value(&coin) <= 1, 104);
            ts::return_to_address(BUYER1, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
