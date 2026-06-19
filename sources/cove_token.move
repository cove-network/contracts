/// COVE Token - The native token of the Cove Labs Decentralized Transcoding Network.
///
/// This module defines the COVE coin type using Sui's one-time witness (OTW) pattern.
/// It does NOT create any shared objects - the only outputs are:
///   - An owned `TreasuryCap<COVE_TOKEN>` (sent to deployer, later passed to `treasury.move`)
///   - A frozen `CoinMetadata` object (immutable on-chain token info)
///
/// Token economics:
///   - Total supply: 10B COVE with 9 decimal places
///   - Distribution: 25% presale, 25% team (4yr vest, 1yr cliff),
///                   30% liquidity, 10% community rewards, 10% reserve
///   - There is no public_sale pool — DEX listing takes over price discovery
///     post-presale.
///   - Actual minting happens in `treasury::initialize_distribution()`, not here
///
/// The TreasuryCap is the ONLY way to mint or burn COVE. Whoever holds it
/// controls supply. In production, it should be transferred into the Treasury
/// contract immediately after deployment.
module cove::cove_token {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::url;

    /// One-time witness struct. Sui requires this to match the module name
    /// (uppercase) and have only the `drop` ability. It's consumed during
    /// `init()` to create the coin type and can never be constructed again.
    public struct COVE_TOKEN has drop {}

    // =========================================================================
    // Constants - Token Supply & Distribution
    // =========================================================================

    /// Total supply: 10 billion tokens with 9 decimals (10B * 10^9)
    const TOTAL_SUPPLY: u64 = 10_000_000_000_000_000_000;

    /// Distribution amounts (all with 9 decimals applied).
    /// These are exposed via accessor functions for use by other contracts
    /// and off-chain tooling.
    const PRESALE_AMOUNT: u64 = 2_500_000_000_000_000_000;      // 25% - 2.5B
    const TEAM_AMOUNT: u64 = 2_500_000_000_000_000_000;         // 25% - 2.5B
    const LIQUIDITY_AMOUNT: u64 = 3_000_000_000_000_000_000;    // 30% - 3B
    const COMMUNITY_AMOUNT: u64 = 1_000_000_000_000_000_000;    // 10% - 1B
    const TREASURY_AMOUNT: u64 = 1_000_000_000_000_000_000;     // 10% - 1B (reserve pool)

    // =========================================================================
    // Init - Package publish entry point
    // =========================================================================

    /// Called exactly once when the package is published.
    /// Creates the COVE coin type with metadata, freezes the metadata so
    /// token name/symbol/icon can never be changed, and sends the TreasuryCap
    /// to the deployer's address.
    ///
    /// Next step after deployment: call `treasury::create_treasury()` and pass
    /// the TreasuryCap to lock it inside the Treasury shared object.
    #[allow(deprecated_usage)]
    fun init(witness: COVE_TOKEN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // 9 decimal places (same as SUI)
            b"COVE",
            b"Cove Token",
            b"The native token of the Cove Labs Decentralized Transcoding Network",
            option::some(url::new_unsafe_from_bytes(b"https://covelabs.io/token-icon.png")),
            ctx
        );

        // Freeze metadata - makes token info (name, symbol, icon) permanently immutable
        transfer::public_freeze_object(metadata);

        // Send TreasuryCap to deployer. This is an owned object that grants
        // mint/burn authority. Must be transferred to Treasury contract ASAP.
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    // =========================================================================
    // Public Functions - Burn
    // =========================================================================
    // Minting is done directly via `coin::mint` inside
    // `treasury::initialize_distribution()` (the TreasuryCap holder), so this
    // module intentionally exposes no mint wrapper.

    /// Permanently destroy COVE tokens, reducing circulating supply.
    /// Can only be called by the TreasuryCap holder.
    public fun burn(
        treasury_cap: &mut TreasuryCap<COVE_TOKEN>,
        coin: Coin<COVE_TOKEN>
    ) {
        coin::burn(treasury_cap, coin);
    }

    // =========================================================================
    // View Functions - Distribution Constants
    // =========================================================================
    // These expose the allocation amounts so other contracts and off-chain
    // tools can reference the canonical distribution without hardcoding values.

    public fun total_supply(): u64 { TOTAL_SUPPLY }
    public fun presale_amount(): u64 { PRESALE_AMOUNT }
    public fun team_amount(): u64 { TEAM_AMOUNT }
    public fun liquidity_amount(): u64 { LIQUIDITY_AMOUNT }
    public fun community_amount(): u64 { COMMUNITY_AMOUNT }
    public fun treasury_reserve_amount(): u64 { TREASURY_AMOUNT }

    // =========================================================================
    // Test Helpers
    // =========================================================================

    /// Creates a fresh COVE_TOKEN witness and calls init().
    /// Only available in test builds. Allows unit tests to set up the coin
    /// type without publishing the package.
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(COVE_TOKEN {}, ctx);
    }
}
