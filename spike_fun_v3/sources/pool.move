module hoglet_core::pool {
    use std::error;
    use std::bcs;
    use std::option;
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::fungible_asset::{Self, FungibleAsset, FungibleStore, Metadata};
    // [V3-TAX-AWARE] Launcher-launched smart_tokens (TaxFreeRouter en su DAO)
    // custody its routes via the dao_tax_router of its own DAO (bypass of
    // its hooks with its TaxFreeCap - audit9 H-2, audit10 C3).
    use dao_factory::petra;
    use dao_factory::tax_router;
    use hoglet_core::asset_manager;

    friend hoglet_core::hoglet_core;
    friend hoglet_core::migration;

    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_MIGRATION_STATE_INCONSISTENCY: u64 = 25;

    struct Pool has key {
        token_address: address,
        /// AMM-canonical quote asset this pool trades against (whitelist-checked at deploy).
        quote_metadata: address,
        initial_virtual_token_supply: u128,
        initial_virtual_quote_reserves: u128,
        target_threshold: u64,
        /// Frozen from the quote's config at deploy time so a later oracle
        /// refresh can never alter the economics of an in-flight curve.
        min_trade_amount: u64,
        raising_percent: u64,
        is_completed: bool,
        is_migrated_to_dex: bool,
        dev: address,
        migration_snapshot_v_token_reserves: u128,
        migration_snapshot_v_quote_reserves: u128,
        /// FungibleStore object owned by the Pool object (same pattern as the
        /// AMM's Pair reserves). FungibleAsset itself cannot be stored in a
        /// key-struct (no `store` ability).
        quote_store: Object<FungibleStore>,
        /// [AUDIT-V3-4] The pool's OWN accounting of collected quote. The base
        /// store is permissionless-depositable (its address is derivable), so
        /// the curve economics must NEVER read the raw store balance:
        /// donations would otherwise force early completion / price drift /
        /// steal the migration excess. This counter is only touched by
        /// deposit_quote/extract_quote external direct deposits stay frozen
        /// in the store and count for nothing.
        quote_balance_internal: u64,
        pool_extend_ref: ExtendRef,
        is_meme: bool,
        /// [V3-TAX-AWARE] True when the quote is a launcher-launched smart_token
        /// whose DAO holds the TaxFreeRouter: pool custody routes through
        /// `dao_tax_router::deposit/withdraw_tax_free` (hooks bypassed via the
        /// DAO's own TaxFreeCap) so the curve math remains exact 1:1.
        quote_tax_aware: bool,
    }

    public(friend) fun create_pool(
        resource_signer: &signer,
        token_address: address,
        quote_metadata: address,
        is_tax_aware: bool,
        initial_virtual_token_supply: u128,
        initial_virtual_quote_reserves: u128,
        target_threshold: u64,
        min_trade_amount: u64,
        raising_percent: u64,
        dev: address,
        is_meme: bool
    ): address {
        let pool_seed = bcs::to_bytes(&token_address);
        let constructor_ref = object::create_named_object(resource_signer, pool_seed);
        let pool_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        // Dedicated quote reserve store owned by the Pool object itself
        // deposits are permissionless into it, withdrawals require the pool signer.
        let quote_metadata_obj = object::address_to_object<Metadata>(quote_metadata);
        let store_constructor_ref = &object::create_object_from_object(&pool_signer);
        let quote_store = fungible_asset::create_store(store_constructor_ref, quote_metadata_obj);

        move_to(&pool_signer, Pool {
            token_address,
            quote_metadata,
            initial_virtual_token_supply,
            initial_virtual_quote_reserves,
            target_threshold,
            min_trade_amount,
            raising_percent,
            is_completed: false,
            is_migrated_to_dex: false,
            dev,
            migration_snapshot_v_token_reserves: 0,
            migration_snapshot_v_quote_reserves: 0,
            quote_store,
            quote_balance_internal: 0,
            pool_extend_ref: extend_ref,
            is_meme,
            quote_tax_aware: is_tax_aware,
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

    public fun get_quote_metadata(pool_address: address): address acquires Pool {
        borrow_global<Pool>(pool_address).quote_metadata
    }

    public fun get_quote_store_address(pool_address: address): address acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        object::object_address(&pool.quote_store)
    }

    public(friend) fun deposit_quote(pool_address: address, quote: FungibleAsset) acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        let amount = fungible_asset::amount(&quote);
        if (pool.quote_tax_aware) {
            // [V3-TAX-AWARE] Tax-free route of the quote's DAO (TaxFreeCap):
            // the credited == declared (1:1) - the counter matches exactly and the
            // curve math remains deterministic.
            let quote_obj = object::address_to_object<Metadata>(pool.quote_metadata);
            let dao_opt = petra::get_dao_for_token(quote_obj);
            if (option::is_some(&dao_opt)) {
                tax_router::deposit_tax_free(*option::borrow(&dao_opt), pool.quote_store, quote);
            } else {
                fungible_asset::deposit(pool.quote_store, quote);
            };
        } else {
            fungible_asset::deposit(pool.quote_store, quote);
        };
        pool.quote_balance_internal = pool.quote_balance_internal + amount;
    }

    /// [AUDIT-V3-4] Deposits through this friend-path only. The base store is
    /// permissionless-depositable (derivable address), so curve economics must
    /// NEVER trust the raw store balance external direct donations stay
    /// frozen in the store and count for nothing.
    public(friend) fun extract_quote(pool_address: address, amount: u64): FungibleAsset acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(pool.quote_balance_internal >= amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        let balance = fungible_asset::balance(pool.quote_store);
        assert!(balance >= amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        pool.quote_balance_internal = pool.quote_balance_internal - amount;
        let pool_signer = &object::generate_signer_for_extending(&pool.pool_extend_ref);
        if (pool.quote_tax_aware) {
            // [V3-TAX-AWARE] Tax-free extraction via the TaxFreeCap of the DAO of the
            // quote (audit9 H-2: the pool signer is the owner of the store ).
            let quote_obj = object::address_to_object<Metadata>(pool.quote_metadata);
            let dao_opt = petra::get_dao_for_token(quote_obj);
            if (option::is_some(&dao_opt)) {
                tax_router::withdraw_tax_free(*option::borrow(&dao_opt), pool_signer, pool.quote_store, amount)
            } else {
                fungible_asset::withdraw(pool_signer, pool.quote_store, amount)
            }
        } else {
            fungible_asset::withdraw(pool_signer, pool.quote_store, amount)
        }
    }

    public(friend) fun extract_all_quote(pool_address: address): FungibleAsset acquires Pool {
        assert!(exists<Pool>(pool_address), error::not_found(ERROR_PUMP_NOT_EXIST));
        let pool = borrow_global_mut<Pool>(pool_address);
        let amount = pool.quote_balance_internal;
        let balance = fungible_asset::balance(pool.quote_store);
        assert!(balance >= amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        pool.quote_balance_internal = 0;
        let pool_signer = &object::generate_signer_for_extending(&pool.pool_extend_ref);
        if (pool.quote_tax_aware) {
            // [V3-TAX-AWARE] Tax-free extraction via the TaxFreeCap of the DAO of the
            // quote (audit9 H-2: the pool signer is the owner of the store ).
            let quote_obj = object::address_to_object<Metadata>(pool.quote_metadata);
            let dao_opt = petra::get_dao_for_token(quote_obj);
            if (option::is_some(&dao_opt)) {
                tax_router::withdraw_tax_free(*option::borrow(&dao_opt), pool_signer, pool.quote_store, amount)
            } else {
                fungible_asset::withdraw(pool_signer, pool.quote_store, amount)
            }
        } else {
            fungible_asset::withdraw(pool_signer, pool.quote_store, amount)
        }
    }

    /// [AUDIT-V3-4] Returns the pool's own accounting, NOT the raw store
    /// balance permissionless store donations must never count for the
    /// curve (completion/prices/migration excess).
    public fun get_quote_balance(pool_address: address): u64 acquires Pool {
        if (!exists<Pool>(pool_address)) {
            return 0
        };
        borrow_global<Pool>(pool_address).quote_balance_internal
    }

    public(friend) fun set_completed(
        pool_address: address,
        snapshot_v_token: u128,
        snapshot_v_quote: u128
    ) acquires Pool {
        let pool = borrow_global_mut<Pool>(pool_address);
        assert!(!pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));
        pool.is_completed = true;
        pool.migration_snapshot_v_token_reserves = snapshot_v_token;
        pool.migration_snapshot_v_quote_reserves = snapshot_v_quote;
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
        let v_quote = pool.initial_virtual_quote_reserves + (pool.quote_balance_internal as u128);
        let total_minted = asset_manager::get_total_supply(pool.token_address);
        let v_token = pool.initial_virtual_token_supply - total_minted;
        (v_quote, v_token)
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
        pool.target_threshold
    }

    public fun get_min_trade_amount(pool_address: address): u64 acquires Pool {
        borrow_global<Pool>(pool_address).min_trade_amount
    }

    public fun get_initial_virtual_pools(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.initial_virtual_token_supply, pool.initial_virtual_quote_reserves)
    }

    public fun get_dev_address(pool_address: address): address acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.dev
    }

    public fun get_snapshots(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.migration_snapshot_v_quote_reserves, pool.migration_snapshot_v_token_reserves)
    }

    public fun get_initial_reserves(pool_address: address): (u128, u128) acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        (pool.initial_virtual_quote_reserves, pool.initial_virtual_token_supply)
    }

    public fun get_raising_percent(pool_address: address): u64 acquires Pool {
        let pool = borrow_global<Pool>(pool_address);
        pool.raising_percent
    }
}
