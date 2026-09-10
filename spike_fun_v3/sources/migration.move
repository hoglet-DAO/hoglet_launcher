module hoglet_core::migration {
    use std::error;
    use std::signer::address_of;
    use std::option;
    use aptos_std::math128;
    use aptos_std::math64;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::primary_fungible_store;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use hoglet_core::pool;
    use hoglet_core::launch_config;
    use hoglet_core::asset_manager;
    use spike_amm::amm_router;
    use spike_amm::amm_pair;
    use hoglet_hodl::hodl_fa;
    use hoglet_buffer::manager;
    friend hoglet_core::hoglet_core;
    use dao_factory::petra;
    use dao_factory::tax_router;
    use dao_factory::zeal;
    use dao_factory::restore;
    use dao_factory::legacy;
    use dao_tokens::smart_token;
    use supra_framework::timestamp;
    use supra_framework::event;

    const ERROR_MIGRATION_STATE_INCONSISTENCY: u64 = 25;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    // [AUDIT-V3-10] Buffer exchange returned less than the tolerance-adjusted
    // 1:1 SUPRA expectation: seeding would be under-backed (arbitrage drain).
    const ERROR_BUFFER_RATE_DEGRADED: u64 = 14;

    const U64_MAX_AS_U128: u128 = 18446744073709551615u128;

    struct MigrationRewards has store, drop, copy {
        dev_reward: u64,
        staking_reward: u64,
        migrator_reward: u64,
    }

    #[event]
    struct MigrationEvent has drop, store {
        token_address: address,
        pool_address: address,
        quote_address: address,
        quote_for_amm: u64,
        tokens_for_lp: u64,
        migrator_address: address,
        timestamp: u64
    }

    public(friend) fun prepare_quote_for_migration(
        real_quote_reserves_mut: &mut FungibleAsset,
        router_signer: &signer,
        target_threshold: u64,
        benefitiary_address: address,
        quote_obj: Object<Metadata>
    ): u64 {
        let current_quote_in_pool = fungible_asset::amount(real_quote_reserves_mut);

        if (current_quote_in_pool > target_threshold) {
            let excess_amount = current_quote_in_pool - target_threshold;
            let excess_quote = fungible_asset::extract(real_quote_reserves_mut, excess_amount);
            if (!primary_fungible_store::primary_store_exists(benefitiary_address, quote_obj)) {
                primary_fungible_store::create_primary_store(benefitiary_address, quote_obj);
            };
            // [FIX-H1] Tax-aware quotes: the excess refund routes tax-free via the
            // quote's DAO TaxFreeCap (bypasses their own tax hooks - the smart
            // token has dispatch registered from birth). Vanilla primary deposit
            // would abort (sanity-abort-on-dispatch) since the hooks are already
            // registered by design. Falls back internally for non-router quotes.
            // [FIX (audit13 R-1)] The router proof is the launcher's own shared
            // resource account signer whitelisted in EVERY launcher-DAO's
            // TaxFreeRouter at its migration; users can never produce it.
            let dao_opt = petra::get_dao_for_token(quote_obj);
            let beneficiary_store = primary_fungible_store::ensure_primary_store_exists(benefitiary_address, quote_obj);
            if (option::is_some(&dao_opt)) {
                tax_router::deposit_tax_free(*option::borrow(&dao_opt), router_signer, beneficiary_store, excess_quote);
            } else {
                fungible_asset::deposit(beneficiary_store, excess_quote);
            };
        };

        fungible_asset::amount(real_quote_reserves_mut)
    }

    public(friend) fun calculate_migration_mints(
        pool_address: address,
        migrator_reward_bps: u64,
        quote_value_for_amm: u64,
        is_meme: bool
    ): (u64, MigrationRewards) {
        let (v_quote, v_token) = pool::get_snapshots(pool_address);
        let (initial_v_quote, initial_v_token) = pool::get_initial_reserves(pool_address);
        let target = pool::get_target_threshold(pool_address);
        let raising_percent = pool::get_raising_percent(pool_address);

        let ideal_token_supply = hoglet_core::math::calculate_ideal_projected_supply_base(
            initial_v_token,
            initial_v_quote,
            target
        );

        let tokens_for_lp_u128 = math128::mul_div(
            (quote_value_for_amm as u128),
            v_token,
            v_quote
        );

        let dev_reward_bps = raising_percent;
        let dev_reward_u128 = math128::mul_div(ideal_token_supply, (dev_reward_bps as u128), 10000);

        let staking_reward_bps = if (is_meme) { launch_config::get_staking_reward_meme_bps() } else { 0 };
        let staking_reward_u128 = math128::mul_div(ideal_token_supply, (staking_reward_bps as u128), 10000);
        let migrator_reward_u128 = math128::mul_div(ideal_token_supply, (migrator_reward_bps as u128), 10000);

        assert!(tokens_for_lp_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(dev_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(staking_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(migrator_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));

        let tokens_for_lp = (tokens_for_lp_u128 as u64);
        assert!(tokens_for_lp > 0, error::invalid_state(ERROR_MIGRATION_STATE_INCONSISTENCY));

        let rewards = MigrationRewards {
            dev_reward: (dev_reward_u128 as u64),
            staking_reward: (staking_reward_u128 as u64),
            migrator_reward: (migrator_reward_u128 as u64),
        };

        (tokens_for_lp, rewards)
    }

    public(friend)     fun mint_and_distribute_rewards(
        token_address: address,
        rewards: &MigrationRewards,
        resource_signer: &signer,
        pool_key_staking: &hodl_fa::PoolIdentifier,
        dev_address: address,
        migrator_address: address,
        is_meme: bool,
        seeded_pool_addr: address,
        curve_pool_address: address
    ) {
        let resource_addr = address_of(resource_signer);

        if (rewards.dev_reward > 0) {
            if (is_meme) {
                asset_manager::mint(token_address, resource_addr, rewards.dev_reward);

                let token_metadata_obj = object::address_to_object<Metadata>(token_address);
                if (!primary_fungible_store::primary_store_exists(resource_addr, token_metadata_obj)) {
                    primary_fungible_store::create_primary_store(resource_addr, token_metadata_obj);
                };

                let primary_store = primary_fungible_store::primary_store(resource_addr, token_metadata_obj);
                let dev_reward_asset = supra_framework::fungible_asset::withdraw(resource_signer, primary_store, rewards.dev_reward);

                hodl_fa::deposit_and_stake_for_beneficiary(
                    resource_signer,
                    *pool_key_staking,
                    dev_address,
                    dev_reward_asset
                );
            } else {
                asset_manager::mint(token_address, dev_address, rewards.dev_reward);
            };
        };

        if (is_meme) {
            asset_manager::mint(token_address, resource_addr, rewards.staking_reward);
            hodl_fa::finalize_hodl_pool_rewards(resource_signer, *pool_key_staking, rewards.staking_reward);
        };

        asset_manager::mint(token_address, migrator_address, rewards.migrator_reward);
        if (is_meme) {
            asset_manager::disable_minting(token_address);
        } else {
            let token_obj = object::address_to_object<Metadata>(token_address);
            let dao_address_opt = petra::get_dao_for_token(token_obj);
            if (option::is_some(&dao_address_opt)) {
                let dao_address = option::extract(&mut dao_address_opt);

                let mint_ref = asset_manager::extract_mint_ref(token_address);
                petra::activate_dao_inflationary(
                    resource_signer,
                    dao_address,
                    token_obj,
                    mint_ref
                );

                // Transfer the absolute power of the Smart Tokens to the newly activated DAO
                let cap_opt = asset_manager::extract_smart_token_cap(token_address);
                if (option::is_some(&cap_opt)) {
                    let cap = option::extract(&mut cap_opt);

                    // SECURITY WARNING (M-06): This entire block (set_dao_admin -> set_exemption -> transfer_admin)
                    // MUST remain within a single atomic transaction. Do NOT refactor this into multiple entry
                    // functions. If the transaction were to abort after set_dao_admin but before transfer_admin,
                    // the resource_signer would permanently retain the admin role and the token would be compromised.
                    smart_token::set_dao_admin(cap, address_of(resource_signer));

                    // Exempt the DAO itself
                    smart_token::set_exemption(token_address, resource_signer, dao_address, true);

                    // Exempt all initial Gauges
                    let gauge_count = zeal::get_gauge_count(dao_address);
                    let mut_i = 0;
                    while (mut_i < gauge_count) {
                        let gauge_address = zeal::get_gauge_destination(dao_address, mut_i);
                        smart_token::set_exemption(token_address, resource_signer, gauge_address, true);
                        mut_i = mut_i + 1;
                    };

                    // Exempt the Vaults of the DAO infrastructure
                    smart_token::set_exemption(token_address, resource_signer, zeal::get_vault_address(dao_address), true);
                    smart_token::set_exemption(token_address, resource_signer, restore::get_vault_address(dao_address), true);
                    smart_token::set_exemption(token_address, resource_signer, legacy::get_rebase_store_address(dao_address), true);

                    // SECURITY FIX: Exempt the AMM pair from smart token taxes
                    smart_token::set_exemption(token_address, resource_signer, seeded_pool_addr, true);

                    // Transfer absolute power to the DAO
                    smart_token::update_treasury_address(token_address, resource_signer, dao_address);

                    // FIX (audit10 C2): exchange the transfer_ref for a TaxFreeCap and store
                    // it BEFORE transfer_admin enable_tax_free_routing asserts
                    // caller == admin, which is still the resource_signer here. Doing it
                    // after transfer_admin aborts with E_NOT_AUTHORIZED and reverts the
                    // whole migration, permanently trapping the pool's quote.
                    let transfer_ref = asset_manager::extract_transfer_ref(token_address);
                    let tax_free_cap = smart_token::enable_tax_free_routing(resource_signer, token_address, transfer_ref);

                    // FIX (audit13 R-1): register the signer-proof routers of
                    // this DAO while the resource signer exists after
                    // migration no user or module can ever add routers again.
                    // Cached: (1) the bonding-curve Pool (its own store
                    // custody), (2) the launcher's shared resource account
                    // (cross-launch flows: a later launch using THIS token as
                    // its quote), (3) the DAO itself (its own trusted infra:
                    // legacy vaults / harvest / restore claims / foundry
                    // gauges same authority that already holds mint/burn).
                    let launch_routers = std::vector::empty<address>();
                    std::vector::push_back(&mut launch_routers, curve_pool_address);
                    std::vector::push_back(&mut launch_routers, resource_addr);
                    std::vector::push_back(&mut launch_routers, dao_address);
                    petra::store_tax_free_cap(resource_signer, dao_address, tax_free_cap, launch_routers);

                    smart_token::transfer_admin(token_address, resource_signer, dao_address);

                    // SECURITY FIX (M-01 & M-07): Destroy leftover god-mode capabilities
                    // EXCEPTION: transfer_ref was exchanged for a TaxFreeCap above
                    asset_manager::destroy_burn_ref(token_address);
                };
            } else {
                asset_manager::disable_minting(token_address);

                // SECURITY FIX (M-01 & M-07): Destroy leftover capabilities for meme coins too
                asset_manager::destroy_transfer_ref(token_address);
                asset_manager::destroy_burn_ref(token_address);
            }
        };
    }

    public(friend) fun orchestrate_migration_to_amm(
        caller: &signer,
        token_address: address,
        pool_address: address,
        deadline: u64
    ) {
        let migrator_address = address_of(caller);

        let resource_signer = launch_config::get_resource_signer();
        let resource_addr = address_of(&resource_signer);

        // The curve ran entirely in the quote's units, so the pool ALREADY holds
        // the exact asset that seeds the AMM pair: seed token/quote directly
        // no SUPRA conversion, no buffer exchange, no oracle dependency.
        let quote_address = pool::get_quote_metadata(pool_address);
        let quote_obj = object::address_to_object<Metadata>(quote_address);

        let mut_quote = pool::extract_all_quote(pool_address);

        let quote_value_for_amm = prepare_quote_for_migration(
            &mut mut_quote,
            &resource_signer,
            pool::get_target_threshold(pool_address),
            launch_config::get_benefitiary_address_for_excess(),
            quote_obj
        );

        // The AMM router withdraws the seed from the resource signer's primary
        // store (smart_withdraw). Ensure the store exists and park the entire
        // collected quote there  exactly the v2 flow's coin::deposit step.
        // [FIX-H1] Tax-aware quotes: the vanilla deposit aborts (their dispatch
        // hooks are registered from birth) route via the quote's DAO
        // TaxFreeCap so the parked seed stays at exact amounts.
        let quote_primary_store = primary_fungible_store::ensure_primary_store_exists(resource_addr, quote_obj);
        let quote_dao_opt = petra::get_dao_for_token(quote_obj);
        if (option::is_some(&quote_dao_opt)) {
            // [FIX (audit13 R-1)] Router proof = launcher's shared resource
            // account signer, already whitelisted in the quote DAO's
            // TaxFreeRouter at that DAO's own migration.
            tax_router::deposit_tax_free(*option::borrow(&quote_dao_opt), &resource_signer, quote_primary_store, mut_quote);
        } else {
            fungible_asset::deposit(quote_primary_store, mut_quote);
        };

        let is_meme = pool::is_meme(pool_address);

        let (tokens_for_lp, rewards) = calculate_migration_mints(
            pool_address,
            launch_config::get_migrator_reward_bps(),
            quote_value_for_amm,
            is_meme
        );

        let pool_key_staking = hodl_fa::new_pool_identifier(resource_addr, token_address, token_address);

        asset_manager::mint(token_address, resource_addr, tokens_for_lp);

        let token_obj = object::address_to_object<Metadata>(token_address);

        // [V3-BUFFER-ROUTE] Resolve the seed route EARLY: the seeded pool
        // address must be known before mint_and_distribute_rewards (the DAO
        // track exempts it from smart-token taxes AND the gauge block activates
        // it). SUPRA-native pools may seed (token, iasset) through the buffer
        // exchange iSUPRA liquidity means PoEL yield for LPs and gauge
        // income ONLY when ALL preconditions hold. [FIX v2-audit] v2 committed
        // the route after checking STOCK alone: a paused buffer with stock
        // aborted the whole iasset route instead of falling back. Here EVERY
        // precondition is verified upfront; ANY failure selects the canonical
        // bwsup path (fail-open, never blocking, retryable semantics).
        let is_supra_quote = launch_config::is_supra_native_fa(quote_address);
        let buffer_route_available = if (is_supra_quote && launch_config::is_buffer_enabled()) {
            let iasset_quote_address = launch_config::get_buffer_iasset_address();
            if (iasset_quote_address == @0x0) {
                false
            } else {
                let iasset_obj_probe = object::address_to_object<Metadata>(iasset_quote_address);
                manager::is_whitelisted(resource_addr)
                    && !manager::is_paused()
                    && manager::get_available_iasset_stock(iasset_obj_probe) >= quote_value_for_amm
            }
        } else {
            false
        };

        let seeded_pool: address;
        let iasset_route_info: option::Option<address> = if (buffer_route_available) {
            let iasset_quote_address = launch_config::get_buffer_iasset_address();
            let pair_quote_obj = object::address_to_object<Metadata>(iasset_quote_address);
            seeded_pool = amm_pair::liquidity_pool_address(token_obj, pair_quote_obj);
            option::some(iasset_quote_address)
        } else if (is_supra_quote) {
            let bwsup_obj = object::address_to_object<Metadata>(amm_router::get_address_BWSUP());
            seeded_pool = amm_pair::liquidity_pool_address(token_obj, bwsup_obj);
            option::none()
        } else {
            seeded_pool = amm_pair::liquidity_pool_address(token_obj, quote_obj);
            option::none()
        };

        mint_and_distribute_rewards(
            token_address,
            &rewards,
            &resource_signer,
            &pool_key_staking,
            pool::get_dev_address(pool_address),
            migrator_address,
            is_meme,
            seeded_pool,
            pool_address
        );

        let migration_slippage = launch_config::get_migration_slippage_bps();
        assert!(migration_slippage <= 10000, ERROR_SLIPPAGE_TOO_HIGH);
        let slippage_numerator = 10000 - migration_slippage;
        let amount_token_min = math64::mul_div(tokens_for_lp, slippage_numerator, 10000);
        let amount_quote_min = math64::mul_div(quote_value_for_amm, slippage_numerator, 10000);

        if (option::is_some(&iasset_route_info)) {
            // --- Buffer route: SUPRA -> iasset, seed (token, iasset) ---
            let iasset_obj = object::address_to_object<Metadata>(*option::borrow(&iasset_route_info));
            // Convert the collected 0xA-FA custody into native SUPRA via the
            // framework's own mixed withdraw (CoinStore + 0xA-FA store merged).
            let supra_coins = coin::withdraw<SupraCoin>(&resource_signer, quote_value_for_amm);
            let iasset_fa = manager::exchange_coin_for_launch(&resource_signer, supra_coins, iasset_obj);
            let iasset_amount = fungible_asset::amount(&iasset_fa);

            // [AUDIT-V3-10] Rate guard for the buffer exchange: the buffer may
            // return ANY iasset amount it wants (degraded rate / oracle lag /
            // internal fees) = an under-backed seed would let arbitrage drain
            // the (token, iasset) pool relative to the curve-priced tokens on
            // the first block. Enforce at least the migration-tolerance ratio
            // of the 1:1 SUPRA expectation; a degraded quote aborts the whole
            // tx (funds safe = the migrator retries when the rate normalizes).
            let min_iasset_expected = math64::mul_div(quote_value_for_amm, slippage_numerator, 10000);
            assert!(
                iasset_amount >= min_iasset_expected,
                error::invalid_state(ERROR_BUFFER_RATE_DEGRADED)
            );
            let amount_iasset_min = math64::mul_div(iasset_amount, slippage_numerator, 10000);

            // Park the iasset in the resource store for the router's withdraw.
            let iasset_primary_store = primary_fungible_store::ensure_primary_store_exists(resource_addr, iasset_obj);
            fungible_asset::deposit(iasset_primary_store, iasset_fa);

            // Note: `add_liquidity_from_launchpad_fa` returns () (discards the
            // tuple of beta internals); the minimums are already asserted inside.
            amm_router::add_liquidity_from_launchpad_fa(
                &resource_signer,
                token_address,
                *option::borrow(&iasset_route_info),
                tokens_for_lp,
                amount_token_min,
                iasset_amount,
                amount_iasset_min,
                @0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
                deadline,
            );
        } else {
            // --- Canonical route: seed (token, bwsup) ---
            // fa_beta canonicalizes the quote anyway (0xA -> bwsup) so the
            // seeding withdrawal works through smart_withdraw's native fallback:
            // the 0xA-FA parked in the resource store above is picked up by the
            // framework's own mixed `coin::withdraw` inside the router.
            let (_, _, _, _) = amm_router::add_liquidity_from_launchpad_fa_beta(
                &resource_signer,
                token_address,
                quote_address,
                tokens_for_lp,
                amount_token_min,
                quote_value_for_amm,
                amount_quote_min,
                @0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
                deadline,
            );
        };

        pool::set_migrated(pool_address);

        let dao_opt = petra::get_dao_for_token(token_obj);
        if (option::is_some(&dao_opt)) {
            let dao_address = *option::borrow(&dao_opt);

            // Activate ONLY the gauge of the pool that received the seed
            // liquidity in this migration (token/iasset on the buffer route,
            // token/bwsup on the canonical one). Other gauges were born
            // inactive and cannot receive votes/emissions while their pool is
            // empty; governance can activate them later (anchor,
            // gauge action_type == 2) if they gain organic liquidity.
            petra::activate_seeded_gauge(&resource_signer, dao_address, seeded_pool);

            petra::activate_dao(&resource_signer, dao_address);
        };

        event::emit(
            MigrationEvent {
                token_address,
                pool_address,
                quote_address,
                quote_for_amm: quote_value_for_amm,
                tokens_for_lp,
                migrator_address,
                timestamp: timestamp::now_seconds()
            }
        );
    }
}
