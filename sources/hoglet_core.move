module hoglet_core::hoglet_core {
    use std::error;
    use std::signer::address_of;
    use std::string::{String};
    use aptos_std::math64;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::primary_fungible_store;
    use supra_framework::account;
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::fungible_asset::Metadata;
    
    use hoglet_core::asset_manager;
    use hoglet_core::launch_config;
    use hoglet_core::math;
    use hoglet_core::pool;
    use hoglet_core::migration;
    use hoglet_core::hodl_fa;
    use dao_factory::petra;
    use spike_amm::amm_router;
    use spike_amm::coin_wrapper;
    use spike_amm::amm_pair;

    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 8;
    const ERROR_PUMP_AMOUNT_TO_LOW: u64 = 9;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 18;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 19;
    const ERROR_AMOUNT_TOO_LOW: u64 = 20;
    const ERROR_INVALID_RAISE: u64 = 22;
    const ERROR_INVALID_LENGTH: u64 = 1;
    const ERROR_HODL_FA_NOT_SUPPORTED: u64 = 33;
    const ERROR_HODL_PERIOD_NOT_FINISHED: u64 = 34;
    const ERROR_NAME_TOO_LONG: u64 = 35;
    const ERROR_SYMBOL_TOO_LONG: u64 = 36;
    /// [FIX-H2] Deployer passed an unstake_period_seconds outside the [min, max] range set in launch_config.
    const ERROR_INVALID_UNSTAKE_PERIOD: u64 = 37;
    /// [FIX-H1.2] stake() is blocked once the bonding curve has been completed.
    const ERROR_POOL_COMPLETED_NO_STAKE: u64 = 38;
    const ERROR_DESCRIPTION_TOO_LONG: u64 = 39;
    const ERROR_SOCIALS_TOO_LONG: u64 = 40;
    const ERROR_NAME_EMPTY: u64 = 41;
    const ERROR_SYMBOL_EMPTY: u64 = 42;

    #[event]
    struct PumpEvent has drop, store {
        pool_address: address,
        dev: address,
        name: String,
        symbol: String,
        token_address: address,
        uri: String,
        website: String,
        description: String,
        socials: String,
        initial_virtual_token_reserves: u128,
        initial_virtual_supra_reserves: u128,
        raising: u64,
        project_type: String,
    }

    #[event]
    struct TradeEvent has drop, store {
        supra_amount: u64,
        is_buy: bool,
        token_address: address,
        token_amount: u64,
        user: address,
        timestamp: u64,
    }

    struct PoolStateView has drop, store {
        virtual_token_reserves: u128,
        virtual_supra_reserves: u128,
        is_completed: bool,
        is_migrated_to_dex: bool,
        target_supra_dex_threshold: u64,
        dev_address: address,
    }

    fun init_module(admin: &signer) {
        assert!(address_of(admin) == @hoglet_core, error::permission_denied(ERROR_NO_AUTH));
        let (_, signer_cap) = account::create_resource_account(admin, b"pump_v2");
        launch_config::initialize(admin, signer_cap);
    }

    public entry fun deploy(
        caller: &signer,
        raising: u64,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        description: String,
        socials: String,
        unstake_period_seconds: u64
    ) {
        deploy_internal(caller, raising, name, symbol, uri, website, description, socials, unstake_period_seconds);
    }

    fun deploy_internal(
        caller: &signer,
        raising: u64,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        description: String,
        socials: String,
        unstake_period_seconds: u64
    ): address {
        assert!(std::string::length(&name) > 0, error::invalid_argument(ERROR_NAME_EMPTY));
        assert!(std::string::length(&name) <= 37, error::invalid_argument(ERROR_NAME_TOO_LONG));
        
        assert!(std::string::length(&symbol) > 0, error::invalid_argument(ERROR_SYMBOL_EMPTY));
        assert!(std::string::length(&symbol) <= 13, error::invalid_argument(ERROR_SYMBOL_TOO_LONG));
        
        assert!(std::string::length(&description) <= 731, error::invalid_argument(ERROR_DESCRIPTION_TOO_LONG));
        assert!(std::string::length(&socials) <= 1371, error::invalid_argument(ERROR_SOCIALS_TOO_LONG));

        let sender = address_of(caller);

        let (_, deploy_fee, _, platform_fee_address) = launch_config::get_platform_fees();
        if (deploy_fee > 0) {
            let deploy_fee_coin = coin::withdraw<SupraCoin>(caller, deploy_fee);
            if (coin::is_account_registered<SupraCoin>(platform_fee_address)) {
                coin::deposit(platform_fee_address, deploy_fee_coin);
            } else {
                coin::deposit(@hoglet_core, deploy_fee_coin);
            };
        };

        let (virtual_supra_reserves, virtual_token_reserves) = calculate_virtual_pools_internal(raising);
        let percentage_reward_bps = get_percentage_bps_reward_internal(raising);

        let resource_signer = launch_config::get_resource_signer();
        
        let is_meme = launch_config::is_meme_project(raising);
        
        let token_address = asset_manager::create_fa(
            name,
            symbol,
            launch_config::get_token_decimals(),
            uri,
            website,
            is_meme
        );

        asset_manager::register(token_address, caller);

        let token_obj = object::address_to_object<Metadata>(token_address);
        petra::claim_token_for_launcher(&resource_signer, token_obj);

        let pool_address = pool::create_pool(
            &resource_signer,
            token_address,
            virtual_token_reserves,
            virtual_supra_reserves,
            raising,
            percentage_reward_bps,
            sender,
            is_meme
        );
        let final_unstake_period = if (unstake_period_seconds > 0) {
            // [FIX-H2] Validate deployer-supplied unstake period is within the platform-configured range.
            let (min_period, max_period) = launch_config::get_unstake_period_range();
            assert!(
                unstake_period_seconds >= min_period && unstake_period_seconds <= max_period,
                error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD)
            );
            unstake_period_seconds
        } else {
            launch_config::get_unstake_period_default()
        };

        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);

        //register pair in amm to prevent manual creation attacks, and to ensure the LP Token Object exists before the Gauge is created
        amm_router::create_locked_pair_for_launchpad(
            &resource_signer,
            token_address,
            bwsup,
        );

        let amm_pool_addresses = std::vector::empty<address>();
        let supra_pool = amm_pair::liquidity_pool_address(token_obj, supra_metadata_obj);
        std::vector::push_back(&mut amm_pool_addresses, supra_pool);

        let supported_iassets = hoglet_buffer::manager::get_all_supported_iassets();
        let len = std::vector::length(&supported_iassets);
        let i = 0;
        while (i < len) {
            let iasset_obj = *std::vector::borrow(&supported_iassets, i);
            let symbol = supra_framework::fungible_asset::symbol(iasset_obj);
            if (symbol == std::string::utf8(b"iSUPRA")) {
                let iasset_addr = object::object_address(&iasset_obj);
                amm_router::create_locked_pair_for_launchpad(
                    &resource_signer,
                    token_address,
                    iasset_addr,
                );
                let iasset_pool = amm_pair::liquidity_pool_address(token_obj, iasset_obj);
                std::vector::push_back(&mut amm_pool_addresses, iasset_pool);
            };
            i = i + 1;
        };

        if (is_meme) {
            hodl_fa::register_hodl_pool(
                &resource_signer,
                token_address,
                token_address,
                final_unstake_period,
                std::option::none<hodl_fa::NFTBoostConfig>()
            );
        } else {
            let ideal_supply = math::calculate_ideal_projected_supply_base(virtual_token_reserves, virtual_supra_reserves, raising);
            
            petra::create_dao_inflationary_from_launcher(
                caller,
                &resource_signer,
                token_obj,
                ideal_supply,
                amm_pool_addresses
            );
        };

        let (raise_limit_min, raise_limit_max) = launch_config::get_raise_limits_config();
        let third = (raise_limit_max - raise_limit_min) / 3;
        let lower_threshold = third + raise_limit_min;
        let upper_threshold = (third * 2) + raise_limit_min;
        let project_type = if (raising <= lower_threshold) {
            std::string::utf8(b"Meme")
        } else if (raising <= upper_threshold) {
            std::string::utf8(b"DAO")
        } else {
            std::string::utf8(b"BIG_DAO")
        };

        // AMM Pair registration was moved inside the 'else' block for DAOs, and for memes it happens during migration.

        event::emit(
            PumpEvent {
                pool_address,
                dev: sender,
                name,
                symbol,
                token_address,
                uri,
                website,
                description,
                socials,
                initial_virtual_token_reserves: virtual_token_reserves,
                initial_virtual_supra_reserves: virtual_supra_reserves,
                raising,
                project_type,
            }
        );

        token_address
    }

    public entry fun buy_tokens(
        caller: &signer,
        token_address: address,
        supra_in_amount_param: u64,
        min_token_out: u64
    ) {
        let supra_in_amount = supra_in_amount_param;
        assert!(supra_in_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        
        // SECURITY FIX (L-03): Enforce minimum trade amount to prevent dust spam/botting
        assert!(supra_in_amount >= launch_config::get_min_trade_supra_amount(), error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let sender = address_of(caller);
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));

        let current_supra_balance = pool::get_supra_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_supra_to_add = if (required_balance > current_supra_balance) { required_balance - current_supra_balance } else { 0 };

        let platform_fee = math64::mul_div(supra_in_amount, platform_fee_bps, 10000);
        let creator_fee = math64::mul_div(supra_in_amount, creator_fee_bps, 10000); 
        let total_fees = platform_fee + creator_fee;

        assert!(supra_in_amount > total_fees, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let supra_to_pool_amount_u64 = supra_in_amount - total_fees;

        if (supra_to_pool_amount_u64 > max_supra_to_add) {
            let excess_pool_amount = supra_to_pool_amount_u64 - max_supra_to_add;
            let total_fees_bps = platform_fee_bps + creator_fee_bps;
            let excess_input = math64::mul_div(excess_pool_amount, 10000, 10000 - total_fees_bps);
            
            supra_in_amount = supra_in_amount - excess_input;
            platform_fee = math64::mul_div(supra_in_amount, platform_fee_bps, 10000);
            creator_fee = math64::mul_div(supra_in_amount, creator_fee_bps, 10000);
            total_fees = platform_fee + creator_fee;
            supra_to_pool_amount_u64 = supra_in_amount - total_fees;
        };

        let (v_supra, v_token) = pool::get_reserves(pool_address);
        
        let tokens_to_receive_u128 = math::calculate_buy_token(
            v_token,
            v_supra,
            (supra_to_pool_amount_u64 as u128)
        );

        let tokens_to_receive_u64 = (tokens_to_receive_u128 as u64);
        assert!(tokens_to_receive_u64 > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_TO_LOW));
        assert!(tokens_to_receive_u64 >= min_token_out, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));

        let total_supra_coin = coin::withdraw<SupraCoin>(caller, supra_in_amount);
        let platform_fee_coin = coin::extract(&mut total_supra_coin, platform_fee);
        let creator_fee_coin = coin::extract(&mut total_supra_coin, creator_fee);
        
        distribute_fees_internal(pool_address, platform_fee_address, platform_fee_coin, creator_fee_coin);

        pool::deposit_supra(pool_address, total_supra_coin);
        asset_manager::mint(token_address, sender, tokens_to_receive_u64);

        event::emit(
            TradeEvent {
                supra_amount: supra_to_pool_amount_u64,
                is_buy: true,
                token_address,
                token_amount: tokens_to_receive_u64,
                user: sender,
                timestamp: timestamp::now_seconds(),
            }
        );

        check_and_complete_pool_internal(pool_address);
    }

    public entry fun sell_tokens(
        caller: &signer,
        token_address: address,
        sell_token_amount: u64,
        min_supra_out: u64
    ) {
        assert!(sell_token_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        let sender = address_of(caller);
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));

        let (v_supra, v_token) = pool::get_reserves(pool_address);
        
        let supra_to_receive_u128 = math::calculate_sell_token(
            v_token,
            v_supra,
            (sell_token_amount as u128)
        );

        let supra_to_receive_u64 = (supra_to_receive_u128 as u64);
        assert!(supra_to_receive_u64 >= min_supra_out, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));
        
        asset_manager::burn(token_address, sender, sell_token_amount);

        let platform_fee = math64::mul_div(supra_to_receive_u64, platform_fee_bps, 10000);
        let creator_fee = math64::mul_div(supra_to_receive_u64, creator_fee_bps, 10000);

        let supra_from_pool = pool::extract_supra(pool_address, supra_to_receive_u64);
        let platform_fee_coin = coin::extract<SupraCoin>(&mut supra_from_pool, platform_fee);
        let creator_fee_coin = coin::extract<SupraCoin>(&mut supra_from_pool, creator_fee);

        distribute_fees_internal(pool_address, platform_fee_address, platform_fee_coin, creator_fee_coin);
        coin::deposit(sender, supra_from_pool);

        event::emit(
            TradeEvent {
                supra_amount: supra_to_receive_u64 - platform_fee - creator_fee,
                is_buy: false,
                token_address,
                token_amount: sell_token_amount,
                user: sender,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    public entry fun execute_migration(
        caller: &signer,
        token_address: address
    ) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        assert!(pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));
        assert!(!pool::is_migrated(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));

        let deadline = timestamp::now_seconds() + 10800;
        migration::orchestrate_migration_to_amm(
            caller, 
            token_address, 
            pool_address, 
            deadline
        );
    }

    // Helper math calculation functions to preserve compatibility
    fun get_raise_limits(): (u64, u64, u64, u64) {
        let (min_limit, max_limit) = launch_config::get_raise_limits_config();
        let lower_threshold = (((max_limit - min_limit) * 1) / 3) + min_limit;
        let upper_threshold = (((max_limit - min_limit) * 2) / 3) + min_limit;
        (min_limit, lower_threshold, upper_threshold, max_limit)
    }

    fun calculate_virtual_pools_internal(raising: u64): (u128, u128) {
        let (min_limit, lower_threshold, upper_threshold, max_limit) = get_raise_limits();
        assert!(raising >= min_limit && raising <= max_limit, error::invalid_argument(ERROR_INVALID_RAISE));

        let (meme_mult, dao_mult, big_dao_mult) = launch_config::get_virtual_mult_ranges();

        let virtual_supra_reserves_u128: u128;
        if (raising <= lower_threshold) {
            virtual_supra_reserves_u128 = (raising as u128) * (meme_mult as u128);
        } else if (raising <= upper_threshold) {
            virtual_supra_reserves_u128 = (raising as u128) * (dao_mult as u128);
        } else {
            virtual_supra_reserves_u128 = (raising as u128) * (big_dao_mult as u128);
        };

        let factor_u128 = aptos_std::math128::pow((10 as u128), (launch_config::get_token_decimals() as u128));
        let tokens_per_sup_u128 = (launch_config::get_tokens_per_sup() as u128);
        let supra_decimals_u128 = (100_000_000 as u128);

        let intermediate_result = aptos_std::math128::mul_div(
            virtual_supra_reserves_u128,
            tokens_per_sup_u128,
            supra_decimals_u128
        );
        let virtual_token_reserves_u128 = (intermediate_result as u256) * (factor_u128 as u256);

        (virtual_supra_reserves_u128, (virtual_token_reserves_u128 as u128))
    }

    fun get_percentage_bps_reward_internal(raising: u64): u64 {
        let (_min_limit, lower_threshold, upper_threshold, _max_limit) = get_raise_limits();
        let (meme_pct, dao_pct, big_dao_pct) = launch_config::get_raising_percentages();
        
        if (raising <= lower_threshold) {
            meme_pct
        } else if (raising <= upper_threshold) {
            dao_pct
        } else {
            big_dao_pct
        }
    }

    public entry fun swap_supra_for_exact_tokens(
        caller: &signer,
        token_address: address,
        buy_token_amount: u64,
        max_supra_in: u64
    ) {
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));
        let (v_supra, v_token) = pool::get_reserves(pool_address);
        assert!((buy_token_amount as u128) < v_token, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let min_trade_supra_amount = launch_config::get_min_trade_supra_amount();
        let current_supra_balance = pool::get_supra_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_supra_to_add = if (required_balance > current_supra_balance) { required_balance - current_supra_balance } else { 0 };

        let liquidity_cost_u128 = math::calculate_add_liquidity_cost(
            v_supra,
            v_token,
            (buy_token_amount as u128)
        );

        assert!((liquidity_cost_u128 as u64) <= max_supra_to_add, error::invalid_state(ERROR_PUMP_COMPLETED));

        let platform_fee_u128 = aptos_std::math128::mul_div(liquidity_cost_u128, (platform_fee_bps as u128), 10000);
        let creator_fee_u128 = aptos_std::math128::mul_div(liquidity_cost_u128, (creator_fee_bps as u128), 10000);

        let total_cost_u128 = liquidity_cost_u128 + platform_fee_u128 + creator_fee_u128;
        let total_cost_u64 = (total_cost_u128 as u64);
        assert!(total_cost_u64 <= max_supra_in, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));
        assert!(total_cost_u64 >= min_trade_supra_amount, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));

        let total_supra_coin = coin::withdraw<SupraCoin>(caller, total_cost_u64);
        let platform_fee_coin = coin::extract(&mut total_supra_coin, (platform_fee_u128 as u64));
        let creator_fee_coin = coin::extract(&mut total_supra_coin, (creator_fee_u128 as u64));

        distribute_fees_internal(pool_address, platform_fee_address, platform_fee_coin, creator_fee_coin);

        pool::deposit_supra(pool_address, total_supra_coin);

        let sender = address_of(caller);
        asset_manager::mint(token_address, sender, buy_token_amount);

        event::emit(
            TradeEvent {
                supra_amount: (liquidity_cost_u128 as u64),
                is_buy: true,
                token_address,
                token_amount: buy_token_amount,
                user: sender,
                timestamp: timestamp::now_seconds(),
            }
        );

        check_and_complete_pool_internal(pool_address);
    }

    public entry fun deploy_and_buy_for_exact_supra(
        caller: &signer,
        raising: u64,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        description: String,
        socials: String,
        unstake_period_seconds: u64,
        supra_in_amount: u64,
        min_token_out: u64
    ) {
        let token_address = deploy_internal(caller, raising, name, symbol, uri, website, description, socials, unstake_period_seconds);

        if (supra_in_amount > 0) {
            buy_tokens(caller, token_address, supra_in_amount, min_token_out);
        }
    }

    public entry fun stake(
        user: &signer,
        token_address: address,
        stake_amount: u64
    ) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        assert!(pool::is_meme(pool_address), error::invalid_argument(ERROR_HODL_FA_NOT_SUPPORTED));
        // [FIX-H1.2] Block staking once the bonding curve has completed. This prevents
        // flash-stake attacks where an attacker stakes just before execute_migration
        // and captures retroactive HODL rewards without having held tokens.
        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_POOL_COMPLETED_NO_STAKE));
        let pool_key = hodl_fa::new_pool_identifier(resource_address, token_address, token_address);
        hodl_fa::stake(user, pool_key, stake_amount);
    }
    
    public entry fun unstake(
        user: &signer,
        token_address: address,
        unstake_amount: u64
    ) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        assert!(pool::is_meme(pool_address), error::invalid_argument(ERROR_HODL_FA_NOT_SUPPORTED));

        let pool_key = hodl_fa::new_pool_identifier(resource_address, token_address, token_address);
        let fa = hodl_fa::unstake(user, pool_key, unstake_amount);
        primary_fungible_store::deposit(address_of(user), fa);
    }

    public entry fun harvest(
        user: &signer,
        token_address: address
    ) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        assert!(pool::is_meme(pool_address), error::invalid_argument(ERROR_HODL_FA_NOT_SUPPORTED));

        let pool_key = hodl_fa::new_pool_identifier(resource_address, token_address, token_address);
        let (_, harvested_rewards) = hodl_fa::harvest(user, pool_key);

        let user_addr = address_of(user);
        let reward_fa_metadata_obj = object::address_to_object<Metadata>(token_address);
        if (!primary_fungible_store::primary_store_exists(user_addr, reward_fa_metadata_obj)) {
            primary_fungible_store::create_primary_store(user_addr, reward_fa_metadata_obj);
        };
        primary_fungible_store::deposit(user_addr, harvested_rewards);
    }

    #[view]
    public fun buy_token_amount(
        token_address: address, buy_token_amount: u64
    ): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let (v_supra, v_token) = pool::get_reserves(pool_address);

        let token_amount = aptos_std::math128::min((buy_token_amount as u128), v_token);
        math::calculate_add_liquidity_cost(v_supra, v_token, token_amount)
    }

    #[view]
    public fun get_current_pool_supra_balance(token_address: address): u64 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        pool::get_supra_balance(pool_address)
    }

    #[view]
    public fun buy_supra_amount(token_address: address, buy_supra_amount: u64): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        
        let current_supra_balance = pool::get_supra_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_supra_to_add = if (required_balance > current_supra_balance) { required_balance - current_supra_balance } else { 0 };

        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();
        
        let supra_in_amount = buy_supra_amount;
        let platform_fee = aptos_std::math64::mul_div(supra_in_amount, platform_fee_bps, 10000);
        let creator_fee = aptos_std::math64::mul_div(supra_in_amount, creator_fee_bps, 10000); 
        let total_fees = platform_fee + creator_fee;

        let supra_to_pool_amount_u64 = if (supra_in_amount > total_fees) { supra_in_amount - total_fees } else { 0 };

        if (supra_to_pool_amount_u64 > max_supra_to_add) {
            let excess_pool_amount = supra_to_pool_amount_u64 - max_supra_to_add;
            let total_fees_bps = platform_fee_bps + creator_fee_bps;
            let excess_input = aptos_std::math64::mul_div(excess_pool_amount, 10000, 10000 - total_fees_bps);
            
            supra_in_amount = if (supra_in_amount > excess_input) { supra_in_amount - excess_input } else { 0 };
            platform_fee = aptos_std::math64::mul_div(supra_in_amount, platform_fee_bps, 10000);
            creator_fee = aptos_std::math64::mul_div(supra_in_amount, creator_fee_bps, 10000);
            total_fees = platform_fee + creator_fee;
            supra_to_pool_amount_u64 = if (supra_in_amount > total_fees) { supra_in_amount - total_fees } else { 0 };
        };

        let (v_supra, v_token) = pool::get_reserves(pool_address);
        math::calculate_buy_token(v_token, v_supra, (supra_to_pool_amount_u64 as u128))
    }

    #[view]
    public fun sell_token(token_address: address, sell_token_amount: u64): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let (v_supra, v_token) = pool::get_reserves(pool_address);
        math::calculate_sell_token(v_token, v_supra, (sell_token_amount as u128))
    }

    #[view]
    public fun get_current_price(token_address: address): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let (v_supra, v_token) = pool::get_reserves(pool_address);
        aptos_std::math128::mul_div(v_supra, (100_000_000 as u128), v_token)
    }

    #[view]
    public fun buy_price_with_fee(token_address: address, buy_meme_amount: u64): u128 {
        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();
        let supra_pool = buy_token_amount(token_address, buy_meme_amount);
        let total_fees_bps = platform_fee_bps + creator_fee_bps;
        aptos_std::math128::mul_div(supra_pool, 10000, 10000 - (total_fees_bps as u128))
    }

    #[view]
    public fun sell_price_with_fee(token_address: address, sell_meme_amount: u64): u128 {
        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();
        let supra_amount = sell_token(token_address, sell_meme_amount);
        let platform_fee = aptos_std::math128::mul_div(supra_amount, (platform_fee_bps as u128), 10000);
        let creator_fee = aptos_std::math128::mul_div(supra_amount, (creator_fee_bps as u128), 10000);
        let total_fees = platform_fee + creator_fee;
        if (supra_amount > total_fees) {
            supra_amount - total_fees
        } else {
            0
        }
    }

    public entry fun activate_delayed_dao(
        caller: &signer,
        token_address: address
    ) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        
        // 1. Verify it's a Meme project (Static DAO path)
        assert!(pool::is_meme(pool_address), error::invalid_argument(ERROR_HODL_FA_NOT_SUPPORTED));
        
        // 2. Verify HODL period is finished
        let pool_key = hodl_fa::new_pool_identifier(resource_address, token_address, token_address);
        assert!(hodl_fa::is_hodl_period_finished(resource_address, pool_key), error::invalid_state(ERROR_HODL_PERIOD_NOT_FINISHED));
        
        let resource_signer = launch_config::get_resource_signer();
        let token_obj = object::address_to_object<Metadata>(token_address);
        
        // 3. Create Static DAO
        let target_threshold = pool::get_target_threshold(pool_address);
        let (initial_v_token, initial_v_supra) = pool::get_initial_virtual_pools(pool_address);
        let expected_supply = math::calculate_ideal_projected_supply_base(
            initial_v_token,
            initial_v_supra,
            target_threshold
        );
        let dao_address = petra::create_dao_static_from_launcher(
            caller,
            &resource_signer,
            token_obj,
            expected_supply
        );

        petra::update_static_dao_threshold(&resource_signer, dao_address, token_obj);
    }

    #[view]
    public fun get_bonding_curve_progress_data(token_address: address): (u64, u64, bool) {       
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let target_amount = pool::get_target_threshold(pool_address);
        let is_completed = pool::is_completed(pool_address);
        let current_amount = pool::get_supra_balance(pool_address);
        (current_amount, target_amount, is_completed)
    }

    #[view]
    public fun calculate_virtual_pools(raising: u64): (u128, u128) {
        calculate_virtual_pools_internal(raising)
    }

    #[view]
    public fun get_percentage_bps_reward(raising: u64): u64 {
        get_percentage_bps_reward_internal(raising)
    }

    #[view]
    public fun get_user_stake_info(token_address: address, user_addr: address): (u64, u64) {
        let resource_address = launch_config::get_resource_address();
        let total_staked = hodl_fa::get_user_stake_or_zero(resource_address, token_address, token_address, user_addr);
        let unlocked_amount = hodl_fa::get_unlocked_stake_amount(resource_address, token_address, token_address, user_addr);
        (unlocked_amount, total_staked)
    }

    #[view]
    public fun get_hodl_pool_stats(token_address: address) : (u64, u128) {
        let resource_address = launch_config::get_resource_address();
        let total_staked = hodl_fa::get_pool_total_stake(resource_address, token_address, token_address);
        let total_supply = asset_manager::get_total_supply(token_address);
        (total_staked, total_supply)
    }

    #[view]
    public fun get_pool_state(token_address: address): PoolStateView {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        
        let (v_supra, v_token) = pool::get_reserves(pool_address);
        
        PoolStateView {
            virtual_token_reserves: v_token,
            virtual_supra_reserves: v_supra,
            is_completed: pool::is_completed(pool_address),
            is_migrated_to_dex: pool::is_migrated(pool_address),
            target_supra_dex_threshold: pool::get_target_threshold(pool_address),
            dev_address: pool::get_dev_address(pool_address),
        }
    }

    // --- Helper Functions for Refactoring ---

    fun distribute_fees_internal(
        pool_address: address,
        platform_fee_address: address,
        platform_fee_coin: coin::Coin<SupraCoin>,
        creator_fee_coin: coin::Coin<SupraCoin>
    ) {
        let dev_address = pool::get_dev_address(pool_address);
        if (coin::is_account_registered<SupraCoin>(dev_address)) {
            coin::deposit(dev_address, creator_fee_coin);
        } else {
            coin::merge(&mut platform_fee_coin, creator_fee_coin);
        };
        // [FIX-H3.1] Guard against DoS: if platform_fee_address has no CoinStore
        // (e.g. admin misconfigured), fall back to the module admin address (@hoglet_core)
        // which is always registered as the module deployer. This ensures buy/sell
        // transactions never abort due to a bad fee address configuration.
        if (coin::is_account_registered<SupraCoin>(platform_fee_address)) {
            coin::deposit(platform_fee_address, platform_fee_coin);
        } else {
            coin::deposit(@hoglet_core, platform_fee_coin);
        };
    }

    fun check_and_complete_pool_internal(pool_address: address) {
        let current_supra_balance = pool::get_supra_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);

        if (current_supra_balance >= required_balance && !pool::is_completed(pool_address)) {
            let (final_v_supra, final_v_token) = pool::get_reserves(pool_address);
            pool::set_completed(pool_address, final_v_token, final_v_supra);
        }
    }
}
