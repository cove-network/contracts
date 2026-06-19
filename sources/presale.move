/// Cove Presale Module -- 5-Stage Bonding Curve Token Sale
///
/// Implements a presale mechanism for the COVE token using a 5-stage bonding curve
/// with linear price appreciation within each stage. Total allocation: 2.5B COVE
/// (500M per stage).
///
/// ## Bonding Curve
///
/// 5 sequential stages. Within each stage, price increases linearly from start to
/// end as tokens are sold. Heavier discount early, smaller jumps later — rewards
/// the earliest believers.
///
///   Stage 1: $0.0010 -> $0.0020   (2.0× growth)
///   Stage 2: $0.0020 -> $0.0035   (1.75×)
///   Stage 3: $0.0035 -> $0.0050   (1.43×)
///   Stage 4: $0.0050 -> $0.0070   (1.40×)
///   Stage 5: $0.0070 -> $0.0090   (1.29×)
///
/// Avg cost basis across a fully-sold presale ≈ $0.0045, total raise ≈ $11.25M USD.
/// Stages auto-advance when fully sold out, or can be manually advanced by the admin.
///
/// ## Anti-Whale Protection
///
/// Each wallet is limited to purchasing 50M COVE tokens per stage (10% of stage supply).
/// This ensures broad distribution and prevents any single buyer from dominating.
///
/// ## Token Vesting
///
/// Tokens vest on a fixed schedule from each buyer's first-purchase timestamp:
///   - 25% available immediately
///   - 75% vests linearly over 90 days
///
/// Users call `claim_vested()` repeatedly to pull whatever has unlocked since the
/// last call. Vesting begins the moment a purchase lands; there is no gating on
/// total raise.
///
/// ## One-Way Purchases
///
/// Presale purchases are one-way. Buyers receive their tokens via the vesting
/// schedule regardless of total raise. Tokens stay in `token_pool` until
/// `claim_vested()` so a buyer cannot extract more than their vested share.
/// Admin can withdraw raised SUI at any time via `withdraw_raised_sui()`.
///
/// ## Upgrade Safety
///
/// Both `Presale` and `PurchaseRegistry` carry a `version` field. All mutating functions
/// assert the object version matches the package `VERSION` constant. After a package
/// upgrade, the admin must call `migrate_presale()` / `migrate_registry()` to bump
/// object versions before normal operations resume.
module cove::presale {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::sui::SUI;
    use sui::event;
    use cove::cove_token::COVE_TOKEN;
    use cove::admin_registry::{Self, AdminRegistry};

    // ============================= Error Codes ===============================

    const ENotAdmin: u64 = 0;
    const EPresaleNotActive: u64 = 1;
    const EStageNotActive: u64 = 2;
    const EInsufficientPayment: u64 = 3;
    const EExceedsWalletLimit: u64 = 4;
    const ENoTokensToVest: u64 = 7;
    const EInvalidStage: u64 = 10;
    const EOverflow: u64 = 11;
    const EPurchaseNotFound: u64 = 12;
    const EWrongVersion: u64 = 13;
    /// Insufficient tokens provided to fund the presale.
    const EInsufficientTokens: u64 = 15;
    /// Pentest L1 (2026-06-05). Withdrawals paused (cap = 0) or amount
    /// is zero. Refusing amount = 0 is part of the fix — the old
    /// drain-all-on-zero semantics let a compromised admin clear the
    /// entire raised pool in one tx; explicit positive amounts force
    /// the operator to pick a number the cap can be sized against.
    const EZeroWithdrawAmount: u64 = 16;
    /// Pentest L1. Cumulative withdraws in the rolling cap window
    /// would exceed sui_withdraw_cap. Operator must wait for the
    /// window to roll or raise the cap (super-admin only).
    const ESuiWithdrawCapExceeded: u64 = 17;
    /// Pentest L1. sui_withdraw_cap = 0 = withdrawals paused. Used
    /// as an emergency brake without needing a contract upgrade.
    const ESuiWithdrawsPaused: u64 = 18;
    /// 2026-06-08 — admin tried to change a tunable parameter after
    /// the first buyer purchased. Once `parameters_frozen` flips
    /// true, every setter aborts with this code.
    const EParametersFrozen: u64 = 19;
    /// 2026-06-08 — setter received a vector of stage prices with
    /// wrong length, or with descending values within a stage, or
    /// stages where end < start.
    const EInvalidStagePrices: u64 = 20;
    /// 2026-06-08 — immediate_release_pct must be in [0, 100].
    const EInvalidReleasePct: u64 = 21;

    // ============================ Versioning ==================================

    /// Current package version. Bumped on each upgrade; all shared objects must
    /// be migrated to this version before they can be mutated.
    const VERSION: u64 = 1;

    // ========================= Presale Parameters ============================

    /// 500 million COVE tokens per stage (with 9 decimal places).
    const TOKENS_PER_STAGE: u64 = 500_000_000_000_000_000; // 500M * 1e9

    /// Maximum tokens a single wallet can buy in any one stage (50M with 9 decimals).
    /// This is 10% of the per-stage supply, preventing whale domination.
    // 2026-06-08 — tightened from 50M to 5M COVE/wallet/stage. At new
    // stage-5 prices this is still a meaningful entry (5M × $0.05 =
    // $250k per wallet at the most expensive stage); aggregate cap
    // across the full presale is 25M COVE per wallet (≤1% of supply).
    // Wider distribution = healthier post-launch market.
    const MAX_PER_WALLET_PER_STAGE: u64 = 5_000_000_000_000_000; // 5M * 1e9

    /// Total number of presale stages.
    const NUM_STAGES: u8 = 5;

    // ======================== Vesting Parameters =============================

    /// Percentage of purchased tokens released immediately at first claim.
    const IMMEDIATE_RELEASE_PCT: u64 = 25;

    /// Duration over which the remaining 75% of tokens vest linearly (90 days in ms).
    const VESTING_DURATION_MS: u64 = 7_776_000_000; // 90 * 24 * 60 * 60 * 1000

    // ─── L1: withdraw_raised_sui cap defaults ────────────────────────────────
    //
    // Defaults sized for a tight ceiling-by-default. A real launch with
    // bigger expected raises calls `set_sui_withdraw_cap` to raise the
    // limit before any single withdraw. Mirrors the treasury pattern
    // (super_admin only).

    /// Default rolling window for the cap: 24 hours.
    const DEFAULT_SUI_WITHDRAW_WINDOW_MS: u64 = 86_400_000;
    /// Default per-window SUI cap (base units, 1 SUI = 1e9).
    /// 1,000 SUI / 24h. Operators should raise this BEFORE a real
    /// presale opens via `set_sui_withdraw_cap` if their expected
    /// daily withdraw exceeds this.
    const DEFAULT_SUI_WITHDRAW_CAP: u64 = 1_000_000_000_000;

    // =================== Bonding Curve Price Constants ========================
    //
    // $0.001 → $0.009 SUI-per-COVE across 5 stages. Heavier discount early,
    // smaller jumps later. Average ~$0.0045 across a fully-sold presale.
    //
    // Prices are scaled by PRICE_SCALE (1e18). Example: $0.001 → 1_000_000_000_000_000.

    // 2026-06-08 — revised pricing (v2 of the day). Stage 5's
    // earlier 3.3x within-stage jump was unsustainable; tamed to
    // 2x for a healthier sell-through expectation.
    //
    //   Stage 1:  $0.00350 → $0.00450  (avg $0.00400)  → $2.00M
    //   Stage 2:  $0.00450 → $0.00600  (avg $0.00525)  → $2.63M
    //   Stage 3:  $0.00600 → $0.00850  (avg $0.00725)  → $3.63M
    //   Stage 4:  $0.00850 → $0.01500  (avg $0.01175)  → $5.88M
    //   Stage 5:  $0.01500 → $0.03000  (avg $0.02250)  → $11.25M
    //   ────────────────────────────────────────────────────────
    //                                  avg $0.01015    →  $25.375M
    //
    // Within-stage jump caps at 2x; cross-stage smooth, no cliffs.
    // Day-1 DEX price target ~$0.03 → $300M FDV at 10B supply —
    // ambitious for a Sui infra play but defensible given the
    // ecosystem maturity (Walrus / Suilend / Cetus comp set).
    const STAGE_1_START_PRICE: u64 =  3_500_000_000_000_000; // 0.00350
    const STAGE_1_END_PRICE:   u64 =  4_500_000_000_000_000; // 0.00450
    const STAGE_2_START_PRICE: u64 =  4_500_000_000_000_000; // 0.00450
    const STAGE_2_END_PRICE:   u64 =  6_000_000_000_000_000; // 0.00600
    const STAGE_3_START_PRICE: u64 =  6_000_000_000_000_000; // 0.00600
    const STAGE_3_END_PRICE:   u64 =  8_500_000_000_000_000; // 0.00850
    const STAGE_4_START_PRICE: u64 =  8_500_000_000_000_000; // 0.00850
    const STAGE_4_END_PRICE:   u64 = 15_000_000_000_000_000; // 0.01500
    const STAGE_5_START_PRICE: u64 = 15_000_000_000_000_000; // 0.01500
    const STAGE_5_END_PRICE:   u64 = 30_000_000_000_000_000; // 0.03000

    /// Fixed-point scale factor (1e18) used for all price arithmetic.
    /// Multiplied into numerators before division to preserve precision.
    const PRICE_SCALE: u64 = 1_000_000_000_000_000_000; // 1e18

    // =============================== Structs =================================

    /// Shared object holding the global presale state.
    ///
    /// Created once by `initialize()` and shared so any user can call `purchase()`.
    /// Admin operations (stage advancement, finalization, SUI withdrawal, version
    /// migration) are gated by the shared `AdminRegistry`.
    public struct Presale has key {
        id: UID,
        /// Object version -- must equal package VERSION for all mutating calls.
        version: u64,
        /// Current active stage (1-5). Advances when a stage sells out or manually.
        current_stage: u8,
        /// Whether the presale is currently accepting purchases.
        is_active: bool,
        /// Pool of COVE tokens reserved for this presale. Tokens are split out
        /// of this balance when users claim vested amounts.
        token_pool: Balance<COVE_TOKEN>,
        /// Accumulated SUI from all purchases. Withdrawable by admin at any
        /// time via `withdraw_raised_sui()`.
        sui_raised: Balance<SUI>,
        /// Tokens sold in each stage (index 0 = stage 1, ..., index 4 = stage 5).
        stage_sold: vector<u64>,
        /// Timestamp (ms) when the presale was initialized.
        start_time: u64,
        /// Set to `true` by admin via `finalize_presale()`. Once finalized, no
        /// further purchases are accepted. Unsold tokens become claimable by
        /// admin via `withdraw_unsold_tokens()`. Buyers' vesting schedules are
        /// unaffected — they continue claiming via `claim_vested()`.
        finalized: bool,
        /// Sum of buyer COVE that has been purchased but not yet released via
        /// `claim_vested()`. Incremented on each `purchase()` by `actual_tokens`,
        /// decremented on each `claim_vested()` by `to_release`. Used by
        /// `withdraw_unsold_tokens()` to refuse to drain tokens that buyers
        /// are still owed under the 90-day vesting schedule.
        ///
        /// Invariant: `outstanding_obligations <= balance::value(&token_pool)`
        /// at all times after `initialize()`. Without this counter,
        /// `withdraw_unsold_tokens()` would drain the entire pool — including
        /// buyer-owed tokens — and subsequently brick `claim_vested()` with
        /// `balance::split` aborts on an empty pool. (Pentest C1, 2026-06-05.)
        outstanding_obligations: u64,

        // ─── L1 (2026-06-05): rolling-window cap on withdraw_raised_sui ──
        //
        // Mirrors the treasury withdrawal-cap pattern (treasury.move).
        // Bounds how much SUI an admin can pull out of the raised pool
        // per `sui_withdraw_window_ms`. Without this, a single
        // compromised admin key drained 100% of raised SUI in one tx
        // (the old `withdraw_raised_sui` accepted amount=0 as
        // drain-all + had no cap of any kind).
        //
        // Cap = 0 means withdrawals are PAUSED. Use as an emergency
        // brake — super-admin can set it to 0 without a contract
        // upgrade if compromise is suspected.
        //
        // Window state is reset whenever the rolling window elapses.

        /// Maximum SUI (base units) that can be withdrawn per window.
        /// Mutable via `set_sui_withdraw_cap()` (super-admin only).
        sui_withdraw_cap: u64,
        /// Length of the rolling cap window, in milliseconds.
        sui_withdraw_window_ms: u64,
        /// Start of the current rolling window (ms since epoch).
        sui_withdraw_window_start: u64,
        /// Total SUI withdrawn so far in the current window.
        sui_withdraw_window_used: u64,

        // ─── Tunable parameters (2026-06-08) ─────────────────────
        //
        // These were previously const values baked into the bytecode,
        // which meant any change required a fresh package publish + a
        // full post-deploy ceremony. They are now state fields with
        // super-admin setters, gated by `parameters_frozen` — once any
        // buyer purchases, the parameters become permanently
        // immutable for that presale (same trust property as the old
        // const values, but with pre-launch tuning flexibility).
        //
        // The bonding-curve math (calculatePrice, purchase, etc.)
        // reads from these fields instead of the const values; the
        // const values remain in the source as DEFAULTS used by
        // `initialize()` so a fresh presale starts with the
        // documented ladder.

        /// Stage start prices in PRICE_SCALE units. vector length must
        /// equal NUM_STAGES (validated by setters).
        stage_start_prices: vector<u64>,
        /// Stage end prices in PRICE_SCALE units. Same length / validation.
        stage_end_prices: vector<u64>,
        /// Per-wallet purchase cap per stage. Mutable until first
        /// purchase. Defaults to MAX_PER_WALLET_PER_STAGE const at init.
        max_per_wallet_per_stage_value: u64,
        /// % of purchased tokens released immediately on first claim.
        /// Mutable until first purchase. Defaults to IMMEDIATE_RELEASE_PCT.
        immediate_release_pct_value: u64,
        /// Linear-vesting duration for the remaining %. Mutable until
        /// first purchase. Defaults to VESTING_DURATION_MS.
        vesting_duration_ms_value: u64,

        /// Permanent freeze flag. Set to `true` automatically the first
        /// time `purchase()` runs successfully. Once true, every
        /// parameter-setter aborts with `EParametersFrozen` — buyers
        /// are guaranteed the contract terms they purchased under
        /// cannot be changed retroactively.
        parameters_frozen: bool,
    }

    /// Per-user purchase record, stored inside `PurchaseRegistry`.
    ///
    /// Tracks how many tokens the user bought in each stage, total tokens,
    /// how many have been released so far, total SUI paid, and the timestamp
    /// of the user's first purchase (used as the vesting start time).
    public struct UserPurchase has store, drop, copy {
        /// Tokens purchased in each stage (index 0 = stage 1, etc.).
        purchased_per_stage: vector<u64>,
        /// Sum of tokens purchased across all stages.
        total_purchased: u64,
        /// Tokens already released to the user via `claim_vested()`.
        tokens_released: u64,
        /// Total SUI paid by this user. Zeroed out upon refund.
        sui_paid: u64,
        /// Timestamp (ms) of the user's first purchase. Serves as the vesting
        /// start time for computing the linear unlock schedule.
        purchase_time: u64,
    }

    /// Shared object mapping buyer addresses to their `UserPurchase` records.
    ///
    /// Separated from `Presale` so that purchase lookups and updates can be
    /// done independently of the main presale state when beneficial.
    public struct PurchaseRegistry has key {
        id: UID,
        /// Object version -- must equal package VERSION for all mutating calls.
        version: u64,
        /// Mapping from buyer address to purchase record.
        purchases: Table<address, UserPurchase>,
    }

    // =============================== Events ==================================

    /// Emitted when a user successfully purchases tokens.
    public struct TokensPurchased has copy, drop {
        buyer: address,
        stage: u8,
        tokens: u64,
        sui_paid: u64,
        /// Spot price at the time of purchase (PRICE_SCALE-scaled).
        price: u64,
    }

    /// Emitted when a user claims vested tokens.
    public struct TokensVested has copy, drop {
        user: address,
        /// Tokens released in this claim.
        amount: u64,
        /// Cumulative tokens released to the user after this claim.
        total_released: u64,
    }

    /// Emitted when admin withdraws raised SUI from the presale.
    /// AN-05 fix: explicit event so adminwatch can classify the action
    /// rather than seeing an unstructured admin tx.
    public struct RaisedSuiWithdrawn has copy, drop {
        admin: address,
        amount: u64,
        /// SUI remaining in `sui_raised` after this withdrawal.
        remaining: u64,
        timestamp_ms: u64,
    }

    /// Emitted whenever the super-admin updates the `sui_withdraw_cap`
    /// or the rolling window length via `set_sui_withdraw_cap`.
    /// On-chain watchers should treat large cap increases as a
    /// security event — operators usually only raise the cap once
    /// before launch and then leave it alone. (Pentest L1, 2026-06-05.)
    public struct SuiWithdrawCapUpdated has copy, drop {
        admin: address,
        old_cap: u64,
        new_cap: u64,
        old_window_ms: u64,
        new_window_ms: u64,
        timestamp_ms: u64,
    }

    /// Emitted when super-admin calls `set_stage_prices()`. The actual
    /// vectors aren't included in the event (they'd bloat the audit
    /// log) — the on-chain state IS the source of truth; admins read
    /// it before/after for diff. Pre-freeze only.
    public struct StagePricesUpdated has copy, drop {
        admin: address,
        timestamp_ms: u64,
    }

    /// Emitted on `set_max_per_wallet_per_stage()`. Pre-freeze only.
    public struct MaxPerWalletUpdated has copy, drop {
        admin: address,
        old_max: u64,
        new_max: u64,
        timestamp_ms: u64,
    }

    /// Emitted on `set_vesting_terms()`. Pre-freeze only.
    public struct VestingTermsUpdated has copy, drop {
        admin: address,
        old_immediate_pct: u64,
        new_immediate_pct: u64,
        old_vesting_duration_ms: u64,
        new_vesting_duration_ms: u64,
        timestamp_ms: u64,
    }

    // ========================= Entry Functions ===============================

    /// Initialize the presale with the full COVE token allocation.
    ///
    /// Creates the shared `Presale` and `PurchaseRegistry` objects. The caller
    /// must be a registered admin in the `AdminRegistry`. The `token_coin` should
    /// contain the entire presale allocation (2.5B COVE). The presale starts
    /// immediately in stage 1.
    ///
    /// Can only be called once since it creates new shared objects.
    public fun initialize(
        admin_reg: &AdminRegistry,
        token_coin: Coin<COVE_TOKEN>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Defense-in-depth: only admins may initialize
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);

        // Ensure the coin contains at least the full presale allocation
        assert!(
            coin::value(&token_coin) >= TOKENS_PER_STAGE * (NUM_STAGES as u64),
            EInsufficientTokens
        );

        let presale = Presale {
            id: object::new(ctx),
            version: VERSION,
            current_stage: 1,
            is_active: true,
            token_pool: coin::into_balance(token_coin),
            sui_raised: balance::zero(),
            stage_sold: vector[0, 0, 0, 0, 0],
            start_time: clock::timestamp_ms(clock),
            finalized: false,
            outstanding_obligations: 0,
            // L1 (2026-06-05): cap defaults to 1k SUI / 24h. Super-admin
            // raises before launch via `set_sui_withdraw_cap`.
            sui_withdraw_cap: DEFAULT_SUI_WITHDRAW_CAP,
            sui_withdraw_window_ms: DEFAULT_SUI_WITHDRAW_WINDOW_MS,
            sui_withdraw_window_start: 0,
            sui_withdraw_window_used: 0,

            // 2026-06-08 — tunable params seeded from the documented
            // const defaults. Admin can change via setters until
            // first purchase, then frozen forever.
            stage_start_prices: vector[
                STAGE_1_START_PRICE,
                STAGE_2_START_PRICE,
                STAGE_3_START_PRICE,
                STAGE_4_START_PRICE,
                STAGE_5_START_PRICE,
            ],
            stage_end_prices: vector[
                STAGE_1_END_PRICE,
                STAGE_2_END_PRICE,
                STAGE_3_END_PRICE,
                STAGE_4_END_PRICE,
                STAGE_5_END_PRICE,
            ],
            max_per_wallet_per_stage_value: MAX_PER_WALLET_PER_STAGE,
            immediate_release_pct_value: IMMEDIATE_RELEASE_PCT,
            vesting_duration_ms_value: VESTING_DURATION_MS,
            parameters_frozen: false,
        };

        let registry = PurchaseRegistry {
            id: object::new(ctx),
            version: VERSION,
            purchases: table::new(ctx),
        };

        transfer::share_object(presale);
        transfer::share_object(registry);
    }

    /// Purchase COVE tokens in the current presale stage.
    ///
    /// The caller sends a SUI `payment` coin. The function calculates how many
    /// COVE tokens the payment buys at the current bonding curve price, caps it
    /// by remaining stage supply and the per-wallet limit, and refunds any
    /// excess SUI.
    ///
    /// **Tokens are NOT transferred here.** All purchased tokens remain in the
    /// pool and are released to the buyer over time via `claim_vested()` per
    /// the 25%-immediate / 75%-over-90-days schedule.
    ///
    /// Preconditions:
    /// - Presale must be active (`is_active == true`).
    /// - Current stage must be valid (1-5).
    /// - Buyer must not have exceeded the per-wallet limit for the current stage.
    ///
    /// Side effects:
    /// - Updates `stage_sold` and may auto-advance to the next stage.
    /// - Creates or updates the buyer's `UserPurchase` in the registry.
    /// - Refunds excess SUI to the buyer if overpaid.
    /// - Emits `TokensPurchased`.
    #[allow(lint(self_transfer))] // Transfers refund coin to tx sender
    public fun purchase(
        presale: &mut Presale,
        registry: &mut PurchaseRegistry,
        payment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(registry.version == VERSION, EWrongVersion);
        assert!(presale.is_active, EPresaleNotActive);
        assert!(presale.current_stage <= NUM_STAGES, EStageNotActive);

        let buyer = tx_context::sender(ctx);
        let payment_amount = coin::value(&payment);
        let stage_idx = (presale.current_stage as u64) - 1;
        let timestamp = clock::timestamp_ms(clock);

        // --- Bonding curve price lookup ---
        let (start_price, end_price) = get_stage_prices(presale, presale.current_stage);
        let stage_sold = *vector::borrow(&presale.stage_sold, stage_idx);
        let current_price = calculate_current_price(start_price, end_price, stage_sold);

        // tokens = payment * PRICE_SCALE / current_price  (uses u128 internally)
        let tokens_purchasable = safe_mul_div(payment_amount, PRICE_SCALE, current_price);

        // Cap by remaining supply in this stage
        let remaining_in_stage = TOKENS_PER_STAGE - stage_sold;
        let mut actual_tokens = if (tokens_purchasable > remaining_in_stage) {
            remaining_in_stage
        } else {
            tokens_purchasable
        };

        // --- Per-wallet limit enforcement ---
        let existing_stage_purchased = if (table::contains(&registry.purchases, buyer)) {
            let purchase = table::borrow(&registry.purchases, buyer);
            *vector::borrow(&purchase.purchased_per_stage, stage_idx)
        } else {
            0
        };

        let max_per_wallet = presale.max_per_wallet_per_stage_value;
        let max_allowed = if (max_per_wallet > existing_stage_purchased) {
            max_per_wallet - existing_stage_purchased
        } else {
            0
        };

        // AN-06 fix: refund-and-return instead of abort. A buyer who's
        // already at the per-stage cap shouldn't eat a failed-tx UX —
        // their wallet should show a successful tx with a full refund.
        // The Move runtime would revert SUI on abort anyway, but the
        // wallet UI surfaces the failure differently.
        if (max_allowed == 0) {
            transfer::public_transfer(payment, buyer);
            return
        };

        if (actual_tokens > max_allowed) {
            actual_tokens = max_allowed;
        };

        // --- Compute actual SUI cost using integrated bonding curve ---
        // For a linear curve, cost = tokens * avg(price_start, price_end).
        // This is the trapezoidal rule, which is exact for linear functions.
        let price_after = calculate_current_price(start_price, end_price, stage_sold + actual_tokens);
        let mut avg_price = (current_price + price_after) / 2;
        let mut actual_cost = safe_mul_div(actual_tokens, avg_price, PRICE_SCALE);

        // If spot-price estimate was too generous (integrated cost > payment),
        // re-estimate tokens using the average price.
        //
        // AN-09 note: `safe_mul_div` floors. After the second pass, a sub-unit
        // rounding residue may remain — the buyer can end up paying the
        // full payment_amount for `actual_tokens − 1` base units in rare
        // cases (the protocol benefits from the asymmetry: the residue
        // accrues to `sui_raised`, never to a loss). Invariant guaranteed
        // by the final assertion below: `actual_cost <= payment_amount`.
        if (actual_cost > payment_amount) {
            actual_tokens = safe_mul_div(payment_amount, PRICE_SCALE, avg_price);
            if (actual_tokens > remaining_in_stage) { actual_tokens = remaining_in_stage; };
            if (actual_tokens > max_allowed) { actual_tokens = max_allowed; };
            let adj_end = calculate_current_price(start_price, end_price, stage_sold + actual_tokens);
            avg_price = (current_price + adj_end) / 2;
            actual_cost = safe_mul_div(actual_tokens, avg_price, PRICE_SCALE);
        };

        // AN-06 fix continued: same refund-and-return path when payment is
        // sub-unit dust below the smallest representable cost on the curve.
        // Keeps wallet UX consistent (success + refund, not failed tx).
        if (actual_cost == 0) {
            transfer::public_transfer(payment, buyer);
            return
        };

        // --- Payment handling: accept cost, refund excess ---
        let mut payment_balance = coin::into_balance(payment);

        if (payment_amount > actual_cost) {
            let refund_amount = payment_amount - actual_cost;
            let refund_balance = balance::split(&mut payment_balance, refund_amount);
            let refund_coin = coin::from_balance(refund_balance, ctx);
            transfer::public_transfer(refund_coin, buyer);
        };

        // Deposit the actual cost into the raised SUI pool
        balance::join(&mut presale.sui_raised, payment_balance);

        // --- Update or create purchase record ---
        if (table::contains(&registry.purchases, buyer)) {
            let purchase = table::borrow_mut(&mut registry.purchases, buyer);
            // Weighted average purchase time so later purchases vest fairly
            let old_total_128 = (purchase.total_purchased as u128);
            let new_tokens_128 = (actual_tokens as u128);
            let old_time_128 = (purchase.purchase_time as u128);
            let new_time_128 = (timestamp as u128);
            let combined_128 = old_total_128 + new_tokens_128;
            let weighted = (old_total_128 * old_time_128 + new_tokens_128 * new_time_128) / combined_128;
            purchase.purchase_time = (weighted as u64);

            let stage_ref = vector::borrow_mut(&mut purchase.purchased_per_stage, stage_idx);
            *stage_ref = *stage_ref + actual_tokens;
            purchase.total_purchased = purchase.total_purchased + actual_tokens;
            purchase.sui_paid = purchase.sui_paid + actual_cost;
        } else {
            let mut purchased_per_stage = vector[0u64, 0u64, 0u64, 0u64, 0u64];
            let stage_ref = vector::borrow_mut(&mut purchased_per_stage, stage_idx);
            *stage_ref = actual_tokens;

            let new_purchase = UserPurchase {
                purchased_per_stage,
                total_purchased: actual_tokens,
                tokens_released: 0,
                sui_paid: actual_cost,
                purchase_time: timestamp,
            };
            table::add(&mut registry.purchases, buyer, new_purchase);
        };

        // --- Stage bookkeeping ---
        let purchase_stage = presale.current_stage; // capture before potential auto-advance
        let sold_ref = vector::borrow_mut(&mut presale.stage_sold, stage_idx);
        *sold_ref = *sold_ref + actual_tokens;

        // Auto-advance to next stage if this one is fully sold
        if (*sold_ref >= TOKENS_PER_STAGE && presale.current_stage < NUM_STAGES) {
            presale.current_stage = presale.current_stage + 1;
        };

        // --- Obligations bookkeeping (Pentest C1, 2026-06-05) ---
        // The buyer now owns `actual_tokens` against the pool, releasable
        // via claim_vested() over the 90-day schedule. Track this so
        // withdraw_unsold_tokens() can refuse to drain what buyers are
        // still owed. Decremented in claim_vested() as tokens release.
        presale.outstanding_obligations = presale.outstanding_obligations + actual_tokens;

        // 2026-06-08 — freeze tunable parameters on the FIRST successful
        // purchase. After this point, every parameter-setter aborts
        // with `EParametersFrozen`. Buyers are guaranteed the
        // contract terms they purchased under cannot be changed.
        // Setting `true` repeatedly is a no-op.
        presale.parameters_frozen = true;

        // No tokens are transferred here. Tokens stay in token_pool until the
        // buyer calls claim_vested() on the vesting schedule.

        event::emit(TokensPurchased {
            buyer,
            stage: purchase_stage,
            tokens: actual_tokens,
            sui_paid: actual_cost,
            price: avg_price,
        });
    }

    /// Claim unlocked (vested) COVE tokens.
    ///
    /// Computes the total tokens the caller is entitled to based on the vesting
    /// schedule (25% immediate + 75% linear over 90 days), subtracts what has
    /// already been released, and transfers the difference.
    ///
    /// Preconditions:
    /// - The caller must have a purchase record.
    /// - There must be unreleased tokens available.
    ///
    /// Vesting begins at the buyer's first purchase regardless of total raise.
    /// Repeatable: as more vests over the 90-day window, the buyer calls again
    /// to pull each new tranche.
    ///
    /// Emits `TokensVested`.
    #[allow(lint(self_transfer))] // Transfers vested tokens to tx sender
    public fun claim_vested(
        presale: &mut Presale,
        registry: &mut PurchaseRegistry,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);

        let buyer = tx_context::sender(ctx);
        assert!(table::contains(&registry.purchases, buyer), EPurchaseNotFound);

        let purchase = table::borrow_mut(&mut registry.purchases, buyer);
        let current_time = clock::timestamp_ms(clock);
        let elapsed = if (current_time > purchase.purchase_time) {
            current_time - purchase.purchase_time
        } else {
            0
        };

        // 75% of tokens vest linearly over vesting_duration_ms_value.
        // Vesting params read from state — see `parameters_frozen`
        // contract: once any buyer purchases, these can't change.
        let immediate_pct = presale.immediate_release_pct_value;
        let vesting_duration = presale.vesting_duration_ms_value;
        // u128 intermediate: total_purchased can reach 2.5e17 (50M × 5 stages
        // at 9 decimals), and 2.5e17 × 75 = 1.875e19 overflows u64 (1.844e19).
        let vesting_amount: u64 = ((((purchase.total_purchased as u128)
            * ((100 - immediate_pct) as u128)) / 100u128) as u64);
        let total_vested = if (elapsed >= vesting_duration) {
            vesting_amount // Fully vested
        } else {
            ((((vesting_amount as u128) * (elapsed as u128)) / (vesting_duration as u128)) as u64)
        };

        // 25% is available immediately on first claim. u128 cast for the
        // same reason — even though 25× is safe at the cap today, hardening
        // it removes a footgun if immediate_release_pct ever shifts pre-freeze.
        let immediate: u64 = ((((purchase.total_purchased as u128)
            * (immediate_pct as u128)) / 100u128) as u64);
        let total_claimable = immediate + total_vested;

        // Only release what hasn't been released yet (guard against rounding edge cases)
        let to_release = if (total_claimable > purchase.tokens_released) {
            total_claimable - purchase.tokens_released
        } else {
            0
        };

        assert!(to_release > 0, ENoTokensToVest);

        purchase.tokens_released = purchase.tokens_released + to_release;

        // Obligations bookkeeping (Pentest C1, 2026-06-05): tokens released
        // are no longer owed to anyone, so they free up for withdraw_unsold.
        // The invariant `outstanding_obligations >= to_release` holds by
        // construction — purchase() incremented it by `actual_tokens` at
        // sale time, and to_release across all claim_vested calls for this
        // buyer never exceeds their total_purchased.
        presale.outstanding_obligations = presale.outstanding_obligations - to_release;

        // Split tokens from the presale pool and transfer to buyer
        let release_balance = balance::split(&mut presale.token_pool, to_release);
        let release_coin = coin::from_balance(release_balance, ctx);
        transfer::public_transfer(release_coin, buyer);

        event::emit(TokensVested {
            user: buyer,
            amount: to_release,
            total_released: purchase.tokens_released,
        });
    }

    // ========================== Admin Functions ==============================

    /// Manually advance the presale to the next stage.
    ///
    /// Allows the admin to move to the next stage even if the current one is not
    /// fully sold out. Useful for time-based stage progression or ending an
    /// undersubscribed stage early.
    ///
    /// Admin only. Aborts if presale is not active or already at the final stage.
    public fun advance_stage(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(presale.is_active, EPresaleNotActive);
        assert!(presale.current_stage < NUM_STAGES, EInvalidStage);
        presale.current_stage = presale.current_stage + 1;
    }

    /// Finalize the presale, stopping all future purchases.
    ///
    /// Sets `is_active = false` and `finalized = true`. Once finalized:
    /// - No more purchases can be made.
    /// - Buyers continue to claim their vested tokens per the schedule
    ///   (vesting is not affected by finalization).
    /// - Admin can call `withdraw_unsold_tokens()` to recover any tokens
    ///   from stages that didn't sell out.
    ///
    /// Admin only. Irreversible.
    public fun finalize_presale(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        presale.is_active = false;
        presale.finalized = true;
    }

    /// Withdraw raised SUI from the presale pool, subject to the rolling
    /// per-window cap (`sui_withdraw_cap`).
    ///
    /// Admin can withdraw raised SUI at any time (during the presale or
    /// after finalization). The SUI in `sui_raised` is admin-controlled
    /// from the moment a buyer pays — there is no refund path.
    ///
    /// Pentest L1 (2026-06-05):
    ///   - `amount = 0` is REJECTED (`EZeroWithdrawAmount`). The old
    ///     drain-all-on-zero shortcut let a single compromised admin
    ///     key empty `sui_raised` in one tx. Operators must pass an
    ///     explicit positive amount.
    ///   - The amount is checked against a rolling per-window cap
    ///     (`sui_withdraw_cap` / `sui_withdraw_window_ms`). A
    ///     compromised key is bounded to the cap before the next
    ///     window rolls. Mirrors the treasury withdrawal-cap pattern.
    ///   - Set `sui_withdraw_cap = 0` (super-admin only) to PAUSE
    ///     withdrawals entirely; the call then aborts
    ///     `ESuiWithdrawsPaused` until the cap is raised again.
    ///
    /// Admin only.
    public fun withdraw_raised_sui(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<SUI> {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        // L1: amount > 0 is mandatory now (no drain-all shortcut).
        assert!(amount > 0, EZeroWithdrawAmount);
        // L1: cap = 0 = paused. Distinct error code so an admin
        // watching for "did this fail because we paused?" vs
        // "did this fail because we hit the cap?" can react accordingly.
        assert!(presale.sui_withdraw_cap > 0, ESuiWithdrawsPaused);

        // Roll the window if expired (also handles backwards-clock
        // anomaly the same way treasury does — see AN-07 fix).
        let now = clock::timestamp_ms(clock);
        if (now < presale.sui_withdraw_window_start) {
            presale.sui_withdraw_window_start = now;
            presale.sui_withdraw_window_used = 0;
        };
        if (now >= presale.sui_withdraw_window_start + presale.sui_withdraw_window_ms) {
            presale.sui_withdraw_window_start = now;
            presale.sui_withdraw_window_used = 0;
        };
        assert!(
            presale.sui_withdraw_window_used + amount <= presale.sui_withdraw_cap,
            ESuiWithdrawCapExceeded
        );

        let available = balance::value(&presale.sui_raised);
        assert!(amount <= available, EInsufficientPayment);

        presale.sui_withdraw_window_used = presale.sui_withdraw_window_used + amount;

        let withdraw_balance = balance::split(&mut presale.sui_raised, amount);
        event::emit(RaisedSuiWithdrawn {
            admin: tx_context::sender(ctx),
            amount: amount,
            remaining: available - amount,
            timestamp_ms: now,
        });
        coin::from_balance(withdraw_balance, ctx)
    }

    /// Update the rolling-window cap on `withdraw_raised_sui`.
    ///
    /// SUPER-admin only. The cap is the only knob that bounds how much
    /// a compromised regular-admin key can drain in 24h; only the
    /// super-admin should control it.
    ///
    /// Setting `new_cap = 0` is the documented emergency brake: it
    /// PAUSES `withdraw_raised_sui` (aborts `ESuiWithdrawsPaused`)
    /// without requiring a contract upgrade. Set back to a positive
    /// value to resume.
    ///
    /// `new_window_ms` adjusts the rolling-window length. Common
    /// values: 24h = 86_400_000, 7d = 604_800_000.
    ///
    /// Emits `SuiWithdrawCapUpdated`.
    ///
    /// Pentest L1 (2026-06-05).
    public fun set_sui_withdraw_cap(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        new_cap: u64,
        new_window_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(
            admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)),
            ENotAdmin
        );
        // Sanity: a 0 window would either underflow the rollover math
        // (we already guard with `now >= start + window`) or make the
        // window-roll trivially perpetual. Reject so set_sui_withdraw_cap
        // can't be used as an oblique pause vector — use new_cap=0 for
        // pause instead.
        assert!(new_window_ms > 0, EZeroWithdrawAmount);

        let old_cap = presale.sui_withdraw_cap;
        let old_window_ms = presale.sui_withdraw_window_ms;
        presale.sui_withdraw_cap = new_cap;
        presale.sui_withdraw_window_ms = new_window_ms;

        event::emit(SuiWithdrawCapUpdated {
            admin: tx_context::sender(ctx),
            old_cap,
            new_cap,
            old_window_ms,
            new_window_ms,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    // ─── Tunable parameter setters (2026-06-08) ──────────────────────
    //
    // Three setters — set_stage_prices, set_max_per_wallet_per_stage,
    // set_vesting_terms — let the super-admin tune the presale's
    // bonding curve, wallet cap, and vesting schedule UP UNTIL the
    // first buyer purchases. After that, `presale.parameters_frozen`
    // is `true` and every setter aborts with `EParametersFrozen`.
    //
    // Each setter validates its inputs strictly (length, ordering,
    // bounds) and emits an event for auditability.

    /// Replace the per-stage bonding-curve price ladder. Both vectors
    /// must have exactly NUM_STAGES (5) entries. Within each stage
    /// `end >= start` (linear bonding curves don't go backward).
    /// Aborts after first purchase.
    public fun set_stage_prices(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        new_start_prices: vector<u64>,
        new_end_prices: vector<u64>,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(
            admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)),
            ENotAdmin
        );
        assert!(!presale.parameters_frozen, EParametersFrozen);
        let n = (NUM_STAGES as u64);
        assert!(vector::length(&new_start_prices) == n, EInvalidStagePrices);
        assert!(vector::length(&new_end_prices) == n, EInvalidStagePrices);
        // Per-stage validation: end >= start, and prices must be
        // non-zero (a zero price would let buyers mint infinite tokens
        // for one MIST).
        let mut i = 0;
        while (i < n) {
            let s = *vector::borrow(&new_start_prices, i);
            let e = *vector::borrow(&new_end_prices, i);
            assert!(s > 0, EInvalidStagePrices);
            assert!(e >= s, EInvalidStagePrices);
            i = i + 1;
        };
        presale.stage_start_prices = new_start_prices;
        presale.stage_end_prices = new_end_prices;
        event::emit(StagePricesUpdated {
            admin: tx_context::sender(ctx),
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    /// Replace the per-wallet purchase cap. 0 effectively pauses
    /// purchases (every buyer gets refunded — `purchase()` returns
    /// max_allowed=0). Aborts after first purchase.
    public fun set_max_per_wallet_per_stage(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        new_max: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(
            admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)),
            ENotAdmin
        );
        assert!(!presale.parameters_frozen, EParametersFrozen);
        let old_max = presale.max_per_wallet_per_stage_value;
        presale.max_per_wallet_per_stage_value = new_max;
        event::emit(MaxPerWalletUpdated {
            admin: tx_context::sender(ctx),
            old_max,
            new_max,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }

    /// Replace the vesting schedule. immediate_pct in [0, 100];
    /// vesting_duration_ms > 0. Aborts after first purchase.
    public fun set_vesting_terms(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        new_immediate_pct: u64,
        new_vesting_duration_ms: u64,
        clock: &Clock,
        ctx: &TxContext
    ) {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(
            admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)),
            ENotAdmin
        );
        assert!(!presale.parameters_frozen, EParametersFrozen);
        assert!(new_immediate_pct <= 100, EInvalidReleasePct);
        assert!(new_vesting_duration_ms > 0, EInvalidReleasePct);
        let old_immediate_pct = presale.immediate_release_pct_value;
        let old_duration = presale.vesting_duration_ms_value;
        presale.immediate_release_pct_value = new_immediate_pct;
        presale.vesting_duration_ms_value = new_vesting_duration_ms;
        event::emit(VestingTermsUpdated {
            admin: tx_context::sender(ctx),
            old_immediate_pct,
            new_immediate_pct,
            old_vesting_duration_ms: old_duration,
            new_vesting_duration_ms,
            timestamp_ms: clock::timestamp_ms(clock),
        });
    }


    /// Withdraw unsold COVE tokens remaining in the presale pool after finalization.
    ///
    /// Recovers tokens from stages that didn't fully sell out, returning them
    /// to the admin for reallocation (e.g. into the liquidity_pool to seed a
    /// DEX listing).
    ///
    /// Withdraws exactly `pool_balance - outstanding_obligations` — never the
    /// COVE that buyers are still owed under the 90-day vesting schedule.
    /// Buyers continue claiming via `claim_vested()` after this call as
    /// documented; the pool retains their tranche.
    ///
    /// Admin only. Presale must be finalized.
    ///
    /// (Pentest C1, 2026-06-05: prior version drained the entire pool,
    /// including buyer-owed tokens, bricking subsequent `claim_vested()`
    /// calls with `balance::split` aborts.)
    public fun withdraw_unsold_tokens(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        ctx: &mut TxContext
    ): Coin<COVE_TOKEN> {
        assert!(presale.version == VERSION, EWrongVersion);
        assert!(admin_registry::is_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(presale.finalized, EPresaleNotActive);

        let pool_balance = balance::value(&presale.token_pool);
        // Defense in depth: the invariant
        // `pool_balance >= outstanding_obligations` should always hold
        // (purchase increments both supply-out + obligations equally; claim
        // decrements both equally). Assert it here so a violation aborts
        // with EInsufficientTokens rather than underflowing.
        assert!(pool_balance >= presale.outstanding_obligations, EInsufficientTokens);
        let withdrawable = pool_balance - presale.outstanding_obligations;
        assert!(withdrawable > 0, EInsufficientTokens);

        let withdraw_balance = balance::split(&mut presale.token_pool, withdrawable);
        coin::from_balance(withdraw_balance, ctx)
    }

    // ========================= Helper Functions ==============================

    /// Returns the (start_price, end_price) pair for the given stage
    /// number (1-5). Reads from the Presale's mutable price vectors
    /// — the source of truth for the active price ladder. The
    /// STAGE_*_PRICE consts at the top of this module are kept as
    /// DEFAULT seeds used only by `initialize()`; once a presale is
    /// shared, only the on-chain vectors matter (and they freeze
    /// permanently on first purchase).
    fun get_stage_prices(presale: &Presale, stage: u8): (u64, u64) {
        // 1-indexed stage, vectors are 0-indexed. stage is validated
        // by the caller (current_stage is always 1-5 by construction).
        let idx = (stage as u64) - 1;
        (*vector::borrow(&presale.stage_start_prices, idx),
         *vector::borrow(&presale.stage_end_prices, idx))
    }

    /// Computes the current spot price on the linear bonding curve.
    ///
    /// The price increases linearly from `start_price` to `end_price` as
    /// `sold` goes from 0 to `TOKENS_PER_STAGE`:
    ///
    ///   price = start_price + (end_price - start_price) * (sold / TOKENS_PER_STAGE)
    ///
    /// Uses `safe_mul_div` throughout to avoid u64 overflow in intermediate products.
    fun calculate_current_price(start_price: u64, end_price: u64, sold: u64): u64 {
        let price_range = end_price - start_price;
        // progress = sold / TOKENS_PER_STAGE, scaled by PRICE_SCALE for precision
        let progress = safe_mul_div(sold, PRICE_SCALE, TOKENS_PER_STAGE);
        // price = start + range * progress / PRICE_SCALE
        start_price + safe_mul_div(price_range, progress, PRICE_SCALE)
    }

    /// Calculates `(a * b) / c` using u128 intermediate arithmetic to prevent
    /// u64 overflow.
    ///
    /// Move's u64 maxes out at ~1.8e19. Since price calculations multiply token
    /// amounts (~5e17) by price scale (~1e18), the intermediate product (~5e35)
    /// would overflow u64. Casting to u128 (max ~3.4e38) handles this safely.
    ///
    /// Aborts with `EOverflow` if `c` is zero or if the result exceeds u64 range.
    fun safe_mul_div(a: u64, b: u64, c: u64): u64 {
        assert!(c > 0, EOverflow);
        let a_128 = (a as u128);
        let b_128 = (b as u128);
        let c_128 = (c as u128);
        let result = (a_128 * b_128) / c_128;
        assert!(result <= (18_446_744_073_709_551_615u128), EOverflow); // MAX_U64
        (result as u64)
    }

    // ============================ View / Query ===============================

    /// Returns the number of tokens `user` has purchased in a specific stage.
    /// `stage_idx` is 0-indexed (0 = stage 1, ..., 4 = stage 5).
    public fun get_user_stage_purchase(registry: &PurchaseRegistry, user: address, stage_idx: u64): u64 {
        if (table::contains(&registry.purchases, user)) {
            let purchase = table::borrow(&registry.purchases, user);
            *vector::borrow(&purchase.purchased_per_stage, stage_idx)
        } else {
            0
        }
    }

    /// Returns the total tokens `user` has purchased across all stages.
    public fun get_user_total_purchase(registry: &PurchaseRegistry, user: address): u64 {
        if (table::contains(&registry.purchases, user)) {
            let purchase = table::borrow(&registry.purchases, user);
            purchase.total_purchased
        } else {
            0
        }
    }

    /// Returns the vesting status for a user as a tuple:
    /// `(total_purchased, tokens_released, claimable_now)`.
    ///
    /// `claimable_now` is the amount the user could receive by calling
    /// `claim_vested()` at the current time.
    public fun get_user_vesting_status(
        presale: &Presale,
        registry: &PurchaseRegistry,
        user: address,
        clock: &Clock
    ): (u64, u64, u64) {
        if (!table::contains(&registry.purchases, user)) {
            return (0, 0, 0)
        };

        let purchase = table::borrow(&registry.purchases, user);
        let current_time = clock::timestamp_ms(clock);
        let elapsed = if (current_time > purchase.purchase_time) {
            current_time - purchase.purchase_time
        } else {
            0
        };

        // Mirror the claim_vested math exactly (see comment at L451 for
        // why these need u128 — otherwise this read-only view aborts for
        // any wallet that maxed the per-stage cap across all 5 stages).
        let immediate_pct = presale.immediate_release_pct_value;
        let vesting_duration = presale.vesting_duration_ms_value;
        let vesting_amount: u64 = ((((purchase.total_purchased as u128)
            * ((100 - immediate_pct) as u128)) / 100u128) as u64);
        let total_vested = if (elapsed >= vesting_duration) {
            vesting_amount
        } else {
            ((((vesting_amount as u128) * (elapsed as u128)) / (vesting_duration as u128)) as u64)
        };

        let immediate: u64 = ((((purchase.total_purchased as u128)
            * (immediate_pct as u128)) / 100u128) as u64);
        let total_claimable = immediate + total_vested;
        let claimable_now = if (total_claimable > purchase.tokens_released) {
            total_claimable - purchase.tokens_released
        } else {
            0
        };

        (purchase.total_purchased, purchase.tokens_released, claimable_now)
    }

    // ======================== Simple Accessors ================================

    /// Returns the current presale stage (1-5).
    public fun current_stage(presale: &Presale): u8 {
        presale.current_stage
    }

    /// Returns whether the presale is currently accepting purchases.
    public fun is_active(presale: &Presale): bool {
        presale.is_active
    }

    /// Returns the total SUI raised so far (in base units with 9 decimals).
    public fun sui_raised(presale: &Presale): u64 {
        balance::value(&presale.sui_raised)
    }

    /// Returns the number of tokens sold in a given stage (1-indexed).
    public fun stage_sold(presale: &Presale, stage: u8): u64 {
        let idx = (stage as u64) - 1;
        *vector::borrow(&presale.stage_sold, idx)
    }

    /// Returns the number of COVE tokens still held in the presale pool.
    public fun tokens_remaining(presale: &Presale): u64 {
        balance::value(&presale.token_pool)
    }

    /// Returns the sum of COVE that buyers have purchased but not yet
    /// claimed via `claim_vested()`. `withdraw_unsold_tokens()` will refuse
    /// to drain this portion of the pool. Useful for dashboards + tests.
    public fun outstanding_obligations(presale: &Presale): u64 {
        presale.outstanding_obligations
    }

    /// Returns the COVE in the pool that is NOT pledged to any buyer's
    /// vesting schedule — what `withdraw_unsold_tokens()` would yield if
    /// called now. Useful for admin-side previewing before finalize.
    public fun withdrawable_unsold(presale: &Presale): u64 {
        let pool = balance::value(&presale.token_pool);
        if (pool > presale.outstanding_obligations) {
            pool - presale.outstanding_obligations
        } else {
            0
        }
    }

    /// Returns the current rolling-window SUI withdrawal cap (base units).
    /// 0 means withdrawals are paused. Pentest L1 (2026-06-05).
    public fun sui_withdraw_cap(presale: &Presale): u64 {
        presale.sui_withdraw_cap
    }

    /// Returns the rolling window length, in milliseconds.
    public fun sui_withdraw_window_ms(presale: &Presale): u64 {
        presale.sui_withdraw_window_ms
    }

    /// Returns (window_start_ms, window_used_base_units) — how much SUI
    /// has been withdrawn since the current window opened. Dashboards
    /// use this to render a "X% of daily cap used" gauge.
    public fun sui_withdraw_window_state(presale: &Presale): (u64, u64) {
        (presale.sui_withdraw_window_start, presale.sui_withdraw_window_used)
    }

    /// Returns the current spot price on the bonding curve for the active stage
    /// (PRICE_SCALE-scaled). Divide by 1e18 to get the SUI-per-COVE price.
    public fun get_current_price(presale: &Presale): u64 {
        let stage_idx = (presale.current_stage as u64) - 1;
        let (start_price, end_price) = get_stage_prices(presale, presale.current_stage);
        let sold = *vector::borrow(&presale.stage_sold, stage_idx);
        calculate_current_price(start_price, end_price, sold)
    }

    // ─── State getters for the dashboard ────────────────────────────
    //
    // The frontend used to hardcode the price ladder + max-per-wallet
    // + vesting terms in TypeScript constants that mirrored the Move
    // consts. With those values now on-chain, the dashboard reads
    // them from the Presale shared object instead — these are the
    // accessors that expose them via the standard Sui object-read
    // path.

    public fun stage_start_prices(presale: &Presale): vector<u64> {
        presale.stage_start_prices
    }
    public fun stage_end_prices(presale: &Presale): vector<u64> {
        presale.stage_end_prices
    }
    public fun max_per_wallet_per_stage(presale: &Presale): u64 {
        presale.max_per_wallet_per_stage_value
    }
    public fun immediate_release_pct(presale: &Presale): u64 {
        presale.immediate_release_pct_value
    }
    public fun vesting_duration_ms(presale: &Presale): u64 {
        presale.vesting_duration_ms_value
    }
    public fun parameters_frozen(presale: &Presale): bool {
        presale.parameters_frozen
    }

    // ======================== Migration Functions =============================

    /// Migrate the `Presale` shared object to the current package version.
    ///
    /// After a package upgrade that bumps `VERSION`, the admin must call this
    /// before any other mutating function will accept the object. Aborts if
    /// already at current version (prevents accidental double-migration).
    ///
    /// Admin only.
    public fun migrate_presale(
        admin_reg: &AdminRegistry,
        presale: &mut Presale,
        ctx: &TxContext
    ) {
        // Super-admin only: version migrations follow package upgrades.
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(presale.version < VERSION, EWrongVersion);
        presale.version = VERSION;
    }

    /// Migrate the `PurchaseRegistry` shared object to the current package version.
    ///
    /// Same pattern as `migrate_presale()`. Requires the `AdminRegistry` reference
    /// to verify admin identity.
    ///
    /// Admin only.
    public fun migrate_registry(
        admin_reg: &AdminRegistry,
        registry: &mut PurchaseRegistry,
        ctx: &TxContext
    ) {
        // Super-admin only: version migrations follow package upgrades.
        assert!(admin_registry::is_super_admin(admin_reg, tx_context::sender(ctx)), ENotAdmin);
        assert!(registry.version < VERSION, EWrongVersion);
        registry.version = VERSION;
    }

    // ====================== Test-only helpers =================================

    /// Insert a synthetic `UserPurchase` directly into the registry. Used by
    /// regression tests that need to drive the vesting math at the per-wallet
    /// cap without spinning up a full 5-stage scenario. Production code MUST
    /// NOT call this; the `#[test_only]` attribute keeps it out of the
    /// published bytecode.
    #[test_only]
    public fun insert_purchase_for_testing(
        presale: &mut Presale,
        registry: &mut PurchaseRegistry,
        buyer: address,
        total_purchased: u64,
        purchase_time: u64,
    ) {
        // If this buyer already had a synthetic purchase, undo its
        // obligation contribution before overwriting — otherwise we'd
        // double-count obligations across repeated injections.
        if (table::contains(&registry.purchases, buyer)) {
            let old = table::remove(&mut registry.purchases, buyer);
            let unreleased = if (old.total_purchased > old.tokens_released) {
                old.total_purchased - old.tokens_released
            } else {
                0
            };
            if (presale.outstanding_obligations >= unreleased) {
                presale.outstanding_obligations =
                    presale.outstanding_obligations - unreleased;
            } else {
                presale.outstanding_obligations = 0;
            };
        };

        let purchase = UserPurchase {
            purchased_per_stage: vector[total_purchased / 5, total_purchased / 5, total_purchased / 5, total_purchased / 5, total_purchased / 5],
            total_purchased,
            tokens_released: 0,
            sui_paid: 0,
            purchase_time,
        };
        table::add(&mut registry.purchases, buyer, purchase);

        // Match what purchase() does — bump obligations so claim_vested's
        // decrement doesn't underflow. (Pentest C1, 2026-06-05.)
        presale.outstanding_obligations = presale.outstanding_obligations + total_purchased;
    }

    /// Deposit COVE into the presale pool for test purposes — used to seed
    /// the pool when `insert_purchase_for_testing` simulates a buy that
    /// bypasses the normal `purchase()` path (which would otherwise be the
    /// thing depositing into `token_pool`).
    #[test_only]
    public fun seed_pool_for_testing(
        presale: &mut Presale,
        coin: Coin<COVE_TOKEN>,
    ) {
        balance::join(&mut presale.token_pool, coin::into_balance(coin));
    }

}
