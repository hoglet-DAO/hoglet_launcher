module hoglet_core::migration {
    use std::error;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::primary_fungible_store;
    use supra_framework::object;
    use supra_framework::fungible_asset::Metadata;
    use aptos_std::math128;
    use aptos_std::math64;
    use std::signer::address_of;
    use hoglet_core::pool;
    use hoglet_core::launch_config;
    use hoglet_core::asset_manager;
    use spike_amm::amm_router;
    use spike_amm::amm_factory;
    use spike_amm::amm_pair;
    use spike_amm::coin_wrapper;
    use hoglet_core::hodl_fa;
    friend hoglet_core::hoglet_core;
    use std::option;
    use dao_factory::petra;
    use dao_factory::zeal;
    use dao_factory::restore;
    use dao_factory::legacy;
    use dao_tokens::smart_token;
    use supra_framework::timestamp;
    use supra_framework::event;

    const ERROR_MIGRATION_STATE_INCONSISTENCY: u64 = 25;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;

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
        supra_for_amm: u64,
        tokens_for_lp: u64,
        migrator_address: address,
        timestamp: u64
    }

    public(friend) fun prepare_supra_for_migration(
        real_supra_reserves_mut: &mut Coin<SupraCoin>,
        target_threshold: u64,
        benefitiary_address: address
    ): (u64, u64) {
        let excess_supra_collected = 0u64;
        let current_supra_in_pool = coin::value(real_supra_reserves_mut);

        if (current_supra_in_pool > target_threshold) {
            let excess_amount = current_supra_in_pool - target_threshold;
            let excess_coin = coin::extract(real_supra_reserves_mut, excess_amount);
            if (coin::is_account_registered<SupraCoin>(benefitiary_address)) {
                coin::deposit(benefitiary_address, excess_coin);
            } else {
                coin::deposit(@hoglet_core, excess_coin);
            };
            excess_supra_collected = excess_amount;
        };
        
        let supra_value_for_amm = coin::value(real_supra_reserves_mut);
        (supra_value_for_amm, excess_supra_collected)
    }

    public(friend) fun calculate_migration_mints(
        pool_address: address,
        migrator_reward_bps: u64,
        supra_value_for_amm: u64,
        is_meme: bool
    ): (u64, MigrationRewards) {
        let (v_supra, v_token) = pool::get_snapshots(pool_address);
        let (initial_v_supra, initial_v_token) = pool::get_initial_reserves(pool_address);
        let target = pool::get_target_threshold(pool_address);
        let raising_percent = pool::get_raising_percent(pool_address);

        let ideal_token_supply = hoglet_core::math::calculate_ideal_projected_supply_base(
            initial_v_token,
            initial_v_supra,
            target
        );
        
        let tokens_for_lp_u128 = math128::mul_div(
            (supra_value_for_amm as u128),
            v_token,
            v_supra
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

    public(friend) fun mint_and_distribute_rewards(
        token_address: address,
        rewards: &MigrationRewards,
        resource_signer: &signer,
        pool_key_staking: &hodl_fa::PoolIdentifier,
        dev_address: address,
        migrator_address: address,
        is_meme: bool,
        seeded_pool_addr: address
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
                    // whole migration, permanently trapping the pool's SUPRA.
                    let transfer_ref = asset_manager::extract_transfer_ref(token_address);
                    let tax_free_cap = smart_token::enable_tax_free_routing(resource_signer, token_address, transfer_ref);

                    // Store the TaxFreeCap in the DAO via Petra so immutable DAO modules can use it
                    petra::store_tax_free_cap(resource_signer, dao_address, tax_free_cap);

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
        
        if (!coin::is_account_registered<SupraCoin>(resource_addr)) {
            coin::register<SupraCoin>(&resource_signer);
        };
        
        let mut_supra = pool::extract_all_supra(pool_address);

        let (supra_value_for_amm, _excess_collected) = prepare_supra_for_migration(
            &mut mut_supra,
            pool::get_target_threshold(pool_address),
            launch_config::get_benefitiary_address_for_excess()
        );

        let is_iasset = false;
        let iasset_quote_address = @0x0;
        let mut_iasset = std::option::none<supra_framework::fungible_asset::FungibleAsset>();

        let iasset_amount_for_amm = 0u64;

        if (launch_config::is_buffer_enabled()) {
            let target_iasset_addr = launch_config::get_buffer_iasset_address();
            let iasset_obj = object::address_to_object<Metadata>(target_iasset_addr);
            
            if (hoglet_buffer::manager::is_whitelisted(resource_addr) &&
                !hoglet_buffer::manager::is_paused() && 
                hoglet_buffer::manager::get_available_iasset_stock(iasset_obj) >= supra_value_for_amm &&
                amm_factory::pair_exists(object::address_to_object<Metadata>(token_address), iasset_obj)) {
                
                let mut_supra_for_amm = supra_framework::coin::extract(&mut mut_supra, supra_value_for_amm);
                let iasset_fa = hoglet_buffer::manager::exchange_coin_for_launch(&resource_signer, mut_supra_for_amm, iasset_obj);
                
                iasset_amount_for_amm = supra_framework::fungible_asset::amount(&iasset_fa);
                
                std::option::fill(&mut mut_iasset, iasset_fa);
                is_iasset = true;
                iasset_quote_address = target_iasset_addr;
            };
        };

        if (std::option::is_some(&mut_iasset)) {
            let iasset_fa = std::option::extract(&mut mut_iasset);
            let primary_store = supra_framework::primary_fungible_store::ensure_primary_store_exists(resource_addr, object::address_to_object<Metadata>(iasset_quote_address));
            supra_framework::fungible_asset::deposit(primary_store, iasset_fa);
            supra_framework::coin::deposit<SupraCoin>(resource_addr, mut_supra);
        } else {
            supra_framework::coin::deposit<SupraCoin>(resource_addr, mut_supra);
        };
        std::option::destroy_none(mut_iasset);

        let is_meme = pool::is_meme(pool_address);

        let (tokens_for_lp, rewards) = calculate_migration_mints(
            pool_address,
            launch_config::get_migrator_reward_bps(),
            supra_value_for_amm,
            is_meme
        );
        
        let pool_key_staking = hodl_fa::new_pool_identifier(resource_addr, token_address, token_address);

        asset_manager::mint(token_address, resource_addr, tokens_for_lp);
        
        let token_obj = object::address_to_object<Metadata>(token_address);
        let seeded_pool = if (is_iasset) {
            amm_pair::liquidity_pool_address(token_obj, object::address_to_object<Metadata>(iasset_quote_address))
        } else {
            amm_pair::liquidity_pool_address(token_obj, coin_wrapper::get_wrapper<SupraCoin>())
        };

        mint_and_distribute_rewards(
            token_address,
            &rewards,
            &resource_signer,
            &pool_key_staking,
            pool::get_dev_address(pool_address),
            migrator_address,
            is_meme,
            seeded_pool
        );
        
        let migration_slippage = launch_config::get_migration_slippage_bps();
        assert!(migration_slippage <= 10000, ERROR_SLIPPAGE_TOO_HIGH);
        let slippage_numerator = 10000 - migration_slippage;
        let amount_token_min = math64::mul_div(tokens_for_lp, slippage_numerator, 10000);
        let amount_supra_min = math64::mul_div(supra_value_for_amm, slippage_numerator, 10000);

        if (!is_iasset) {
            let (_, _, _, _) = amm_router::add_liquidity_from_launchpad_aux_beta(
                &resource_signer,
                token_address,
                tokens_for_lp,
                amount_token_min,
                supra_value_for_amm,
                amount_supra_min,
                @0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
                deadline,
            );
        } else {
            let amount_iasset_min = math64::mul_div(iasset_amount_for_amm, slippage_numerator, 10000);
            amm_router::add_liquidity_from_launchpad_fa(
                &resource_signer,
                token_address,
                iasset_quote_address,
                tokens_for_lp,
                amount_token_min,
                iasset_amount_for_amm,
                amount_iasset_min,
                @0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
                deadline,
            );
        };
        
        pool::set_migrated(pool_address);

        let dao_opt = petra::get_dao_for_token(token_obj);
        if (option::is_some(&dao_opt)) {
            let dao_address = *option::borrow(&dao_opt);

            // Activate ONLY the gauge of the pool that received the seed
            // liquidity in this migration (iSUPRA pool if the buffer route
            // was taken, bwSUP pool otherwise). The other pool's gauge was
            // born inactive and cannot receive votes/emissions while its
            // pool is empty; governance can activate it later (anchor,
            // gauge action_type == 2) if it gains organic liquidity.
            petra::activate_seeded_gauge(&resource_signer, dao_address, seeded_pool);

            petra::activate_dao(&resource_signer, dao_address);
        };

        event::emit(
            MigrationEvent {
                token_address,
                pool_address,
                supra_for_amm: supra_value_for_amm,
                tokens_for_lp,
                migrator_address,
                timestamp: timestamp::now_seconds()
            }
        );
    }
}
