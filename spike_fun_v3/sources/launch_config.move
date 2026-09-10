module hoglet_core::launch_config {
    use std::error;
    use std::signer::address_of;
    use std::option;
    use std::simple_map::{Self, SimpleMap};
    use std::vector;
    use aptos_std::math128;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::object::{Self, Object};
    use supra_framework::coin;
    use supra_framework::fungible_asset::{Self, Metadata};
    // [V3-TAX-AWARE] Detector de tokens smart (launcher-launched) con TaxFreeCap
    use dao_factory::petra;
    use dao_factory::tax_router;
    // v3: SUPRA pivot via the AMM's TWAP oracle (one-shot at quote registration).
    use spike_amm::amm_oracle;

    friend hoglet_core::hoglet_core;
    friend hoglet_core::migration;
    friend hoglet_core::launch_vault;
    
    // Constants from original hoglet_core
    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_INITIALIZED: u64 = 3;
    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_OUT_OF_THE_RANGE: u64 = 23;
    const ERROR_INVALID_RAISE_LIMITS: u64 = 24;
    const ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO: u64 = 26;
    const ERROR_INVALID_UNSTAKE_PERIOD: u64 = 32;
    const ERROR_FEE_TOO_HIGH: u64 = 19;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_PUMP_NOT_COMPLETED: u64 = 14;
    const ERROR_TOKEN_DECIMAL: u64 = 10;
    const ERROR_INVALID_IASSET: u64 = 33;
    // v3: quote whitelist errors
    const ERROR_QUOTE_NOT_REGISTERED: u64 = 34;
    const ERROR_QUOTE_ALREADY_REGISTERED: u64 = 35;
    const ERROR_QUOTE_NOT_PURE_FA: u64 = 36;
    const ERROR_QUOTE_INVALID_PARAMS: u64 = 37;
    const ERROR_QUOTE_NOT_ENABLED: u64 = 38;
    const ERROR_QUOTE_NO_ORACLE: u64 = 39;
    const ERROR_QUOTE_RAISE_EXCEEDS_U64: u64 = 40;
    const U64_MAX_AS_U128: u128 = 18446744073709551615u128;
    /// SUPRA raw units per ONE whole SUPRA (the trivial pivot for the native quote).
    const SUPRA_RAW_PER_WHOLE: u128 = 100_000_000;

    const DECIMALS: u64 = 100_000_000;
    const MAX_PLATFORM_FEE_BPS: u64 = 300; 
    const MIN_UNSTAKE_PERIOD: u64 = 2_592_000; 
    const MAX_UNSTAKE_PERIOD: u64 = 31_536_000; 
    const MAX_CREATOR_FEE_BPS: u64 = 300; 
    const MAX_MIGRATOR_REWARD_BPS: u64 = 300; 
    const MAX_VIRTUAL_MULTIPLIER: u64 = 1000; 
    const MIN_VIRTUAL_MULTIPLIER: u64 = 10; 
    const MAX_RAISING_PERCENTAGE: u64 = 5000; 
    const MAX_TOKEN_DECIMALS: u8 = 18;
    const MIN_TOKEN_DECIMALS: u8 = 6;
    const MAX_SUPPLY_DEVIATION_TOLERANCE_BPS: u64 = 5000; 

    struct PumpConfig has key, store {
        admin_address: address,
        creator_fee_bps: u64,
        platform_fee: u64,
        deploy_fee: u64,
        resource_cap: SignerCapability,
        platform_fee_address: address,
        benefitiary_address_for_excess: address,
        raise_limit_min: u64,
        raise_limit_max: u64,
        staking_rate: u64,
        virtual_mult_range_meme: u64,
        virtual_mult_range_DAO: u64,
        virtual_mult_range_BIG_DAO: u64, 
        tokens_per_sup: u64,
        raising_percentage_meme: u64,
        raising_percentage_DAO: u64,
        raising_percentage_BIG_DAO: u64,
        token_decimals: u8,
        min_trade_supra_amount: u64,
        deadline: u64,
        unstake_period_seconds_default: u64,
        unstake_period_seconds_min: u64,
        unstake_period_seconds_max: u64,
        migrator_reward_bps: u64,
        migration_slippage_bps: u64,
        staking_reward_meme_bps: u64,
    }


    public fun initialize(
        admin: &signer,
        signer_cap: SignerCapability
    ) {
        assert!(!exists<PumpConfig>(address_of(admin)), error::already_exists(ERROR_INITIALIZED));
        
        move_to(
            admin,
            PumpConfig {
                admin_address: address_of(admin),
                creator_fee_bps: 13, //0.13% creator fee
                platform_fee: 17, //0.17% platform fee (much lower)
                deploy_fee: 137 * DECIMALS, //137 SUPRA deploy fee (~$0.02)
                platform_fee_address: address_of(admin),
                benefitiary_address_for_excess: address_of(admin),
                resource_cap: signer_cap,
                staking_rate: 1370,
                raise_limit_min: 37_137_137_000_000, //371,371.37 SUPRA (~$78 USD)
                raise_limit_max: 371_371_371_000_000,//3,713,713.71 SUPRA (~$780 USD)
                virtual_mult_range_meme: 137, 
                virtual_mult_range_DAO: 131,
                virtual_mult_range_BIG_DAO: 71,
                tokens_per_sup: 137, //ratio tokens per sup
                raising_percentage_meme: 50, // 0.5% to dev
                raising_percentage_DAO: 50, // 0.5% to dev
                raising_percentage_BIG_DAO: 100, // 1% to dev
                token_decimals: 8,
                min_trade_supra_amount: 137_000_000, //1.37 SUPRA
                deadline: 13700,
                unstake_period_seconds_default: 2592000, //30 days
                unstake_period_seconds_min: MIN_UNSTAKE_PERIOD,
                unstake_period_seconds_max: MAX_UNSTAKE_PERIOD,
                migrator_reward_bps: 1, //0.01% migrator reward
                migration_slippage_bps: 371, //3.71%
                staking_reward_meme_bps: 50, // 0.5% staking reward
            }
        );

        // [AUDIT-V3-6] Eager-initialize BOTH lazy resources at initialization
        // time, when the caller IS guaranteed to be @hoglet_core (hoglet init
        // asserts it). The lazy `move_to(admin, ...)` fallback wrote to the
        // current admin's address: after transfer_admin the first add_quote /
        // set_buffer_target wrote to the WRONG account forever (reads always
        // use @hoglet_core). With eager init, every write below targets
        // @hoglet_core through borrow_global_mut and cannot miscarry.
        move_to(
            admin,
            QuoteWhitelist { quotes: simple_map::new<address, QuoteConfig>() },
        );
        move_to(
            admin,
            BufferTarget { iasset_address: @0x0, is_enabled: false },
        );
    }



    public(friend) fun get_resource_signer(): signer acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        account::create_signer_with_capability(&config.resource_cap)
    }

    #[view]
    public fun get_resource_address(): address acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        account::get_signer_capability_address(&config.resource_cap)
    }

    // Returns the current admin/controller address. Initially the deployer,
    // can be transferred to a DAO via transfer_admin().
    #[view]
    public fun get_admin(): address acquires PumpConfig {
        borrow_global<PumpConfig>(@hoglet_core).admin_address
    }

    // Transfers admin control to a new address (e.g., a DAO contract).
    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires PumpConfig {
        let config = borrow_global_mut<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert!(new_admin != @0x0, error::invalid_argument(ERROR_OUT_OF_THE_RANGE)); // Prevent burning the admin
        config.admin_address = new_admin;
    }

    public fun is_meme_project(raising: u64): bool acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        let min_limit = config.raise_limit_min;
        let max_limit = config.raise_limit_max;
        let lower_threshold = (((max_limit - min_limit) / 3) + min_limit);
        raising <= lower_threshold
    }

    public entry fun update_config(
        admin: &signer,
        new_creator_fee_bps: u64,
        new_platform_fee: u64,
        new_deploy_fee: u64,
        new_platform_fee_address: address,
        new_benefitiary_address_for_excess: address,
        new_raise_limit_min: u64,
        new_raise_limit_max: u64,
        new_virtual_mult_range_meme: u64,
        new_virtual_mult_range_DAO: u64,
        new_virtual_mult_range_BIG_DAO: u64,
        new_tokens_per_sup: u64,
        new_raising_percentage_meme: u64,
        new_raising_percentage_DAO: u64,
        new_raising_percentage_BIG_DAO: u64,
        new_staking_rate: u64,
        new_unstake_period_seconds_min: u64,
        new_unstake_period_seconds_max: u64,
        new_unstake_period_seconds_default: u64,
        new_migrator_reward_bps: u64,
        new_token_decimals: u8,
        new_min_trade_supra_amount: u64,
        new_deadline: u64,
        new_migration_slippage_bps: u64,
        new_staking_reward_meme_bps: u64
    ) acquires PumpConfig {
        let config = borrow_global_mut<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));

        assert!(new_platform_fee <= MAX_PLATFORM_FEE_BPS, error::invalid_argument(ERROR_FEE_TOO_HIGH));
        assert!(new_creator_fee_bps <= MAX_CREATOR_FEE_BPS, error::invalid_argument(ERROR_FEE_TOO_HIGH));
        assert!(new_migrator_reward_bps <= MAX_MIGRATOR_REWARD_BPS, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_staking_reward_meme_bps <= MAX_MIGRATOR_REWARD_BPS, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_migration_slippage_bps <= 10000, error::invalid_argument(ERROR_SLIPPAGE_TOO_HIGH));
        assert!(new_tokens_per_sup > 0 && new_tokens_per_sup <= 10_000, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_unstake_period_seconds_default >= MIN_UNSTAKE_PERIOD && new_unstake_period_seconds_default <= MAX_UNSTAKE_PERIOD, error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD));
        
        assert!(new_virtual_mult_range_meme <= MAX_VIRTUAL_MULTIPLIER && new_virtual_mult_range_meme >= MIN_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_virtual_mult_range_DAO <= MAX_VIRTUAL_MULTIPLIER && new_virtual_mult_range_DAO >= MIN_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_virtual_mult_range_BIG_DAO <= MAX_VIRTUAL_MULTIPLIER && new_virtual_mult_range_BIG_DAO >= MIN_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        
        assert!(new_raising_percentage_meme <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_raising_percentage_DAO <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_raising_percentage_BIG_DAO <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        
        assert!(new_token_decimals <= MAX_TOKEN_DECIMALS && new_token_decimals >= MIN_TOKEN_DECIMALS, error::invalid_argument(ERROR_TOKEN_DECIMAL));
        
        assert!(new_unstake_period_seconds_min >= MIN_UNSTAKE_PERIOD && new_unstake_period_seconds_max <= MAX_UNSTAKE_PERIOD, error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD));
        assert!(new_unstake_period_seconds_min <= new_unstake_period_seconds_max, error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD));
        assert!(new_raise_limit_min < new_raise_limit_max, error::invalid_argument(ERROR_INVALID_RAISE_LIMITS));

        // SECURITY FIX (L-08): Sanity bounds to protect against malicious/incorrect DAO governance
        assert!(new_deploy_fee <= 10000 * DECIMALS, error::invalid_argument(ERROR_FEE_TOO_HIGH));
        assert!(new_deadline >= 600 && new_deadline <= 604800, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_raise_limit_max <= 100_000_000 * DECIMALS, error::invalid_argument(ERROR_INVALID_RAISE_LIMITS));
        assert!(new_min_trade_supra_amount <= 1000 * DECIMALS, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));

        config.creator_fee_bps = new_creator_fee_bps;
        config.platform_fee = new_platform_fee;
        config.benefitiary_address_for_excess = new_benefitiary_address_for_excess;
        config.deploy_fee = new_deploy_fee;
        config.platform_fee_address = new_platform_fee_address;
        config.raise_limit_min = new_raise_limit_min;
        config.raise_limit_max = new_raise_limit_max;
        config.staking_rate = new_staking_rate;
        config.virtual_mult_range_meme = new_virtual_mult_range_meme;
        config.virtual_mult_range_DAO = new_virtual_mult_range_DAO;
        config.virtual_mult_range_BIG_DAO = new_virtual_mult_range_BIG_DAO;
        config.tokens_per_sup = new_tokens_per_sup;
        config.raising_percentage_meme = new_raising_percentage_meme;
        config.raising_percentage_DAO = new_raising_percentage_DAO;
        config.raising_percentage_BIG_DAO = new_raising_percentage_BIG_DAO;
        config.token_decimals = new_token_decimals;
        config.min_trade_supra_amount = new_min_trade_supra_amount;
        config.deadline = new_deadline;
        config.unstake_period_seconds_default = new_unstake_period_seconds_default;
        config.unstake_period_seconds_min = new_unstake_period_seconds_min;
        config.unstake_period_seconds_max = new_unstake_period_seconds_max;
        config.migrator_reward_bps = new_migrator_reward_bps;
        config.migration_slippage_bps = new_migration_slippage_bps;
        config.staking_reward_meme_bps = new_staking_reward_meme_bps;
    }

    #[view]
    public fun get_platform_fees(): (u64, u64, u64, address) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        (config.platform_fee, config.deploy_fee, config.creator_fee_bps, config.platform_fee_address)
    }

    #[view]
    public fun get_raise_limits_config(): (u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        (config.raise_limit_min, config.raise_limit_max)
    }

    #[view]
    public fun get_virtual_mult_ranges(): (u64, u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        (config.virtual_mult_range_meme, config.virtual_mult_range_DAO, config.virtual_mult_range_BIG_DAO)
    }

    #[view]
    public fun get_raising_percentages(): (u64, u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        (config.raising_percentage_meme, config.raising_percentage_DAO, config.raising_percentage_BIG_DAO)
    }

    #[view]
    public fun get_token_decimals(): u8 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.token_decimals
    }

    #[view]
    public fun get_unstake_period_default(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.unstake_period_seconds_default
    }

    // [FIX-H2] Returns the (min, max) bounds for deployer-chosen unstake periods.
    // Used by hoglet_core::deploy_internal to validate the caller's input.
    #[view]
    public fun get_unstake_period_range(): (u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        (config.unstake_period_seconds_min, config.unstake_period_seconds_max)
    }

    #[view]
    public fun get_tokens_per_sup(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.tokens_per_sup
    }

    #[view]
    public fun get_benefitiary_address_for_excess(): address acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.benefitiary_address_for_excess
    }

    #[view]
    public fun get_migrator_reward_bps(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.migrator_reward_bps
    }

    #[view]
    public fun get_migration_slippage_bps(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.migration_slippage_bps
    }
    #[view]
    public fun get_staking_reward_meme_bps(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.staking_reward_meme_bps
    }

    #[view]
    public fun get_min_trade_supra_amount(): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        config.min_trade_supra_amount
    }

    // =================================================================
    // M4/M3 FIX: Buffer Target Configuration
    // =================================================================
    struct BufferTarget has key, store {
        iasset_address: address,
        is_enabled: bool,
    }

    public entry fun set_buffer_target(admin: &signer, iasset_address: address, is_enabled: bool) acquires PumpConfig, BufferTarget {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        
        // Validation: Ensure the target is a valid FungibleAsset or 0x0 (disabled)
        assert!(
            object::object_exists<Metadata>(iasset_address) || iasset_address == @0x0, 
            error::invalid_argument(ERROR_INVALID_IASSET)
        );

        // [AUDIT-V3-6] Eager-initialized at @hoglet_core by initialize(); the
        // v2-style lazy fallback moved_to(admin) and could fork the target
        // after transfer_admin. Mutate instead.
        let bt = borrow_global_mut<BufferTarget>(@hoglet_core);
        bt.iasset_address = iasset_address;
        bt.is_enabled = is_enabled;
    }

    #[view]
    public fun is_buffer_enabled(): bool acquires BufferTarget {
        if (exists<BufferTarget>(@hoglet_core)) {
            borrow_global<BufferTarget>(@hoglet_core).is_enabled
        } else {
            false
        }
    }

    #[view]
    public fun get_buffer_iasset_address(): address acquires BufferTarget {
        assert!(exists<BufferTarget>(@hoglet_core), error::not_found(ERROR_INITIALIZED));
        borrow_global<BufferTarget>(@hoglet_core).iasset_address
    }

    // =================================================================
    // v3: Per-launch quote whitelist
    // Everyone who deploys a token picks ONE quote from this whitelist;
    // the whole bonding curve then runs in that quote's units (FA-native).
    // The address stored MUST be the AMM-canonical one:
    //   - pure FA:          its own Metadata address
    //   - legacy coin:      its spike_amm coin_wrapper address (bwsup pattern)
    //   - iAsset (buffer):  the iasset Metadata address (buffer exchange route)
    // Gateway-paired FAs (paired CoinInfo) are rejected so the AMM's internal
    // coin->wrapper canonicalization can never fork the quote identity.
    // =================================================================
    // `drop` is required: quote params are plain admin data (u64s + bool) that
    // must be destructible when replaced from the whitelist or removed entirely
    // (e.g. `*qc_ref = ...`, `simple_map::remove` dropping the old value).
    struct QuoteConfig has copy, drop, store {
        /// Whole launch-token units per WHOLE quote unit (e.g. 137 tokens per 1 BTC).
        /// Virtual reserves: v_token_quote_field = v_quote * price_ratio * 10^token_dec / 10^quote_dec.
        price_ratio_whole: u64,
        /// Minimum trade size in RAW quote units (per-quote replacement of min_trade_supra_amount).
        min_trade_amount: u64,
        /// Raise target bounds in RAW quote units (per-quote replacement of raise_limit_min/max).
        raising_min: u64,
        raising_max: u64,
        enabled: bool,
    }

    /// Kept as its own resource; eagerly initialized by initialize() at
    /// @hoglet_core (see [AUDIT-V3-6] there).
    struct QuoteWhitelist has key {
        quotes: SimpleMap<address, QuoteConfig>,
    }

    // [AUDIT-V3-5] Quote FAs with dispatchable hooks would tax pool
    // withdrawals (seller-slippage DoS) and could abort migrations.
    const ERROR_QUOTE_HAS_HOOKS: u64 = 41;

    // [V3-SUPRA-TRACK] The network-native SUPRA fungible asset: created by the
    // framework at genesis as a sticky object at @supra_fungible_asset (0xA)
    // (coin.move::create_and_return_paired_metadata_if_not_exist). It IS paired
    // to the legacy Coin<SupraCoin> BY DESIGN the paired-FA rejection below
    // must not fire for it. It is the only legal paired-FA quote.
    const SUPRA_NATIVE_FA: address = @0xa;

    #[view]
    public fun is_supra_native_fa(quote: address): bool {
        quote == SUPRA_NATIVE_FA
    }

    /// [V3-TAX-AWARE] True when the quote is one of OUR OWN launcher-launched
    /// DAO smart_tokens: detected via the dao_factory registry + the
    /// dao_tax_router's TaxFreeRouter (minted at its own migration). Their tax
    /// hooks are bypassed at pool-custody level via the DAO's own cap, so the
    /// curve math remains exact 1:1 while the token keeps its DAO economy.
    #[view]
    public fun is_quote_tax_aware_capable(quote: address): bool {
        // SUPRA nativa ya tiene su propio track sin taxes.
        if (quote == SUPRA_NATIVE_FA) { return false };
        let metadata = object::address_to_object<Metadata>(quote);
        let dao_opt = petra::get_dao_for_token(metadata);
        if (option::is_some(&dao_opt)) {
            return tax_router::has_tax_free_router(*option::borrow(&dao_opt));
        };
        false
    }

    /// [FIX-M1/HOOK-BAIT] Public wrapper for the cross-module re-probe: hoglet's
    /// deploy runs it per-deploy so a maker that whitelisted a clean FA cannot
    /// graft dispatch hooks post-whitelist without aborting the deploy.
    public fun validate_quote_is_pure_canonical_fa(admin: &signer, quote: address) {
        assert_quote_is_pure_canonical_fa(admin, quote)
    }

    inline fun assert_quote_is_pure_canonical_fa(admin: &signer, quote: address) {
        assert!(quote != @0x0, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(
            object::object_exists<Metadata>(quote),
            error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS)
        );
        let metadata = object::address_to_object<Metadata>(quote);
        // [V3-SUPRA-TRACK] The network-native SUPRA FA is the legal exception: it
        // is paired to the legacy coin by the framework itself, yet it is THE
        // platform-native identity of SUPRA (wallets hold it as their SUPRA
        // balance; the framework merges both representations on withdraw). It
        // also cannot carry dispatch hooks (the framework guarantees SUPRA is
        // never dispatchable), so the skip covers the hook probe too.
        // [E14003] Inline fns of this Move version have no early `return`
        // express the exception as an inverted condition instead.
        if (quote != SUPRA_NATIVE_FA) {
            // [V3-TAX-AWARE] Launcher-launched smart_tokens with a TaxFreeRouter
            // (their DAO's own dao_tax_router) are the LEGAL exception: the DAO's
            // own TaxFreeCap bypasses their tax hooks (audit9 H-2, audit10 C3),
            // so the pool custody operations run tax-free at exact amounts and
            // the curve math remains deterministic. The dispatch-rejection and
            // probe below apply only to everything else.
            if (!is_quote_tax_aware_capable(quote)) {
                // Reject gateway-paired FAs: a paired metadata address would canonicalize
                // to its V1 wrapper inside the AMM and fork the pair identity.
                assert!(
                    option::is_none(&coin::paired_coin(metadata)),
                    error::invalid_argument(ERROR_QUOTE_NOT_PURE_FA)
                );

                // [AUDIT-V3-5] The dispatch registry lives at the metadata address and
                // is only readable through a store object -> probe with a throwaway
                // store owned by the admin. ANY registered dispatch function (deposit
                // or withdraw) rejects the quote. One cheap admin tx per registration;
                // the probe objects are inert dust afterwards.
                let probe_constr = object::create_object_from_object(admin);
                let probe_store = fungible_asset::create_store(&probe_constr, metadata);
                assert!(
                    !fungible_asset::is_store_dispatchable(probe_store),
                    error::invalid_argument(ERROR_QUOTE_HAS_HOOKS)
                );
            };
        };
    }

    /// [AUDIT-overflow] Pivot derivation runs ENTIRELY in u256:
    /// `raise_limit X 10^quote_dec` overflows u128 for high-decimal quotes
    /// (the old math128::mul_div path multiplied its ARGUMENTS in u128),
    /// and mul_div silently truncates results with `as u128`.
    /// Returns (price_ratio_whole, min_trade_amount, raising_min, raising_max).
    fun derive_quote_params_internal(config: &PumpConfig, quote_obj: Object<Metadata>, supra_per_quote_whole: u128): (u64, u64, u64, u64) {
        let supra_per_quote_u256 = (supra_per_quote_whole as u256);
        let tokens_per_sup_u256 = (config.tokens_per_sup as u256);
        // pow(10, dec) fits u128 for any feasible FA decimals (<= 32 = 10^32 < u128 max);
        // constants are only widened here. Divisors are >= 1: pow(10, 0) = 1, price > 0.
        let token_dec_factor_u256 = (math128::pow((10 as u128), (config.token_decimals as u128)) as u256);
        let quote_dec_factor_u256 = (math128::pow((10 as u128), (fungible_asset::decimals(quote_obj) as u128)) as u256);

        // whole tokens / whole quote = token_raw-per-supra_raw * supra_raw-per-whole-quote / 10^token_dec
        let price_ratio_whole_u256 = tokens_per_sup_u256 * supra_per_quote_u256 / token_dec_factor_u256;
        assert!(price_ratio_whole_u256 > 0, error::invalid_state(ERROR_QUOTE_NO_ORACLE));
        assert!(price_ratio_whole_u256 <= (U64_MAX_AS_U128 as u256), error::invalid_state(ERROR_QUOTE_INVALID_PARAMS));

        // quote_raw = supra_raw * 10^quote_dec / supra_per_quote_whole
        let raising_min_u256 = (config.raise_limit_min as u256) * quote_dec_factor_u256 / supra_per_quote_u256;
        let raising_max_u256 = (config.raise_limit_max as u256) * quote_dec_factor_u256 / supra_per_quote_u256;
        let min_trade_u256 = (config.min_trade_supra_amount as u256) * quote_dec_factor_u256 / supra_per_quote_u256;

        // Pool raise targets and AMM liquidity amounts are u64 across the stack:
        // quote raw raise bounds must be representable. Too-cheap tokens' raises
        // explode past u64 abort with a dedicated error instead of truncating.
        assert!(raising_max_u256 <= (U64_MAX_AS_U128 as u256), error::invalid_state(ERROR_QUOTE_RAISE_EXCEEDS_U64));
        assert!(raising_min_u256 > 0, error::invalid_state(ERROR_QUOTE_INVALID_PARAMS));
        assert!(min_trade_u256 > 0, error::invalid_state(ERROR_QUOTE_INVALID_PARAMS));

        (
            (price_ratio_whole_u256 as u64),
            (min_trade_u256 as u64),
            (raising_min_u256 as u64),
            (raising_max_u256 as u64)
        )
    }

    public entry fun add_quote(
        admin: &signer,
        quote: address,
        price_ratio_whole: u64,
        min_trade_amount: u64,
        raising_min: u64,
        raising_max: u64
    ) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert_quote_is_pure_canonical_fa(admin, quote);

        assert!(price_ratio_whole > 0, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(min_trade_amount > 0, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(raising_min < raising_max, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        // Sanity caps (raw quote units): price ratio <= 10^12, raise cap <= 10^16.
        assert!(price_ratio_whole <= 1_000_000_000_000, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(raising_max <= 10_000_000_000_000_000, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));

        // [AUDIT-V3-6] QuoteWhitelist is eager-initialized at @hoglet_core by
        // initialize() never lazily written here (a post-transfer_admin lazy
        // write would land on the wrong account, forking the whitelist).
        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        // simple_map::add aborts on duplicates: re-adding must be an explicit remove+add.
        simple_map::add(&mut whitelist.quotes, quote, QuoteConfig {
            price_ratio_whole,
            min_trade_amount,
            raising_min,
            raising_max,
            enabled: true,
        });
    }

    public entry fun update_quote_params(
        admin: &signer,
        quote: address,
        price_ratio_whole: u64,
        min_trade_amount: u64,
        raising_min: u64,
        raising_max: u64
    ) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert!(
            exists<QuoteWhitelist>(@hoglet_core),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        assert!(price_ratio_whole > 0, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(min_trade_amount > 0, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(raising_min < raising_max, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(price_ratio_whole <= 1_000_000_000_000, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));
        assert!(raising_max <= 10_000_000_000_000_000, error::invalid_argument(ERROR_QUOTE_INVALID_PARAMS));

        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        assert!(
            simple_map::contains_key(&whitelist.quotes, &quote),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let qc_ref = simple_map::borrow_mut(&mut whitelist.quotes, &quote);
        qc_ref.price_ratio_whole = price_ratio_whole;
        qc_ref.min_trade_amount = min_trade_amount;
        qc_ref.raising_min = raising_min;
        qc_ref.raising_max = raising_max;
    }

    public entry fun set_quote_enabled(
        admin: &signer,
        quote: address,
        enabled: bool
    ) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert!(
            exists<QuoteWhitelist>(@hoglet_core),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        assert!(
            simple_map::contains_key(&whitelist.quotes, &quote),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        // In-place mutation via borrow_mut: no struct copy/replacement needed,
        // and `enabled` toggling keeps every other field untouched by construction.
        let qc_ref = simple_map::borrow_mut(&mut whitelist.quotes, &quote);
        qc_ref.enabled = enabled;
    }

    /// Registers a quote deriving ALL its economics from the SUPRA pivot with a
    /// one-shot TWAP snapshot taken at registration time (never consulted again):
    ///
    ///   supra_per_quote = amm_oracle::get_average_price_v2(quote)   // SUPRA-raw per 1 whole quote
    ///   price_ratio     = tokens_per_sup * supra_per_quote / 10^token_dec  (whole tokens / whole quote)
    ///   min_trade_quote = min_trade_supra_amount       * 10^quote_dec / supra_per_quote
    ///   raising_quote   = raise_limit_min/max          * 10^quote_dec / supra_per_quote
    ///
    /// Runtime flows (deploy / buy / sell / migration) depend ONLY on the stored
    /// config no keeper uptime needed outside this single admin call.
    /// `update_quote_params` remains available as a manual override for special cases.
    public entry fun add_quote_with_oracle(admin: &signer, quote: address) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert_quote_is_pure_canonical_fa(admin, quote);

        let quote_obj = object::address_to_object<Metadata>(quote);
        // [V3-SUPRA-TRACK] The native SUPRA quote needs NO oracle: its pivot is
        // trivial (1 SUPRA = SUPRA_RAW_PER_WHOLE). Every other quote uses the
        // TWAP snapshot as usual.
        let supra_per_quote_whole = if (quote == SUPRA_NATIVE_FA) {
            SUPRA_RAW_PER_WHOLE
        } else {
            amm_oracle::get_average_price_v2(quote_obj)
        };
        // No oracle path / no observation / no liquidity: refuse rather than
        // whitelist a quote with a zero (or unstateable) pivot price.
        assert!(supra_per_quote_whole > 0, error::invalid_state(ERROR_QUOTE_NO_ORACLE));

        let (price_ratio_whole, min_trade_amount, raising_min, raising_max) =
            derive_quote_params_internal(config, quote_obj, supra_per_quote_whole);

        // [AUDIT-V3-6] Same eager-init guarantee as the manual add_quote path.
        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        // simple_map::add aborts on duplicates: re-adding must be an explicit remove+add.
        simple_map::add(&mut whitelist.quotes, quote, QuoteConfig {
            price_ratio_whole,
            min_trade_amount,
            raising_min,
            raising_max,
            enabled: true,
        });
    }

    #[view]
    public fun get_quote_decimals(quote: address): u8 {
        let metadata = object::address_to_object<Metadata>(quote);
        fungible_asset::decimals(metadata)
    }

    /// Re-derives the SUPRA pivot for an already-registered quote with a fresh
    /// TWAP snapshot (same math as add_quote_with_oracle). Use it when market
    /// drift makes the stored raise bounds stale. Admin-only, one oracle call,
    /// runtime flows still never touch the oracle.
    public entry fun refresh_quote_with_oracle(admin: &signer, quote: address) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert_quote_is_pure_canonical_fa(admin, quote);
        assert!(
            exists<QuoteWhitelist>(@hoglet_core),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );

        let quote_obj = object::address_to_object<Metadata>(quote);
        // [V3-SUPRA-TRACK] Same trivial pivot as add_quote_with_oracle the
        // SUPRA native quote re-derives the same identity values every time.
        let supra_per_quote_whole = if (quote == SUPRA_NATIVE_FA) {
            SUPRA_RAW_PER_WHOLE
        } else {
            amm_oracle::get_average_price_v2(quote_obj)
        };
        assert!(supra_per_quote_whole > 0, error::invalid_state(ERROR_QUOTE_NO_ORACLE));

        let (price_ratio_whole, min_trade_amount, raising_min, raising_max) =
            derive_quote_params_internal(config, quote_obj, supra_per_quote_whole);

        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        assert!(
            simple_map::contains_key(&whitelist.quotes, &quote),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let qc_ref = simple_map::borrow_mut(&mut whitelist.quotes, &quote);
        let old_enabled = qc_ref.enabled;
        // In-place whole-struct replacement via ref (no copy/replace dance):
        // derives params are final (u256-checked), enabled flag is preserved.
        *qc_ref = QuoteConfig {
            price_ratio_whole,
            min_trade_amount,
            raising_min,
            raising_max,
            enabled: old_enabled,
        };
    }

    /// Disabling alone is not enough once pools were opened against the quote.
    /// Removal is intended for entries that were never used.
    public entry fun remove_quote(admin: &signer, quote: address) acquires PumpConfig, QuoteWhitelist {
        let config = borrow_global<PumpConfig>(@hoglet_core);
        assert!(address_of(admin) == config.admin_address, error::permission_denied(ERROR_NO_AUTH));
        assert!(
            exists<QuoteWhitelist>(@hoglet_core),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let whitelist = borrow_global_mut<QuoteWhitelist>(@hoglet_core);
        simple_map::remove(&mut whitelist.quotes, &quote);
    }

    #[view]
    /// Returns (exists, enabled, price_ratio_whole, min_trade_amount, raising_min, raising_max).
    public fun get_quote_config(quote: address): (bool, bool, u64, u64, u64, u64) acquires QuoteWhitelist, PumpConfig {
        // [V3-SUPRA-DEFAULT] SUPRA native is ALWAYS available - no registration is even required: its pivot is the identity and its limits are the global ones of PumpConfig (identical to what `add_quote_with_oracle(0xA)` would register). The whitelist only ADDS extra quotes.
        if (quote == SUPRA_NATIVE_FA) {
            let config = borrow_global<PumpConfig>(@hoglet_core);
            return (
                true, true,
                config.tokens_per_sup,
                config.min_trade_supra_amount,
                config.raise_limit_min,
                config.raise_limit_max,
            )
        };
        if (!exists<QuoteWhitelist>(@hoglet_core)) { return (false, false, 0, 0, 0, 0) };
        let whitelist = borrow_global<QuoteWhitelist>(@hoglet_core);
        if (!simple_map::contains_key(&whitelist.quotes, &quote)) { return (false, false, 0, 0, 0, 0) };
        let qc = *simple_map::borrow(&whitelist.quotes, &quote);
        (true, qc.enabled, qc.price_ratio_whole, qc.min_trade_amount, qc.raising_min, qc.raising_max)
    }

    #[view]
    public fun is_quote_enabled(quote: address): bool acquires QuoteWhitelist {
        // [V3-SUPRA-DEFAULT] The native quote can never be disabled.
        if (quote == SUPRA_NATIVE_FA) { return true };
        if (!exists<QuoteWhitelist>(@hoglet_core)) { return false };
        let whitelist = borrow_global<QuoteWhitelist>(@hoglet_core);
        if (!simple_map::contains_key(&whitelist.quotes, &quote)) { return false };
        simple_map::borrow(&whitelist.quotes, &quote).enabled
    }

    #[view]
    // Field access on QuoteConfig is module-private: cross-module readers
    // (hoglet_core) must go through these getters.
    public fun get_quote_price_ratio(quote: address): u64 acquires QuoteWhitelist, PumpConfig {
        require_quote_config(quote).price_ratio_whole
    }

    #[view]
    public fun get_quote_min_trade_amount(quote: address): u64 acquires QuoteWhitelist, PumpConfig {
        require_quote_config(quote).min_trade_amount
    }

    // Returns the enabled entry or aborts: call-sites need the params, so a
    // missing/disabled quote must never proceed silently.
    // [V3-SUPRA-DEFAULT] SUPRA nativa (0xA) NO requiere registro: el default
    // implicit uses the identity as pivot and the global limits of
    // config a deploy with empty whitelist ALWAYS allows quote SUPRA.
    public fun require_quote_config(quote: address): QuoteConfig acquires QuoteWhitelist, PumpConfig {
        if (quote == SUPRA_NATIVE_FA) {
            let config = borrow_global<PumpConfig>(@hoglet_core);
            return QuoteConfig {
                price_ratio_whole: config.tokens_per_sup,
                min_trade_amount: config.min_trade_supra_amount,
                raising_min: config.raise_limit_min,
                raising_max: config.raise_limit_max,
                enabled: true,
            }
        };
        assert!(
            exists<QuoteWhitelist>(@hoglet_core),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let whitelist = borrow_global<QuoteWhitelist>(@hoglet_core);
        assert!(
            simple_map::contains_key(&whitelist.quotes, &quote),
            error::not_found(ERROR_QUOTE_NOT_REGISTERED)
        );
        let qc = *simple_map::borrow(&whitelist.quotes, &quote);
        assert!(qc.enabled, error::invalid_state(ERROR_QUOTE_NOT_ENABLED));
        qc
    }

    #[view]
    public fun get_all_quotes(): vector<address> acquires QuoteWhitelist {
        // [V3-SUPRA-DEFAULT] The list ALWAYS includes 0xA (append if the admin
        // has not registered it yet) the frontend never runs out of options.
        let out = if (!exists<QuoteWhitelist>(@hoglet_core)) {
            vector::empty<address>()
        } else {
            simple_map::keys(&borrow_global<QuoteWhitelist>(@hoglet_core).quotes)
        };
        let mut_found = false;
        let i = 0;
        let len = std::vector::length(&out);
        while (i < len) {
            if (*std::vector::borrow(&out, i) == SUPRA_NATIVE_FA) {
                mut_found = true;
            };
            i = i + 1;
        };
        if (!mut_found) {
            std::vector::push_back(&mut out, SUPRA_NATIVE_FA);
        };
        out
    }

    /// Mirrors hoglet_core's legacy (min, lower, upper, max) raise thresholds but
    /// denominated in RAW units of the chosen quote.
    /// [acquires] require_quote_config transitive-acquires PumpConfig (SUPRA
    /// implicit default path) the chain must be reflected here.
    public fun get_quote_raise_thresholds(quote: address): (u64, u64, u64, u64) acquires QuoteWhitelist, PumpConfig {
        let qc = require_quote_config(quote);
        let third = (qc.raising_max - qc.raising_min) / 3;
        (qc.raising_min, third + qc.raising_min, (third * 2) + qc.raising_min, qc.raising_max)
    }
}

