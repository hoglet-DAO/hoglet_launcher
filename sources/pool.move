module hoglet_core::pool {
    use std::error;
    use supra_framework::object::{Self, ExtendRef};
    use supra_framework::coin::{Self, Coin};
    use supra_framework::supra_coin::SupraCoin;
    use std::bcs;
    use hoglet_core::asset_manager;

    friend hoglet_core::hoglet_core;
    friend hoglet_core::migration;

    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_MIGRATION_STATE_INCONSISTENCY: u64 = 25;

    struct Pool has key {
        token_address: address,
        initial_virtual_token_supply: u128,
        initial_virtual_supra_reserves: u128,
        target_supra_dex_threshold: u64,
        raising_percent: u64,
        is_completed: bool,
        is_migrated_to_dex: bool,
        dev: address,
        migration_snapshot_v_token_reserves: u128,
        migration_snapshot_v_supra_reserves: u128,
        real_supra_reserves: Coin<SupraCoin>,
        pool_extend_ref: ExtendRef,
        is_meme: bool,
    }

    public(friend) fun create_pool(
        resource_signer: &signer,
        token_address: address,
        initial_virtual_token_supply: u128,
        initial_virtual_supra_reserves: u128,
        target_supra_dex_threshold: u64,
        raising_percent: u64,
        dev: address,
        is_meme: bool
    ): address {
        let pool_seed = bcs::to_bytes(&token_address);
        let constructor_ref = object::create_named_object(resource_signer, pool_seed);
        let pool_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(&pool_signer, Pool {
            token_address,
            initial_virtual_token_supply,
            initial_virtual_supra_reserves,
            target_supra_dex_threshold,
            raising_percent,
            is_completed: false,
            is_migrated_to_dex: false,
            dev,
            migration_snapshot_v_token_reserves: 0,
            migration_snapshot_v_supra_reserves: 0,
            real_supra_reserves: coin::zero<SupraCoin>(),
            pool_extend_ref: extend_ref,
            is_meme,
        });

        object::address_from_constructor_ref(&constructor_ref)
    }

    public fun pool_exists(pool_address: address): bool {
        exists<Pool>(pool_address)
    }

    public fun get_pool_address(resource_address: address, token_address: address): address {
        let pool_seed = bcs::to_bytes(&token_address);
        object::create_object_address(&resource_address, pool_seed)
    }

    public fun is_meme(pool_address: address): bool acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.is_meme
    }

    public(friend) fun deposit_supra(pool_address: address, supra: Coin<SupraCoin>) acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        coin::merge(&mut pool.real_supra_reserves, supra);
    }

    public(friend) fun extract_supra(pool_address: address, amount: u64): Coin<SupraCoin> acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(coin::value(&pool.real_supra_reserves) >= amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        coin::extract(&mut pool.real_supra_reserves, amount)
    }

    public(friend) fun extract_all_supra(pool_address: address): Coin<SupraCoin> acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        coin::extract_all(&mut pool.real_supra_reserves)
    }

    public fun get_supra_balance(pool_address: address): u64 acquires Pool {
        if (!exists<Pool>(pool_address)) {
            return 0
        };
        let pool = borrow_global<Pool>(pool_address);
        coin::value(&pool.real_supra_reserves)
    }

    public(friend) fun set_completed(
        pool_address: address,
        snapshot_v_token: u128,
        snapshot_v_supra: u128
    ) acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(!pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));
        pool.is_completed = true;
        pool.migration_snapshot_v_token_reserves = snapshot_v_token;
        pool.migration_snapshot_v_supra_reserves = snapshot_v_supra;
    }

    public(friend) fun set_migrated(pool_address: address) acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(pool.is_completed, error::invalid_state(ERROR_MIGRATION_STATE_INCONSISTENCY));
        assert!(!pool.is_migrated_to_dex, error::invalid_state(ERROR_MIGRATION_STATE_INCONSISTENCY));
        pool.is_migrated_to_dex = true;
    }

    // Getters
    public fun get_reserves(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        let v_supra = pool.initial_virtual_supra_reserves + (coin::value(&pool.real_supra_reserves) as u128);
        let total_minted = asset_manager::get_total_supply(pool.token_address);
        let v_token = pool.initial_virtual_token_supply - total_minted;
        (v_supra, v_token)
    }

    public fun is_completed(pool_address: address): bool acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.is_completed
    }

    public fun is_migrated(pool_address: address): bool acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.is_migrated_to_dex
    }

    public fun get_target_threshold(pool_address: address): u64 acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.target_supra_dex_threshold
    }

    public fun get_initial_virtual_pools(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.initial_virtual_token_supply, pool.initial_virtual_supra_reserves)
    }

    public fun get_dev_address(pool_address: address): address acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.dev
    }

    public fun get_snapshots(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.migration_snapshot_v_supra_reserves, pool.migration_snapshot_v_token_reserves)
    }

    public fun get_initial_reserves(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.initial_virtual_supra_reserves, pool.initial_virtual_token_supply)
    }

    public fun get_raising_percent(pool_address: address): u64 acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.raising_percent
    }
}
