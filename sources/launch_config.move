module hoglet_core::launch_config {
    use std::error;
    use std::signer::address_of;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::object;
    use supra_framework::fungible_asset::Metadata;

    friend hoglet_core::hoglet_core;
    friend hoglet_core::migration;
    
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

        if (exists<BufferTarget>(@hoglet_core)) {
            let bt = borrow_global_mut<BufferTarget>(@hoglet_core);
            bt.iasset_address = iasset_address;
            bt.is_enabled = is_enabled;
        } else {
            move_to(admin, BufferTarget {
                iasset_address,
                is_enabled
            });
        }
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
}
