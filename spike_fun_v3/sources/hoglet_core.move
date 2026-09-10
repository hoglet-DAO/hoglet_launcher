module hoglet_core::hoglet_core {
    use std::error;
    use std::signer::address_of;
    use std::string::{String};
    use std::option;
    use aptos_std::math64;
    use supra_framework::account;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::primary_fungible_store;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::object::{Self, Object};

    use hoglet_core::asset_manager;
    use hoglet_core::launch_config;
    use hoglet_core::math;
    use hoglet_core::pool;
    use hoglet_core::migration;
    use hoglet_hodl::hodl_fa;
    use dao_factory::petra;
    use dao_factory::tax_router;
    use spike_amm::amm_router;
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
    const ERROR_HODL_FA_NOT_SUPPORTED: u64 = 33;
    const ERROR_HODL_PERIOD_NOT_FINISHED: u64 = 34;
    const ERROR_NAME_TOO_LONG: u64 = 35;
    const ERROR_SYMBOL_TOO_LONG: u64 = 36;
    const ERROR_DESCRIPTION_TOO_LONG: u64 = 39;
    const ERROR_SOCIALS_TOO_LONG: u64 = 40;
    const ERROR_NAME_TOO_SHORT: u64 = 42;
    const ERROR_SYMBOL_TOO_SHORT: u64 = 43;
    const ERROR_OVERFLOW: u64 = 13;
    const U128_MAX: u128 = 340282366920938463463374607431768211455u128;
    /// Deployer passed an unstake_period_seconds outside the [min, max] range set in launch_config.
    const ERROR_INVALID_UNSTAKE_PERIOD: u64 = 37;
    /// stake() is blocked once the bonding curve has been completed.
    const ERROR_POOL_COMPLETED_NO_STAKE: u64 = 38;

    #[event]
    struct PumpEvent has drop, store {
        pool_address: address,
        dev: address,
        name: String,
        symbol: String,
        token_address: address,
        quote_address: address,
        uri: String,
        website: String,
        description: String,
        socials: String,
        initial_virtual_token_reserves: u128,
        initial_virtual_quote_reserves: u128,
        raising: u64,
        project_type: String,
        token_decimals: u8,
        /// Quote decimals so indexers/frontends can scale amounts without an
        /// extra on-chain lookup per pool.
        quote_decimals: u8,
    }

    #[event]
    struct TradeEvent has drop, store {
        quote_amount: u64,
        is_buy: bool,
        token_address: address,
        token_amount: u64,
        user: address,
        timestamp: u64,
    }

    struct PoolStateView has drop, store {
        token_address: address,
        quote_metadata: address,
        virtual_token_reserves: u128,
        virtual_quote_reserves: u128,
        is_completed: bool,
        is_migrated_to_dex: bool,
        target_threshold: u64,
        dev_address: address,
    }

    fun init_module(admin: &signer) {
        assert!(address_of(admin) == @hoglet_core, error::permission_denied(ERROR_NO_AUTH));
        let (_, signer_cap) = account::create_resource_account(admin, b"pump_v3");
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
        quote_address: address,
        unstake_period_seconds: u64
    ) {
        deploy_internal(caller, raising, name, symbol, uri, website, description, socials, quote_address, unstake_period_seconds);
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
        quote_address: address,
        unstake_period_seconds: u64
    ): address {
        assert!(std::string::length(&name) > 0, error::invalid_argument(ERROR_NAME_TOO_SHORT));
        assert!(std::string::length(&name) <= 37, error::invalid_argument(ERROR_NAME_TOO_LONG));
        assert!(std::string::length(&symbol) > 0, error::invalid_argument(ERROR_SYMBOL_TOO_SHORT));
        assert!(std::string::length(&symbol) <= 13, error::invalid_argument(ERROR_SYMBOL_TOO_LONG));
        assert!(std::string::length(&description) <= 731, error::invalid_argument(ERROR_DESCRIPTION_TOO_LONG));
        assert!(std::string::length(&socials) <= 1371, error::invalid_argument(ERROR_SOCIALS_TOO_LONG));

        // Quote must be whitelisted AND enabled; the address is AMM-canonical by
        // construction (validated when the admin registered it). Every consumer
        // field is snapshotted into the Pool below a later oracle refresh
        // never alters the economics of an in-flight curve.
        // (Call serves as an exists+enabled guard; fields come via getters.)
        launch_config::require_quote_config(quote_address);

        let sender = address_of(caller);

        let (_, deploy_fee, _, platform_fee_address) = launch_config::get_platform_fees();
        if (deploy_fee > 0) {
            // Platform revenue stays SUPRA-denominated regardless of the quote.
            let deploy_fee_coin = coin::withdraw<SupraCoin>(caller, deploy_fee);
            if (coin::is_account_registered<SupraCoin>(platform_fee_address)) {
                coin::deposit(platform_fee_address, deploy_fee_coin);
            } else {
                coin::deposit(@hoglet_core, deploy_fee_coin);
            };
        };

        let (virtual_quote_reserves, virtual_token_reserves) = calculate_virtual_pools_internal(raising, quote_address);
        let percentage_reward_bps = get_percentage_bps_reward_internal(raising, quote_address);

        let resource_signer = launch_config::get_resource_signer();

        let is_meme = is_meme_project_internal(raising, quote_address);

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
            quote_address,
            launch_config::is_quote_tax_aware_capable(quote_address),
            virtual_token_reserves,
            virtual_quote_reserves,
            raising,
            launch_config::get_quote_min_trade_amount(quote_address),
            percentage_reward_bps,
            sender,
            is_meme
        );

        // [FIX (audit13 R-2)] Cross-launch whitelist: when the QUOTE is an
        // earlier launcher-DAO's smart token, THIS launch's Pool must be
        // whitelisted in THAT DAO's TaxFreeRouter so the pool's signer-proof
        // routes work. Gated by the launcher registry (same identity pattern
        // as petra::activate_dao); skipped for plain-FA / SUPRA quotes.
        let quote_obj = object::address_to_object<Metadata>(quote_address);
        let quote_dao_opt = petra::get_dao_for_token(quote_obj);
        if (option::is_some(&quote_dao_opt)) {
            let quote_dao_address = *option::borrow(&quote_dao_opt);
            if (tax_router::has_tax_free_router(quote_dao_address)) {
                petra::add_tax_router(&resource_signer, quote_dao_address, pool_address);
            };
        };
let final_unstake_period = if (unstake_period_seconds > 0) {
            // Validate deployer-supplied unstake period is within the platform-configured range.
            let (min_period, max_period) = launch_config::get_unstake_period_range();
            assert!(
                unstake_period_seconds >= min_period && unstake_period_seconds <= max_period,
                error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD)
            );
            unstake_period_seconds
        } else {
            launch_config::get_unstake_period_default()
        };

        // Register the locked pair for the chosen quote prevents manual creation
        // attacks and ensures the LP Token Object exists before the Gauge is
        // created. v3 keeps exactly ONE locked pair per launch: token / quote.
        // [V3-SUPRA-TRACK] The pair must be created at the AMM-canonical address
        // (bwsup) so the ecosystem can trade it via router paths while the
        // POOL keeps custody in the network-native FA (0xA). Computing the
        // pair-quote separately from the custody quote is what lets users
        // pay/receive pure SUPRA the whole lifecycle with zero bridges.
        let pair_quote_address = if (launch_config::is_supra_native_fa(quote_address)) {
            amm_router::get_address_BWSUP()
        } else {
            quote_address
        };
        amm_router::create_locked_pair_for_launchpad(
            &resource_signer,
            token_address,
            pair_quote_address,
        );

        // [V3-BUFFER-ROUTE] When the quote is SUPRA-native and the admin has the
        // buffer route enabled, pre-create the SECOND locked pair (token/iasset)
        // so the migration can seed iSUPRA liquidity (PoEL yields in that pool)
        // if the buffer is healthy at graduation. The AMM gate accepts iassets
        // natively (original branch, zero AMM edits). Inert when disabled.
        // [AUDIT-V3-9] The second pool's address MUST also be registered as a
        // natal gauge (amm_pool_addresses) when the launch is a DAO otherwise
        // the buffer-route migration aborts with GAUGE_NOT_FOUND (the gauge for
        // the iasset pool never existed). Both gauges are born inactive and the
        // migration activates the seeded one exacatly the v2 semantic.
        let buffer_pair_pool_address: option::Option<address> = if (
            launch_config::is_supra_native_fa(quote_address) && launch_config::is_buffer_enabled()
        ) {
            let iasset_quote_address = launch_config::get_buffer_iasset_address();
            // 0x0 means "no target configured": the gate rejects address 0x0.
            if (iasset_quote_address != @0x0) {
                amm_router::create_locked_pair_for_launchpad(
                    &resource_signer,
                    token_address,
                    iasset_quote_address,
                );
                let iasset_pair_obj = object::address_to_object<Metadata>(iasset_quote_address);
                std::option::some(amm_pair::liquidity_pool_address(token_obj, iasset_pair_obj))
            } else {
                std::option::none()
            }
        } else {
            std::option::none()
        };

        if (is_meme) {
            hodl_fa::register_hodl_pool(
                &resource_signer,
                token_address,
                token_address,
                final_unstake_period,
                option::none<hodl_fa::NFTBoostConfig>()
            );
        } else {
            let ideal_supply = math::calculate_ideal_projected_supply_base(
                virtual_token_reserves,
                virtual_quote_reserves,
                raising
            );

            let amm_pool_addresses = std::vector::empty<address>();
            let pair_quote_obj = object::address_to_object<Metadata>(pair_quote_address);
            let quote_pool = amm_pair::liquidity_pool_address(token_obj, pair_quote_obj);
            std::vector::push_back(&mut amm_pool_addresses, quote_pool);
            // [AUDIT-V3-9] Register the iasset-pool gauge too (born inactive; the
            // migration activates whichever pool actually receives the seed).
            if (option::is_some(&buffer_pair_pool_address)) {
                std::vector::push_back(&mut amm_pool_addresses, *option::borrow(&buffer_pair_pool_address));
            };

            petra::create_dao_inflationary_from_launcher(
                caller,
                &resource_signer,
                token_obj,
                ideal_supply,
                amm_pool_addresses
            );
        };

        let (_raise_min, lower_threshold, upper_threshold, _raise_max) = get_raise_limits_for_quote(quote_address);
        let project_type = if (raising <= lower_threshold) {
            std::string::utf8(b"Meme")
        } else if (raising <= upper_threshold) {
            std::string::utf8(b"DAO")
        } else {
            std::string::utf8(b"BIG_DAO")
        };

        event::emit(
            PumpEvent {
                pool_address,
                dev: sender,
                name,
                symbol,
                token_address,
                quote_address,
                uri,
                website,
                description,
                socials,
                initial_virtual_token_reserves: virtual_token_reserves,
                initial_virtual_quote_reserves: virtual_quote_reserves,
        raising,
        project_type,
        token_decimals: launch_config::get_token_decimals(),
        quote_decimals: launch_config::get_quote_decimals(quote_address),
    }
        );

        token_address
    }

    public entry fun buy_tokens(
        caller: &signer,
        token_address: address,
        quote_in_amount_param: u64,
        min_token_out: u64
    ) {
        let quote_in_amount = quote_in_amount_param;
        assert!(quote_in_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        let sender = address_of(caller);
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let quote_obj = get_quote_obj_internal(pool_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));

        // [AUDIT-V3-3] Anti-dust on the primary buy path (v2 enforced this on
        // the fixed swap route only the raft to buy_tokens was the gap).
        // min_trade is frozen per-pool at deploy time.
        assert!(
            quote_in_amount >= pool::get_min_trade_amount(pool_address),
            error::invalid_argument(ERROR_AMOUNT_TOO_LOW)
        );

        let current_quote_balance = pool::get_quote_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_quote_to_add = if (required_balance > current_quote_balance) { required_balance - current_quote_balance } else { 0 };

        let platform_fee = math64::mul_div(quote_in_amount, platform_fee_bps, 10000);
        let creator_fee = math64::mul_div(quote_in_amount, creator_fee_bps, 10000);
        let total_fees = platform_fee + creator_fee;

        assert!(quote_in_amount > total_fees, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let quote_to_pool_amount_u64 = quote_in_amount - total_fees;

        if (quote_to_pool_amount_u64 > max_quote_to_add) {
            let excess_pool_amount = quote_to_pool_amount_u64 - max_quote_to_add;
            let total_fees_bps = platform_fee_bps + creator_fee_bps;
            let excess_input = math64::mul_div(excess_pool_amount, 10000, 10000 - total_fees_bps);

            quote_in_amount = quote_in_amount - excess_input;
            platform_fee = math64::mul_div(quote_in_amount, platform_fee_bps, 10000);
            creator_fee = math64::mul_div(quote_in_amount, creator_fee_bps, 10000);
            total_fees = platform_fee + creator_fee;
            quote_to_pool_amount_u64 = quote_in_amount - total_fees;
        };

        let (v_quote, v_token) = pool::get_reserves(pool_address);

        let tokens_to_receive_u128 = math::calculate_buy_token(
            v_token,
            v_quote,
            (quote_to_pool_amount_u64 as u128)
        );

        let tokens_to_receive_u64 = (tokens_to_receive_u128 as u64);
        assert!(tokens_to_receive_u64 > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_TO_LOW));
        assert!(tokens_to_receive_u64 >= min_token_out, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));

        let total_quote_asset = withdraw_quote_internal(caller, quote_obj, quote_in_amount);
        let platform_fee_asset = fungible_asset::extract(&mut total_quote_asset, platform_fee);
        let creator_fee_asset = fungible_asset::extract(&mut total_quote_asset, creator_fee);

        distribute_quote_fees_internal(
            pool_address,
            quote_obj,
            platform_fee_address,
            platform_fee_asset,
            creator_fee_asset
        );

        pool::deposit_quote(pool_address, total_quote_asset);
        asset_manager::mint(token_address, sender, tokens_to_receive_u64);

        event::emit(
            TradeEvent {
                quote_amount: quote_to_pool_amount_u64,
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
        min_quote_out: u64
    ) {
        assert!(sell_token_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        let sender = address_of(caller);
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let quote_obj = get_quote_obj_internal(pool_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));

        let (v_quote, v_token) = pool::get_reserves(pool_address);

        let quote_to_receive_u128 = math::calculate_sell_token(
            v_token,
            v_quote,
            (sell_token_amount as u128)
        );

        let quote_to_receive_u64 = (quote_to_receive_u128 as u64);

        asset_manager::burn(token_address, sender, sell_token_amount);

        let platform_fee = math64::mul_div(quote_to_receive_u64, platform_fee_bps, 10000);
        let creator_fee = math64::mul_div(quote_to_receive_u64, creator_fee_bps, 10000);

        // [AUDIT-V3-2] Slippage protects what the seller actually RECEIVES:
        // assert on the NET amount after fees (the old pre-fee assert let
        // users land below their minimum by up to the fee spread).
        let net_quote_to_receive = quote_to_receive_u64 - platform_fee - creator_fee;
        assert!(
            net_quote_to_receive >= min_quote_out,
            error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH)
        );

        let quote_from_pool = pool::extract_quote(pool_address, quote_to_receive_u64);
        let platform_fee_asset = fungible_asset::extract(&mut quote_from_pool, platform_fee);
        let creator_fee_asset = fungible_asset::extract(&mut quote_from_pool, creator_fee);

        distribute_quote_fees_internal(
            pool_address,
            quote_obj,
            platform_fee_address,
            platform_fee_asset,
            creator_fee_asset
        );
        // Ensure the seller can receive the quote in the same tx (a user that
        // acquired tokens via transfer may never have held the quote before).
        // [FIX-H2] Tax-aware quotes: the payout routes tax-free via the quote's
        // DAO TaxFreeCap the seller receives the EXACT net asserted (their
        // own tax hooks would skim the payout otherwise, breaking the V3-2
        // slippage guarantee).
        let seller_store = primary_fungible_store::ensure_primary_store_exists(sender, quote_obj);
        let quote_dao_opt = petra::get_dao_for_token(quote_obj);
        if (option::is_some(&quote_dao_opt)) {
            // [FIX-H2 + audit13 R-1]: the router proof is the launcher's
            // shared resource account signer (whitelisted in every
            // launcher-DAO's TaxFreeRouter at that DAO's own migration); no
            // user can produce it.
            let router_signer = &launch_config::get_resource_signer();
            tax_router::deposit_tax_free(*option::borrow(&quote_dao_opt), router_signer, seller_store, quote_from_pool);
        } else {
            primary_fungible_store::deposit(sender, quote_from_pool);
        };

        event::emit(
            TradeEvent {
                quote_amount: quote_to_receive_u64 - platform_fee - creator_fee,
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

    fun get_raise_limits_for_quote(quote_address: address): (u64, u64, u64, u64) {
        // (min, lower_threshold, upper_threshold, max) all RAW units of the quote,
        // derived from the SUPRA pivot frozen at quote registration.
        launch_config::get_quote_raise_thresholds(quote_address)
    }

    fun calculate_virtual_pools_internal(raising: u64, quote_address: address): (u128, u128) {
        let (min_limit, lower_threshold, upper_threshold, max_limit) = get_raise_limits_for_quote(quote_address);
        assert!(raising >= min_limit && raising <= max_limit, error::invalid_argument(ERROR_INVALID_RAISE));

        let (meme_mult, dao_mult, big_dao_mult) = launch_config::get_virtual_mult_ranges();

        let virtual_quote_reserves_u128: u128;
        if (raising <= lower_threshold) {
            virtual_quote_reserves_u128 = (raising as u128) * (meme_mult as u128);
        } else if (raising <= upper_threshold) {
            virtual_quote_reserves_u128 = (raising as u128) * (dao_mult as u128);
        } else {
            virtual_quote_reserves_u128 = (raising as u128) * (big_dao_mult as u128);
        };

        // (Quote existence/enabled was already validated on the deploy path;
        // params come via getters here.)
        let token_dec_factor = aptos_std::math128::pow((10 as u128), (launch_config::get_token_decimals() as u128));
        let quote_dec_factor = aptos_std::math128::pow((10 as u128), (launch_config::get_quote_decimals(quote_address) as u128));

        // price_ratio_whole = whole token units per WHOLE quote unit.
        // v_token = v_quote_raw * 10^token_decimals * price_ratio / 10^quote_decimals
        // [AUDIT-overflow] The product runs in u256: a u128 multiply here
        // (v_quote up to ~2.5e21 x token_dec_factor up to 1e18) would abort
        // arithmetic for 18-decimal tokens with high raising.
        let numerator_u256 = (virtual_quote_reserves_u128 as u256) * (token_dec_factor as u256) * ((launch_config::get_quote_price_ratio(quote_address) as u128) as u256);
        let denominator_u256 = (quote_dec_factor as u256);
        let result_u256 = numerator_u256 / denominator_u256;
        assert!(
            result_u256 <= (U128_MAX as u256),
            error::invalid_argument(ERROR_OVERFLOW)
        );
        let virtual_token_reserves_u128 = (result_u256 as u128);
        assert!(virtual_token_reserves_u128 > 0, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));

        (virtual_quote_reserves_u128, virtual_token_reserves_u128)
    }

    fun get_percentage_bps_reward_internal(raising: u64, quote_address: address): u64 {
        let (_min_limit, lower_threshold, upper_threshold, _max_limit) = get_raise_limits_for_quote(quote_address);
        let (meme_pct, dao_pct, big_dao_pct) = launch_config::get_raising_percentages();

        if (raising <= lower_threshold) {
            meme_pct
        } else if (raising <= upper_threshold) {
            dao_pct
        } else {
            big_dao_pct
        }
    }

    fun is_meme_project_internal(raising: u64, quote_address: address): bool {
        let (_min_limit, lower_threshold, _upper_threshold, _max_limit) = get_raise_limits_for_quote(quote_address);
        raising <= lower_threshold
    }

    public entry fun swap_quote_for_exact_tokens(
        caller: &signer,
        token_address: address,
        buy_token_amount: u64,
        max_quote_in: u64
    ) {
        let (platform_fee_bps, _, creator_fee_bps, platform_fee_address) = launch_config::get_platform_fees();
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let quote_obj = get_quote_obj_internal(pool_address);

        assert!(!pool::is_completed(pool_address), error::invalid_state(ERROR_PUMP_COMPLETED));
        let (v_quote, v_token) = pool::get_reserves(pool_address);
        assert!((buy_token_amount as u128) < v_token, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let min_trade_amount = pool::get_min_trade_amount(pool_address);
        let current_quote_balance = pool::get_quote_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_quote_to_add = if (required_balance > current_quote_balance) { required_balance - current_quote_balance } else { 0 };

        let liquidity_cost_u128 = math::calculate_add_liquidity_cost(
            v_quote,
            v_token,
            (buy_token_amount as u128)
        );

        assert!((liquidity_cost_u128 as u64) <= max_quote_to_add, error::invalid_state(ERROR_PUMP_COMPLETED));

        let platform_fee_u128 = aptos_std::math128::mul_div(liquidity_cost_u128, (platform_fee_bps as u128), 10000);
        let creator_fee_u128 = aptos_std::math128::mul_div(liquidity_cost_u128, (creator_fee_bps as u128), 10000);

        let total_cost_u128 = liquidity_cost_u128 + platform_fee_u128 + creator_fee_u128;
        let total_cost_u64 = (total_cost_u128 as u64);
        assert!(total_cost_u64 <= max_quote_in, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));
        assert!(total_cost_u64 >= min_trade_amount, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));

        let total_quote_asset = withdraw_quote_internal(caller, quote_obj, total_cost_u64);
        let platform_fee_asset = fungible_asset::extract(&mut total_quote_asset, (platform_fee_u128 as u64));
        let creator_fee_asset = fungible_asset::extract(&mut total_quote_asset, (creator_fee_u128 as u64));

        distribute_quote_fees_internal(
            pool_address,
            quote_obj,
            platform_fee_address,
            platform_fee_asset,
            creator_fee_asset
        );

        pool::deposit_quote(pool_address, total_quote_asset);

        let sender = address_of(caller);
        asset_manager::mint(token_address, sender, buy_token_amount);

        event::emit(
            TradeEvent {
                quote_amount: (liquidity_cost_u128 as u64),
                is_buy: true,
                token_address,
                token_amount: buy_token_amount,
                user: sender,
                timestamp: timestamp::now_seconds(),
            }
        );

        check_and_complete_pool_internal(pool_address);
    }

    public entry fun deploy_and_buy_for_exact_quote(
        caller: &signer,
        raising: u64,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        description: String,
        socials: String,
        quote_address: address,
        unstake_period_seconds: u64,
        quote_in_amount: u64,
        min_token_out: u64
    ) {
        let token_address = deploy_internal(caller, raising, name, symbol, uri, website, description, socials, quote_address, unstake_period_seconds);

        if (quote_in_amount > 0) {
            buy_tokens(caller, token_address, quote_in_amount, min_token_out);
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
        // stake() is blocked once the bonding curve has completed. This prevents
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
        let (v_quote, v_token) = pool::get_reserves(pool_address);

        let token_amount = aptos_std::math128::min((buy_token_amount as u128), v_token);
        math::calculate_add_liquidity_cost(v_quote, v_token, token_amount)
    }

    #[view]
    public fun get_current_pool_quote_balance(token_address: address): u64 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        pool::get_quote_balance(pool_address)
    }

    #[view]
    public fun buy_quote_amount(token_address: address, buy_quote_amount: u64): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        let current_quote_balance = pool::get_quote_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);
        let max_quote_to_add = if (required_balance > current_quote_balance) { required_balance - current_quote_balance } else { 0 };

        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();

        let quote_in_amount = buy_quote_amount;
        let platform_fee = aptos_std::math64::mul_div(quote_in_amount, platform_fee_bps, 10000);
        let creator_fee = aptos_std::math64::mul_div(quote_in_amount, creator_fee_bps, 10000);
        let total_fees = platform_fee + creator_fee;

        let quote_to_pool_amount_u64 = if (quote_in_amount > total_fees) { quote_in_amount - total_fees } else { 0 };

        if (quote_to_pool_amount_u64 > max_quote_to_add) {
            let excess_pool_amount = quote_to_pool_amount_u64 - max_quote_to_add;
            let total_fees_bps = platform_fee_bps + creator_fee_bps;
            let excess_input = aptos_std::math64::mul_div(excess_pool_amount, 10000, 10000 - total_fees_bps);

            quote_in_amount = if (quote_in_amount > excess_input) { quote_in_amount - excess_input } else { 0 };
            platform_fee = aptos_std::math64::mul_div(quote_in_amount, platform_fee_bps, 10000);
            creator_fee = aptos_std::math64::mul_div(quote_in_amount, creator_fee_bps, 10000);
            total_fees = platform_fee + creator_fee;
            quote_to_pool_amount_u64 = if (quote_in_amount > total_fees) { quote_in_amount - total_fees } else { 0 };
        };

        let (v_quote, v_token) = pool::get_reserves(pool_address);
        math::calculate_buy_token(v_token, v_quote, (quote_to_pool_amount_u64 as u128))
    }

    #[view]
    public fun sell_token(token_address: address, sell_token_amount: u64): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let (v_quote, v_token) = pool::get_reserves(pool_address);
        math::calculate_sell_token(v_token, v_quote, (sell_token_amount as u128))
    }

    #[view]
    public fun get_current_price(token_address: address): u128 {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let (v_quote, v_token) = pool::get_reserves(pool_address);
        aptos_std::math128::mul_div(v_quote, (100_000_000 as u128), v_token)
    }

    #[view]
    public fun buy_price_with_fee(token_address: address, buy_meme_amount: u64): u128 {
        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();
        let quote_pool = buy_token_amount(token_address, buy_meme_amount);
        let total_fees_bps = platform_fee_bps + creator_fee_bps;
        aptos_std::math128::mul_div(quote_pool, 10000, 10000 - (total_fees_bps as u128))
    }

    #[view]
    public fun sell_price_with_fee(token_address: address, sell_meme_amount: u64): u128 {
        let (platform_fee_bps, _, creator_fee_bps, _) = launch_config::get_platform_fees();
        let quote_amount = sell_token(token_address, sell_meme_amount);
        let platform_fee = aptos_std::math128::mul_div(quote_amount, (platform_fee_bps as u128), 10000);
        let creator_fee = aptos_std::math128::mul_div(quote_amount, (creator_fee_bps as u128), 10000);
        let total_fees = platform_fee + creator_fee;
        if (quote_amount > total_fees) {
            quote_amount - total_fees
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
        let (initial_v_token, initial_v_quote) = pool::get_initial_virtual_pools(pool_address);
        let expected_supply = math::calculate_ideal_projected_supply_base(
            initial_v_token,
            initial_v_quote,
            target_threshold
        );
        petra::create_dao_static_from_launcher(
            caller,
            &resource_signer,
            token_obj,
            expected_supply
        );
    }

    #[view]
    public fun get_bonding_curve_progress_data(token_address: address): (u64, u64, bool) {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);
        let target_amount = pool::get_target_threshold(pool_address);
        let is_completed = pool::is_completed(pool_address);
        let current_amount = pool::get_quote_balance(pool_address);
        (current_amount, target_amount, is_completed)
    }

    #[view]
    public fun calculate_virtual_pools(raising: u64, quote_address: address): (u128, u128) {
        calculate_virtual_pools_internal(raising, quote_address)
    }

    #[view]
    public fun get_percentage_bps_reward(raising: u64, quote_address: address): u64 {
        get_percentage_bps_reward_internal(raising, quote_address)
    }

    #[view]
    public fun get_user_stake_info(token_address: address, user_addr: address): (u64, u64) {
        let resource_address = launch_config::get_resource_address();
        let total_staked = hodl_fa::get_user_stake_or_zero(resource_address, token_address, token_address, user_addr);
        let unlocked_amount = hodl_fa::get_unlocked_stake_amount(resource_address, token_address, token_address, user_addr);
        (unlocked_amount, total_staked)
    }

    #[view]
    public fun get_hodl_pool_stats(token_address: address): (u64, u128) {
        let resource_address = launch_config::get_resource_address();
        let total_staked = hodl_fa::get_pool_total_stake(resource_address, token_address, token_address);
        let total_supply = asset_manager::get_total_supply(token_address);
        (total_staked, total_supply)
    }

    #[view]
    public fun get_pool_state(token_address: address): PoolStateView {
        let resource_address = launch_config::get_resource_address();
        let pool_address = pool::get_pool_address(resource_address, token_address);

        let (v_quote, v_token) = pool::get_reserves(pool_address);

        PoolStateView {
            token_address,
            quote_metadata: pool::get_quote_metadata(pool_address),
            virtual_token_reserves: v_token,
            virtual_quote_reserves: v_quote,
            is_completed: pool::is_completed(pool_address),
            is_migrated_to_dex: pool::is_migrated(pool_address),
            target_threshold: pool::get_target_threshold(pool_address),
            dev_address: pool::get_dev_address(pool_address),
        }
    }

    // --- Internal helpers ---

    fun get_quote_obj_internal(pool_address: address): Object<Metadata> {
        // Pool's data stays module-internal: pool::get_quote_metadata handles
        // its global storage borrow; callers only map the address -> Metadata.
        let quote_metadata = pool::get_quote_metadata(pool_address);
        object::address_to_object<Metadata>(quote_metadata)
    }

    /// Withdraw `amount` RAW units of the quote from the caller.
    /// Quotes are FA-native by design (AMM-canonical address), so a primary store
    /// can always be registered on demand.
    /// [V3-SUPRA-TRACK] For the network-native SUPRA quote, wallets hold the
    /// legacy `Coin<SupraCoin>` (whose balance the framework mixes with the
    /// 0xA-FA store). If the FA balance alone can't cover it, we pull the coin
    /// natively (public `coin::withdraw` the mixed one) and convert via the
    /// framework's public bridge. Users keep paying raw SUPRA. No wrappers,
    /// no AMM involvement, single tx.
    fun withdraw_quote_internal(
        caller: &signer,
        quote_obj: Object<Metadata>,
        amount: u64
    ): FungibleAsset {
        let sender = address_of(caller);
        if (!primary_fungible_store::primary_store_exists(sender, quote_obj)) {
            primary_fungible_store::create_primary_store(sender, quote_obj);
        };
        let balance = primary_fungible_store::balance(sender, quote_obj);
        if (balance < amount && launch_config::is_supra_native_fa(object::object_address(&quote_obj))) {
            // Mixed withdraw-through-framework: CoinStore + 0xA-FA store combined.
            let supra_coins = coin::withdraw<SupraCoin>(caller, amount);
            return coin::coin_to_fungible_asset<SupraCoin>(supra_coins)
        };
        assert!(balance >= amount, error::invalid_argument(ERROR_INSUFFICIENT_BALANCE));
        // [FIX (audit13 R-1)] No tax-free user route: the user pays from their
        // own store via the token's STANDARD dispatch flow. If the quote's DAO
        // keeps its taxes off during the curve phase the leg is free; once the
        // DAO enables them, every user pays them and bots can no longer dodge
        // them the TaxFree routes are now reachable ONLY by the whitelisted
        // router proof (the pool object / the launcher resource account).
        primary_fungible_store::withdraw(caller, quote_obj, amount)
    }

    /// Distributes quote fees to the platform and dev. FA primary stores are
    /// created on demand, so a missing store can never disrupt payouts 
    /// preserving the anti-DoS goal of v2's [FIX-H3.1] fallback without needing
    /// a fallback address at all.
    fun distribute_quote_fees_internal(
        pool_address: address,
        quote_obj: Object<Metadata>,
        platform_fee_address: address,
        platform_fee_coin: FungibleAsset,
        creator_fee_coin: FungibleAsset
    ) {
        let dev_address = pool::get_dev_address(pool_address);
        let quote_dao_opt = petra::get_dao_for_token(quote_obj);
        if (option::is_some(&quote_dao_opt)) {
            // [FIX-H2 + audit13 R-1]: router proof = launcher's shared
            // resource account signer; fees arrive FULL at dev/platform.
            let router_signer = &launch_config::get_resource_signer();
            let dao_address = *option::borrow(&quote_dao_opt);
            let dev_store = primary_fungible_store::ensure_primary_store_exists(dev_address, quote_obj);
            tax_router::deposit_tax_free(dao_address, router_signer, dev_store, creator_fee_coin);
            let platform_store = primary_fungible_store::ensure_primary_store_exists(platform_fee_address, quote_obj);
            tax_router::deposit_tax_free(dao_address, router_signer, platform_store, platform_fee_coin);
        } else {
            if (!primary_fungible_store::primary_store_exists(dev_address, quote_obj)) {
                primary_fungible_store::create_primary_store(dev_address, quote_obj);
            };
            primary_fungible_store::deposit(dev_address, creator_fee_coin);

            if (!primary_fungible_store::primary_store_exists(platform_fee_address, quote_obj)) {
                primary_fungible_store::create_primary_store(platform_fee_address, quote_obj);
            };
            primary_fungible_store::deposit(platform_fee_address, platform_fee_coin);
        };
    }

    fun check_and_complete_pool_internal(pool_address: address) {
        let current_quote_balance = pool::get_quote_balance(pool_address);
        let required_balance = pool::get_target_threshold(pool_address);

        if (current_quote_balance >= required_balance && !pool::is_completed(pool_address)) {
            let (final_v_quote, final_v_token) = pool::get_reserves(pool_address);
            pool::set_completed(pool_address, final_v_token, final_v_quote);
        }
    }
}


