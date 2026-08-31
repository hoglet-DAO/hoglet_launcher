module hoglet_core::hodl_fa {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{String};
    use std::vector;

    use supra_framework::event;
    use aptos_std::math64;
    use aptos_std::math128;
    use aptos_std::error;

    use supra_framework::account;
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Self, Metadata, FungibleStore, FungibleAsset};
    use supra_framework::primary_fungible_store; 
    use supra_framework::timestamp;
    use supra_framework::table::{Self, Table};
    use aptos_token::token::{Self, Token};
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin::{Self};
    use hoglet_core::hodl_fa_config;

    const ERR_REWARD_CANNOT_BE_ZERO: u64 = 1;
    const ERR_AMOUNT_CANNOT_BE_ZERO: u64 = 2;
    const ERR_DURATION_CANNOT_BE_ZERO: u64 = 3;
    const ERR_INVALID_BOOST_PERCENT: u64 = 4;
    const ERR_WRONG_TOKEN_COLLECTION: u64 = 5;
    const ERR_INITIAL_REWARD_AMOUNT_ZERO: u64 = 6;
    const ERR_REWARD_RATE_ZERO: u64 = 7;
    const ERR_INVALID_INITIAL_SETUP_FOR_HODL_POOL: u64 = 8;
    const ERR_NFT_AMOUNT_MORE_THAN_ONE: u64 = 9;
    const ERR_INVALID_CONFIG_DURATION: u64 = 10;
    const ERR_INVALID_CONFIG_VALUE: u64 = 11;

    const ERR_NOTHING_TO_HARVEST: u64 = 21;
    const ERR_TOO_EARLY_UNSTAKE: u64 = 22;
    const ERR_EMERGENCY: u64 = 23;
    const ERR_NO_EMERGENCY: u64 = 24;
    const ERR_HARVEST_FINISHED: u64 = 25;
    const ERR_NOT_WITHDRAW_PERIOD: u64 = 26;
    const ERR_NON_BOOST_POOL: u64 = 27;
    const ERR_ALREADY_BOOSTED: u64 = 28;
    const ERR_NO_BOOST: u64 = 29;
    const ERR_STAKES_ALREADY_CLOSED: u64 = 30;
    const ERR_HODL_POOL_NOT_FINALIZED_FOR_HARVEST: u64 = 31;
    const ERR_NEGATIVE_PENDING_REWARD: u64 = 32;

    const ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY: u64 = 41;
    const ERR_NOT_TREASURY: u64 = 42;
    const ERR_NOT_AUTHORIZED: u64 = 43;

    const ERR_NO_POOL: u64 = 51;
    const ERR_NO_STAKE: u64 = 52;
    const ERR_NO_COLLECTION: u64 = 53;

    const ERR_POOL_ID_ALREADY_EXISTS: u64 = 61;
    const ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE: u64 = 62;

    const ERR_NOT_ENOUGH_S_BALANCE: u64 = 71;
    const ERR_DURATION_OVERFLOW: u64 = 72;
    const ERR_MUL_OVERFLOW_IN_ACCUM_REWARD_UPDATE: u64 = 73;
    const ERR_ACCUM_REWARD_ADD_OVERFLOW: u64 = 74;        
    const ERR_REWARD_DEBT_CALC_OVERFLOW: u64 = 75;
    const ERR_WITHDRAW_AMOUNT_EXCEEDS_UNLOCKED: u64 = 76;


    const ERR_NO_PENDING_ADMIN_TRANSFER: u64 = 81;
    const ERR_NOT_THE_PENDING_ADMIN: u64 = 82;
    const ERR_CANNOT_TRANSFER_TO_SELF: u64 = 83;
    const ERR_INSUFFICIENT_SUPRA_FOR_FEE: u64 = 84;
    
    const MAX_U64: u64 = 0xFFFFFFFFFFFFFFFFu64;
    const MAX_U128: u128 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const MIN_NFT_BOOST_PRECENT: u128 = 1;
    const MAX_NFT_BOOST_PERCENT: u128 = 100;
    const MIN_TREASURY_GRACE_PERIOD_SECONDS: u64 = 7 * 24 * 60 * 60; 
    const MAX_TREASURY_GRACE_PERIOD_SECONDS: u64 = 365 * 24 * 60 * 60;

    const ACCUM_REWARD_SCALE: u128 = 1000000000000;
    const DAILY_UNSTAKE_PERCENT: u64 = 1;
    const SECONDS_IN_A_DAY: u64 = 86400;
    const MODULE_RESOURCE_ACCOUNT_SEED: vector<u8> = b"Hoglet_HODL";
    const MODULE_ADMIN_ACCOUNT: address = @hoglet_core;

    #[event]
    struct PoolRegistrationFeePaidEvent has drop, store {
        caller_address: address,
        pool_key: PoolIdentifier,
        fee_amount: u64,
        fee_treasury_address: address,
    }

    struct ModuleSignerStorage has key {
        resource_address: address,
        signer_cap: account::SignerCapability,
    }

    struct PoolIdentifier has copy, drop, store {
        creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    }

    struct PoolsManager has key {
        pools: Table<PoolIdentifier, StakePoolData>
    }

    struct StakePoolData has store { 
        pool_creator: address,        
        is_hodl_pool: bool,
        stake_metadata: Object<Metadata>,
        reward_metadata: Object<Metadata>,
        reward_per_sec: u256,
        accum_reward: u256,
        last_updated: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        unstake_period_seconds: u64,
        stakes: table::Table<address, UserStake>,
        stake_store: Object<FungibleStore>,
        reward_store: Object<FungibleStore>,
        total_boosted: u128,
        nft_boost_config: Option<NFTBoostConfig>,
        emergency_locked: bool,
        stakes_closed: bool,
        
        // HODL Pool specifics (Stake-Seconds)
        accum_stake_seconds: u128,
        last_stake_seconds_updated: u64,
        final_reward_amount: u64,
    }

    struct NFTBoostConfig has store {
        boost_percent: u128,
        collection_owner: address,
        collection_name: String,
    }

    struct UserStake has store {
        amount: u64,
        reward_points_debt: u256,
        earned_reward: u64,
        nft: Option<Token>,
        boosted_amount: u128,
        unlocked_balance: u64,
        locked_amount: u64,
        locked_start_time: u64,
        
        // HODL Pool specifics
        acc_stake_seconds: u128,
        last_stake_seconds_updated: u64,
    }
       
    #[event]
    struct StakeEvent has drop, store {
        user_address: address,
        pool_key: PoolIdentifier,
        amount: u64,
    }
    #[event]
    struct UnstakeEvent has drop, store {
        user_address: address,
        pool_key: PoolIdentifier,
        unstaked_amount: u64,
        remaining_stake_amount: u64,
    }

    #[event]
    struct BoostEvent has drop, store {
        user_address: address,
        pool_key: PoolIdentifier,
        token_id: token::TokenId,
    }

    #[event]
    struct RemoveBoostEvent has drop, store {
        user_address: address,
        pool_key: PoolIdentifier,
        token_id: token::TokenId,
    }

    #[event]
    struct DepositRewardEvent has drop, store {
        depositor_address: address,
        pool_key: PoolIdentifier,
        amount: u64,
        new_end_timestamp: u64,
    }

    #[event]
    struct HarvestEvent has drop, store {
        user_address: address,
        pool_key: PoolIdentifier,
        amount: u64,
    }
    
    #[event]
    struct PoolRegisteredEvent has copy, drop, store {
        pool_key: PoolIdentifier,
        is_hodl: bool,
        start_timestamp: u64,
        initial_end_timestamp: u64,
        initial_reward_per_sec: u256,
        boost_enabled: bool,
        boost_config_collection_owner: Option<address>,
        boost_config_collection_name: Option<String>,
        boost_config_percent: Option<u128>,
    }

    #[event]
    struct HodlPoolFinalizedEvent has drop, store {
        pool_key: PoolIdentifier,
        finalized_by: address,
        end_timestamp: u64,
        total_reward_amount: u64,
        calculated_duration: u64,
        reward_per_sec: u256,
    }

    #[event]
    struct EmergencyEnabledEvent has drop, store {
        pool_key: PoolIdentifier,
        triggered_by: address,
    }

    #[event]
    struct EmergencyDisabledEvent has drop, store {
        pool_key: PoolIdentifier,
        triggered_by: address,
    }

    #[event]
    struct EmergencyUnstakeEvent has drop, store {
        pool_key: PoolIdentifier,
        user_address: address,
        unstaked_amount: u64,
        nft_withdrawn: bool,
    }

    #[event]
    struct TreasuryWithdrawalEvent has drop, store {
        pool_key: PoolIdentifier,
        treasury_address: address,
        amount: u64,
    }

    struct UserPoolsTracker has key {
        user_to_pools: Table<address, vector<PoolIdentifier>>
    }

    public fun create_boost_config(
        collection_owner: address,
        collection_name: String,
        boost_percent: u128
    ): NFTBoostConfig {
        assert!(token::check_collection_exists(collection_owner, collection_name), error::not_found(ERR_NO_COLLECTION));
        assert!(boost_percent >= MIN_NFT_BOOST_PRECENT && boost_percent <= MAX_NFT_BOOST_PERCENT,  error::invalid_argument(ERR_INVALID_BOOST_PERCENT));

        NFTBoostConfig {
            boost_percent,
            collection_owner,
            collection_name,
        }
    }

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        assert!(deployer_addr == MODULE_ADMIN_ACCOUNT, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(!exists<ModuleSignerStorage>(deployer_addr), error::already_exists(ERR_REGISTRY_ALREADY_EXISTS_FOR_INITIALIZE));
        
        let (resource_signer, signer_cap) = account::create_resource_account(deployer, MODULE_RESOURCE_ACCOUNT_SEED);
        let resource_addr = signer::address_of(&resource_signer);

        move_to(deployer, ModuleSignerStorage {
            resource_address: resource_addr,
            signer_cap: signer_cap,
        });

        move_to(&resource_signer, PoolsManager { 
            pools: table::new() 
        });

        move_to(&resource_signer, UserPoolsTracker {
            user_to_pools: table::new()
        });
    }

    public fun register_pool(
        caller: &signer,
        stake_addr: address,
        reward_addr: address,     
        initial_reward_amount: u64,         
        duration: u64,                      
        nft_boost_config: Option<NFTBoostConfig>
    ) acquires PoolsManager, ModuleSignerStorage {
        let caller_addr = signer::address_of(caller);
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);

        let (fee_amount, fee_treasury) = hodl_fa_config::get_pool_registration_fee_config();
        let linked_contract_address = hodl_fa_config::get_linked_contract_address();

        let is_whitelisted = false;
        if (option::is_some(&linked_contract_address)) {
            if (caller_addr == *option::borrow(&linked_contract_address)) {
                is_whitelisted = true;
            }
        };

        if (fee_amount > 0 && !is_whitelisted) {
            assert!(coin::balance<SupraCoin>(caller_addr) >= fee_amount, error::permission_denied(ERR_INSUFFICIENT_SUPRA_FOR_FEE));
            coin::transfer<SupraCoin>(caller, fee_treasury, fee_amount);
            event::emit(PoolRegistrationFeePaidEvent {
                    caller_address: caller_addr,
                    pool_key: PoolIdentifier {
                        creator_addr: caller_addr,
                        stake_addr,
                        reward_addr
                    },
                    fee_amount,
                    fee_treasury_address: fee_treasury,
                }
            );
        };

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        let pool_key = PoolIdentifier { 
            creator_addr: caller_addr,
            stake_addr, 
            reward_addr 
        };

        assert!(!table::contains(&pools_manager.pools, pool_key), error::already_exists(ERR_POOL_ID_ALREADY_EXISTS));

        assert!(duration > 0, error::invalid_argument(ERR_DURATION_CANNOT_BE_ZERO));
        assert!(initial_reward_amount > 0, error::invalid_argument(ERR_INITIAL_REWARD_AMOUNT_ZERO));
        let boost_enabled = option::is_some(&nft_boost_config);

        let stake_metadata: Object<Metadata> = object::address_to_object<Metadata>(stake_addr);
        let reward_metadata: Object<Metadata> = object::address_to_object<Metadata>(reward_addr);

        let reward_per_sec = ((initial_reward_amount as u256) * (ACCUM_REWARD_SCALE as u256)) / (duration as u256);
        assert!(reward_per_sec > 0, error::invalid_argument(ERR_REWARD_RATE_ZERO));

        let caller_primary_reward_store = primary_fungible_store::primary_store(caller_addr, reward_metadata);
        let initial_reward_asset = fungible_asset::withdraw(
            caller,
            caller_primary_reward_store,
            initial_reward_amount
        );

        let current_time = timestamp::now_seconds();
        let end_timestamp = current_time + duration;
        assert!(end_timestamp > current_time && end_timestamp != MAX_U64, error::out_of_range(ERR_DURATION_OVERFLOW));

        let stake_store_obj_ref = object::create_object_from_account(&resource_signer);
        let pool_stake_store = fungible_asset::create_store(&stake_store_obj_ref, stake_metadata);

        let reward_store_obj_ref = object::create_object_from_account(&resource_signer);
        let pool_reward_store = fungible_asset::create_store(&reward_store_obj_ref, reward_metadata);

        fungible_asset::deposit(pool_reward_store, initial_reward_asset);

        let event_boost_owner_opt: Option<address> = option::none();
        let event_boost_name_opt: Option<String> = option::none();
        let event_boost_percent_opt: Option<u128> = option::none();

        if (boost_enabled) {
            let config_ref = option::borrow(&nft_boost_config); 
            event_boost_owner_opt = option::some(config_ref.collection_owner);
            event_boost_name_opt = option::some(config_ref.collection_name);
            event_boost_percent_opt = option::some(config_ref.boost_percent);
        };


        let new_pool_data = StakePoolData {
            pool_creator: caller_addr,
            is_hodl_pool: false,
            stake_metadata,
            reward_metadata,
            reward_per_sec, 
            accum_reward: 0u256,
            last_updated: current_time,
            start_timestamp: current_time,
            end_timestamp,
            unstake_period_seconds: 0,
            stakes: table::new(),
            stake_store: pool_stake_store,
            reward_store: pool_reward_store,
            total_boosted: 0,
            nft_boost_config,
            emergency_locked: false,
            stakes_closed: false,
            accum_stake_seconds: 0,
            last_stake_seconds_updated: current_time,
            final_reward_amount: 0,
        };

        event::emit(PoolRegisteredEvent {
                pool_key,
                is_hodl: false,
                start_timestamp: current_time,
                initial_end_timestamp: end_timestamp,
                initial_reward_per_sec: reward_per_sec,
                boost_enabled,
                boost_config_collection_owner: event_boost_owner_opt,
                boost_config_collection_name: event_boost_name_opt,
                boost_config_percent: event_boost_percent_opt,
            },
        );

        table::add(&mut pools_manager.pools, pool_key, new_pool_data);
    }

    public fun register_hodl_pool(
        caller: &signer,
        stake_addr: address,
        reward_addr: address,
        unstake_period_seconds: u64,
        nft_boost_config: Option<NFTBoostConfig>,
    ) acquires PoolsManager, ModuleSignerStorage {
        let caller_addr = signer::address_of(caller);
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let (fee_amount, fee_treasury) = hodl_fa_config::get_pool_registration_fee_config();
        let linked_contract_address = hodl_fa_config::get_linked_contract_address();
        let is_whitelisted = false;
        if (option::is_some(&linked_contract_address)) {
            if (caller_addr == *option::borrow(&linked_contract_address)) {
                is_whitelisted = true;
            }
        };

        if (fee_amount > 0 && !is_whitelisted) {

            assert!(coin::balance<SupraCoin>(caller_addr) >= fee_amount, error::permission_denied(ERR_INSUFFICIENT_SUPRA_FOR_FEE));
            coin::transfer<SupraCoin>(caller, fee_treasury, fee_amount);

            event::emit(PoolRegistrationFeePaidEvent {
                    caller_address: caller_addr,
                    pool_key: PoolIdentifier {
                        creator_addr: caller_addr,
                        stake_addr,
                        reward_addr
                    },
                    fee_amount,
                    fee_treasury_address: fee_treasury,
                }
            );
        };

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        
        let pool_key = PoolIdentifier {
            creator_addr: caller_addr,
            stake_addr,
            reward_addr
        };
        assert!(!table::contains(&pools_manager.pools, pool_key), error::already_exists(ERR_POOL_ID_ALREADY_EXISTS));

        let stake_metadata = object::address_to_object(stake_addr);
        let reward_metadata = object::address_to_object(reward_addr);
    
        let current_time = timestamp::now_seconds();
        let boost_enabled = option::is_some(&nft_boost_config);

        let stake_store_obj = object::create_object_from_account(&resource_signer);
        let pool_stake_store = fungible_asset::create_store(&stake_store_obj, stake_metadata);

        let reward_store_obj = object::create_object_from_account(&resource_signer);
        let pool_reward_store = fungible_asset::create_store(&reward_store_obj, reward_metadata);

        let event_boost_owner_opt: Option<address> = option::none();
        let event_boost_name_opt: Option<String> = option::none();
        let event_boost_percent_opt: Option<u128> = option::none();

        if (boost_enabled) {
            let config_ref = option::borrow(&nft_boost_config);
            event_boost_owner_opt = option::some(config_ref.collection_owner);
            event_boost_name_opt = option::some(config_ref.collection_name);
            event_boost_percent_opt = option::some(config_ref.boost_percent);
        };


        let new_pool_data = StakePoolData {
            pool_creator: caller_addr,
            is_hodl_pool: true,
            stake_metadata,
            reward_metadata,
            reward_per_sec: 0, 
            accum_reward: 0,
            last_updated: current_time,
            start_timestamp: current_time,
            end_timestamp: MAX_U64,
            unstake_period_seconds,
            stakes: table::new(),
            stake_store: pool_stake_store,
            reward_store: pool_reward_store,
            total_boosted: 0,
            nft_boost_config,
            emergency_locked: false,
            stakes_closed: false,
            accum_stake_seconds: 0,
            last_stake_seconds_updated: current_time,
            final_reward_amount: 0,
        };

        event::emit(PoolRegisteredEvent {
                pool_key,
                is_hodl: true,
                start_timestamp: current_time,
                initial_end_timestamp: MAX_U64,
                initial_reward_per_sec: 0,
                boost_enabled,
                boost_config_collection_owner: event_boost_owner_opt,
                boost_config_collection_name: event_boost_name_opt,
                boost_config_percent: event_boost_percent_opt,
            },
        );
        
        table::add(&mut pools_manager.pools, pool_key, new_pool_data);
    }
    
    public fun stake(
        user: &signer,
        pool_key: PoolIdentifier,
        stake_amount: u64
    ) acquires PoolsManager, ModuleSignerStorage, UserPoolsTracker {
        let user_addr = signer::address_of(user);
        let resource_addr = get_module_resource_address();
        
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        let user_primary_stake_store = primary_fungible_store::primary_store(user_addr, pool.stake_metadata);
        let assets_to_deposit = fungible_asset::withdraw(user, user_primary_stake_store, stake_amount);
        
        stake_internal(pool, &pool_key, resource_addr, user_addr, stake_amount, false);
        
        fungible_asset::deposit(pool.stake_store, assets_to_deposit);
    }

    public fun unstake(
        user: &signer,
        pool_key: PoolIdentifier,
        amount: u64
    ): FungibleAsset acquires PoolsManager, ModuleSignerStorage {
        assert!(amount > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO));
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let user_addr = signer::address_of(user);

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        
        let user_stake_ref = table::borrow(&pool.stakes, user_addr);
        assert!(amount <= user_stake_ref.amount, error::out_of_range(ERR_NOT_ENOUGH_S_BALANCE));
        
        let max_unlocked_amount = calculate_max_unlocked_amount(pool, user_stake_ref);
        assert!(amount <= max_unlocked_amount, error::invalid_state(ERR_WITHDRAW_AMOUNT_EXCEEDS_UNLOCKED));
        
        update_accum_reward(pool);
        update_stake_seconds(pool, user_addr);

        let pool_unstake_period = pool.unstake_period_seconds;
        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
        
        update_user_reward_state(pool.accum_reward, user_stake);
        
        update_unlocked_balance(pool_unstake_period, user_stake);
        user_stake.unlocked_balance = user_stake.unlocked_balance - amount;

        let old_boosted_amount = user_stake.boosted_amount;
        user_stake.amount = user_stake.amount - amount;

        if (option::is_some(&user_stake.nft)) {
            let boost_config_val = option::borrow(&pool.nft_boost_config);
            let boost_percent = boost_config_val.boost_percent;

            pool.total_boosted = pool.total_boosted - old_boosted_amount;
            if (user_stake.amount > 0) {
                user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
                pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
            } else {
                user_stake.boosted_amount = 0;
            }
        } else {
            user_stake.boosted_amount = 0;
        };

        let user_new_total_effective_stake = user_stake_amount_with_boosted(user_stake);
        user_stake.reward_points_debt = pool.accum_reward * (user_new_total_effective_stake as u256);

        let withdrawn_assets_from_pool = fungible_asset::withdraw(&resource_signer, pool.stake_store, amount);
        event::emit(UnstakeEvent {
            user_address: user_addr,
            pool_key,
            unstaked_amount: amount,
            remaining_stake_amount: user_stake.amount,
        });
        withdrawn_assets_from_pool
    }

    public fun deposit_and_stake_for_beneficiary( 
        caller_signer: &signer,
        pool_key: PoolIdentifier,
        beneficiary_addr: address,
        stake_asset: FungibleAsset,
    ) acquires PoolsManager, ModuleSignerStorage, UserPoolsTracker {
        let caller_addr = signer::address_of(caller_signer);
        let resource_addr = get_module_resource_address();

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        let pool_ref = table::borrow(&pools_manager.pools, pool_key);

        assert!(caller_addr == pool_ref.pool_creator, error::permission_denied(ERR_NOT_AUTHORIZED));

        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        
        let stake_amount = fungible_asset::amount(&stake_asset);

        stake_internal(pool, &pool_key, resource_addr, beneficiary_addr, stake_amount, true);
        
        fungible_asset::deposit(pool.stake_store, stake_asset);
    }

    public fun harvest(
        user: &signer,
        pool_key: PoolIdentifier
    ): (u64, FungibleAsset) acquires PoolsManager, ModuleSignerStorage, UserPoolsTracker {
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let user_addr = signer::address_of(user);

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));
        assert!(
            (!pool.is_hodl_pool) || (pool.is_hodl_pool && pool.stakes_closed),
            error::invalid_state(ERR_HODL_POOL_NOT_FINALIZED_FOR_HARVEST)
        );

        let amount_to_harvest: u64 = 0;
        
        if (pool.is_hodl_pool) {
            update_stake_seconds(pool, user_addr);
            let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
            
            if (pool.accum_stake_seconds > 0) {
                let user_share = math128::mul_div(
                    (pool.final_reward_amount as u128),
                    user_stake.acc_stake_seconds,
                    pool.accum_stake_seconds
                );
                user_stake.earned_reward = user_stake.earned_reward + (user_share as u64);
                user_stake.acc_stake_seconds = 0; // Prevent double harvest
            };
            amount_to_harvest = user_stake.earned_reward;
        } else {
            update_accum_reward(pool); 
            let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
            update_user_reward_state(pool.accum_reward, user_stake);
            amount_to_harvest = user_stake.earned_reward;
        };

        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
        assert!(amount_to_harvest > 0, error::invalid_state(ERR_NOTHING_TO_HARVEST));

        user_stake.earned_reward = 0;

        let should_cleanup = (user_stake.amount == 0);

        let withdrawn_rewards_from_pool = fungible_asset::withdraw(&resource_signer, pool.reward_store, amount_to_harvest);
        event::emit(HarvestEvent { 
            user_address: user_addr, 
            pool_key, 
            amount: amount_to_harvest 
        });

        if (should_cleanup) {
            let UserStake { amount: _, reward_points_debt: _, earned_reward: _, nft, boosted_amount: _, unlocked_balance: _, locked_amount: _, locked_start_time: _, acc_stake_seconds: _, last_stake_seconds_updated: _ } = table::remove(&mut pool.stakes, user_addr);
            option::destroy_none(nft);
            remove_pool_from_tracker(resource_addr, user_addr, &pool_key);
        };

        (amount_to_harvest, withdrawn_rewards_from_pool)
    }

    public fun boost(
        user: &signer, 
        pool_key: PoolIdentifier,
        nft: Token
    ) acquires PoolsManager, ModuleSignerStorage {
        let resource_addr = get_module_resource_address();
        let user_addr = signer::address_of(user);
        
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));

        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        assert!(option::is_some(&pool.nft_boost_config), error::invalid_state(ERR_NON_BOOST_POOL));
        assert!(!pool.stakes_closed, error::invalid_state(ERR_STAKES_ALREADY_CLOSED));

        let boost_config_ref = option::borrow(&pool.nft_boost_config);
        let pool_collection_owner = boost_config_ref.collection_owner;
        let pool_collection_name: String = boost_config_ref.collection_name;
        
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));
        update_stake_seconds(pool, user_addr);

        assert!(token::get_token_amount(&nft) == 1, error::invalid_argument(ERR_NFT_AMOUNT_MORE_THAN_ONE));

        let token_id = token::get_token_id(&nft);
        let (nft_collection_owner, nft_collection_name_ref, _, _) = token::get_token_id_fields(&token_id);
        assert!(nft_collection_owner == pool_collection_owner, error::invalid_argument(ERR_WRONG_TOKEN_COLLECTION));
        assert!(nft_collection_name_ref == pool_collection_name, error::invalid_argument(ERR_WRONG_TOKEN_COLLECTION));
        
        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
        update_user_reward_state(pool.accum_reward, user_stake);
        assert!(option::is_none(&user_stake.nft), error::invalid_state(ERR_ALREADY_BOOSTED));

        option::fill(&mut user_stake.nft, nft);
        let boost_config_val = option::borrow(&pool.nft_boost_config);
        let boost_percent = boost_config_val.boost_percent;
        user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
        pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;

        let user_new_total_effective_stake = user_stake_amount_with_boosted(user_stake);
        user_stake.reward_points_debt = pool.accum_reward * (user_new_total_effective_stake as u256);
        event::emit(BoostEvent {
            user_address: user_addr,
            pool_key,
            token_id 
        });
    }

    public fun remove_boost(
        user: &signer, 
        pool_key: PoolIdentifier
    ): Token acquires PoolsManager, ModuleSignerStorage {
        let resource_addr = get_module_resource_address();
        let user_addr = signer::address_of(user);

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));
        update_stake_seconds(pool, user_addr);

        update_accum_reward(pool);

        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
        assert!(option::is_some(&user_stake.nft), error::invalid_state(ERR_NO_BOOST));

        update_user_reward_state(pool.accum_reward, user_stake);

        pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
        user_stake.boosted_amount = 0;
        let extracted_nft = option::extract(&mut user_stake.nft);
        let token_id = token::get_token_id(&extracted_nft);

        let user_new_total_effective_stake = user_stake_amount_with_boosted(user_stake); 
        user_stake.reward_points_debt = pool.accum_reward * (user_new_total_effective_stake as u256);

        event::emit(RemoveBoostEvent {
            user_address: user_addr,
            pool_key,
            token_id
        });
        extracted_nft
    }

    public fun remove_boost_many(
        user: &signer,
        pool_keys: vector<PoolIdentifier>
    ) acquires PoolsManager, ModuleSignerStorage {
        let num_pools = vector::length(&pool_keys);
        assert!(num_pools > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO));

        let user_addr = signer::address_of(user);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);

        let i = 0;
        while (i < num_pools) {
            let pool_key = *vector::borrow(&pool_keys, i);

            if (table::contains(&pools_manager.pools, pool_key)) {
                let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);

                if (table::contains(&pool.stakes, user_addr)) {
                    let user_stake_ref = table::borrow(&pool.stakes, user_addr);

                    if (option::is_some(&user_stake_ref.nft)) {
                        // SECURITY FIX (L-07): Skip instead of reverting to prevent batch DoS
                        if (is_emergency_inner(pool)) {
                            i = i + 1;
                            continue
                        };

                        update_accum_reward(pool);

                        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
                        update_user_reward_state(pool.accum_reward, user_stake);

                        pool.total_boosted = pool.total_boosted - user_stake.boosted_amount;
                        user_stake.boosted_amount = 0;
                        let extracted_nft = option::extract(&mut user_stake.nft);
                        let token_id = token::get_token_id(&extracted_nft);

                        let user_new_total_effective_stake = user_stake_amount_with_boosted(user_stake);
                        user_stake.reward_points_debt = pool.accum_reward * (user_new_total_effective_stake as u256);

                        event::emit(RemoveBoostEvent { user_address: user_addr, pool_key, token_id });

                        token::deposit_token(user, extracted_nft);
                    }
                }
            };
            i = i + 1;
        }
    }

    public fun finalize_hodl_pool_rewards(
        caller_signer: &signer,
        pool_key: PoolIdentifier,
        total_reward_amount: u64
    ) acquires PoolsManager, ModuleSignerStorage {
        let caller_addr = signer::address_of(caller_signer);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));

        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(caller_addr == pool.pool_creator, error::permission_denied(ERR_NOT_AUTHORIZED));
        assert!(!pool.stakes_closed, error::invalid_state(ERR_STAKES_ALREADY_CLOSED));
        assert!(total_reward_amount > 0, error::invalid_argument(ERR_REWARD_CANNOT_BE_ZERO));

        update_accum_reward(pool);
        // We don't update accum_reward since HODL pool now uses stake-seconds
        // update_accum_reward(pool);

        let finalization_time = timestamp::now_seconds();
        assert!(finalization_time >= pool.start_timestamp, error::invalid_argument(ERR_DURATION_CANNOT_BE_ZERO));
        
        pool.end_timestamp = finalization_time;
        pool.stakes_closed = true;
        pool.final_reward_amount = total_reward_amount;
        
        let pool_delta_t = if (finalization_time > pool.last_stake_seconds_updated) {
            finalization_time - pool.last_stake_seconds_updated
        } else { 0 };
        if (pool_delta_t > 0) {
            let pool_total_effective = pool_total_staked_with_boosted(pool);
            pool.accum_stake_seconds = pool.accum_stake_seconds + (pool_total_effective * (pool_delta_t as u128));
            pool.last_stake_seconds_updated = finalization_time;
        };

        let duration = if (finalization_time > pool.start_timestamp) {
            finalization_time - pool.start_timestamp
        } else {
            0
        };

        let caller_primary_reward_store = primary_fungible_store::primary_store(caller_addr, pool.reward_metadata);
        let reward_assets_to_deposit = fungible_asset::withdraw(
            caller_signer,
            caller_primary_reward_store,
            total_reward_amount
        );
        fungible_asset::deposit(pool.reward_store, reward_assets_to_deposit);

        event::emit(HodlPoolFinalizedEvent {
            pool_key,
            finalized_by: caller_addr,
            end_timestamp: pool.end_timestamp,
            total_reward_amount,
            calculated_duration: duration,
            reward_per_sec: 0,
        });
    }

    public fun enable_emergency(
        admin: &signer, 
        pool_key: PoolIdentifier
    ) acquires PoolsManager, ModuleSignerStorage {
        assert!(signer::address_of(admin) == hodl_fa_config::get_emergency_admin_address(), error::permission_denied(ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY));
        let admin_addr = signer::address_of(admin);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        pool.emergency_locked = true;

        event::emit(EmergencyEnabledEvent {
            pool_key,
            triggered_by: admin_addr,
        });
    }

    public fun disable_emergency(
        admin: &signer, 
        pool_key: PoolIdentifier
    ) acquires PoolsManager, ModuleSignerStorage {
        assert!(signer::address_of(admin) == hodl_fa_config::get_emergency_admin_address(), error::permission_denied(ERR_NOT_ENOUGH_PERMISSIONS_FOR_EMERGENCY));
        let admin_addr = signer::address_of(admin);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        assert!(pool.emergency_locked, error::invalid_state(ERR_NO_EMERGENCY));
        pool.emergency_locked = false;

        event::emit(EmergencyDisabledEvent {
            pool_key,
            triggered_by: admin_addr,
        });
    }

    public fun unstake_many(
        user: &signer,
        pool_keys: vector<PoolIdentifier>
    ) acquires PoolsManager, ModuleSignerStorage {
        let num_pools = vector::length(&pool_keys);
        assert!(num_pools > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO)); 

        let user_addr = signer::address_of(user);
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);

        let i = 0;
        while (i < num_pools) {
            let pool_key = *vector::borrow(&pool_keys, i);
            if (!table::contains(&pools_manager.pools, pool_key)) {
                i = i + 1;
                continue
            };
            let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);

            if (table::contains(&pool.stakes, user_addr)) {
                // SECURITY FIX (L-07): Skip instead of reverting to prevent batch DoS
                if (is_emergency_inner(pool)) {
                    i = i + 1;
                    continue
                };
                
                let user_stake_ref = table::borrow(&pool.stakes, user_addr);

                let amount_to_unstake = calculate_max_unlocked_amount(pool, user_stake_ref);

                if (amount_to_unstake > 0) {
                    update_accum_reward(pool);
                    
                    let pool_unstake_period = pool.unstake_period_seconds;
                    let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
                    
                    update_user_reward_state(pool.accum_reward, user_stake);
                    update_unlocked_balance(pool_unstake_period, user_stake);
                    user_stake.unlocked_balance = 0;

                    let old_boosted_amount = user_stake.boosted_amount;
                    user_stake.amount = user_stake.amount - amount_to_unstake;

                    if (option::is_some(&user_stake.nft)) {
                        let boost_config_val = option::borrow(&pool.nft_boost_config);
                        let boost_percent = boost_config_val.boost_percent;

                        pool.total_boosted = pool.total_boosted - old_boosted_amount;
                        if (user_stake.amount > 0) {
                            user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100;
                            pool.total_boosted = pool.total_boosted + user_stake.boosted_amount;
                        } else {
                            user_stake.boosted_amount = 0;
                        }
                    };
                    
                    let user_new_total_effective_stake = user_stake_amount_with_boosted(user_stake);
                    user_stake.reward_points_debt = pool.accum_reward * (user_new_total_effective_stake as u256);

                    let withdrawn_assets_from_pool = fungible_asset::withdraw(&resource_signer, pool.stake_store, amount_to_unstake);
                    
                    let user_primary_stake_store = primary_fungible_store::primary_store(user_addr, pool.stake_metadata);
                    fungible_asset::deposit(user_primary_stake_store, withdrawn_assets_from_pool);
                    
                    event::emit(UnstakeEvent {
                        user_address: user_addr,
                        pool_key,
                        unstaked_amount: amount_to_unstake,
                        remaining_stake_amount: user_stake.amount,
                    });
                };
            };
            i = i + 1;
        };
    }

    public fun harvest_many(
        user: &signer,
        pool_keys: vector<PoolIdentifier>
    ) acquires PoolsManager, ModuleSignerStorage, UserPoolsTracker {
        let num_pools = vector::length(&pool_keys);
        assert!(num_pools > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO));

        let user_addr = signer::address_of(user);
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);

        let i = 0;
        while (i < num_pools) {
            let pool_key = *vector::borrow(&pool_keys, i);
            
            if (table::contains(&pools_manager.pools, pool_key)) {
                let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);

                if (table::contains(&pool.stakes, user_addr)) {

                    // SECURITY FIX (L-07): Skip instead of reverting to prevent batch DoS
                    if (is_emergency_inner(pool)) {
                        i = i + 1;
                        continue
                    };
                    assert!(
                        (!pool.is_hodl_pool) || (pool.is_hodl_pool && pool.stakes_closed),
                        error::invalid_state(ERR_HODL_POOL_NOT_FINALIZED_FOR_HARVEST)
                    );
                    let amount_to_harvest: u64 = 0;
                    
                    if (pool.is_hodl_pool) {
                        update_stake_seconds(pool, user_addr);
                        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
                        if (pool.accum_stake_seconds > 0) {
                            let user_share = math128::mul_div(
                                (pool.final_reward_amount as u128),
                                user_stake.acc_stake_seconds,
                                pool.accum_stake_seconds
                            );
                            user_stake.earned_reward = user_stake.earned_reward + (user_share as u64);
                            user_stake.acc_stake_seconds = 0;
                        };
                        amount_to_harvest = user_stake.earned_reward;
                    } else {
                        update_accum_reward(pool); 
                        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
                        update_user_reward_state(pool.accum_reward, user_stake);
                        amount_to_harvest = user_stake.earned_reward;
                    };
                    
                    if (amount_to_harvest > 0) {
                        let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
                        user_stake.earned_reward = 0;
                        
                        let withdrawn_rewards = fungible_asset::withdraw(&resource_signer, pool.reward_store, amount_to_harvest);
                        
                        let user_primary_reward_store = primary_fungible_store::primary_store(user_addr, pool.reward_metadata);
                        
                        fungible_asset::deposit(user_primary_reward_store, withdrawn_rewards);

                        // Check if cleanup is needed after harvest.
                        let should_cleanup = (user_stake.amount == 0);

                        event::emit(HarvestEvent { 
                            user_address: user_addr, 
                            pool_key, 
                            amount: amount_to_harvest 
                        });

                        if (should_cleanup) {
                            let UserStake { amount: _, reward_points_debt: _, earned_reward: _, nft, boosted_amount: _, unlocked_balance: _, locked_amount: _, locked_start_time: _, acc_stake_seconds: _, last_stake_seconds_updated: _ } = table::remove(&mut pool.stakes, user_addr);
                            option::destroy_none(nft);
                            remove_pool_from_tracker(resource_addr, user_addr, &pool_key);
                        };
                    };
                }
            };
            i = i + 1;
        };
    }

    public fun emergency_unstake(
        user: &signer, 
        pool_key: PoolIdentifier
    ): (u64, Option<FungibleAsset>, Option<Token>) acquires PoolsManager, ModuleSignerStorage, UserPoolsTracker {
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let user_addr = signer::address_of(user);
        
        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);
        
        assert!(is_emergency_inner(pool), error::invalid_state(ERR_NO_EMERGENCY));
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));

        let tracker = borrow_global_mut<UserPoolsTracker>(resource_addr);
        if (table::contains(&tracker.user_to_pools, user_addr)) {
            let user_pools_vector = table::borrow_mut(&mut tracker.user_to_pools, user_addr);
            
            let (found, index) = vector::index_of(user_pools_vector, &pool_key);
            if (found) {
                vector::remove(user_pools_vector, index);
            };

            if (vector::is_empty(user_pools_vector)) {
                table::remove(&mut tracker.user_to_pools, user_addr);
            }
        };

        if (pool.is_hodl_pool) {
            update_stake_seconds(pool, user_addr);
        };
        let user_stake = table::remove(&mut pool.stakes, user_addr);

        let UserStake { 
            amount, 
            reward_points_debt: _, 
            earned_reward, 
            nft, 
            boosted_amount,
            unlocked_balance: _,
            locked_amount: _,
            locked_start_time: _,
            acc_stake_seconds,
            last_stake_seconds_updated: _
        } = user_stake;

        let nft_was_present = option::is_some(&nft);

        let mut_earned_reward = earned_reward;
        if (pool.is_hodl_pool && pool.accum_stake_seconds > 0) {
            let user_share = math128::mul_div(
                (pool.final_reward_amount as u128),
                acc_stake_seconds,
                pool.accum_stake_seconds
            );
            mut_earned_reward = mut_earned_reward + (user_share as u64);
        };

        // Attempt to payout earned_reward
        if (mut_earned_reward > 0) {
            let available_rewards = fungible_asset::balance(pool.reward_store);
            let payout = if (available_rewards >= mut_earned_reward) { mut_earned_reward } else { available_rewards };
            if (payout > 0) {
                let withdrawn_rewards = fungible_asset::withdraw(&resource_signer, pool.reward_store, payout);
                let user_primary_reward_store = primary_fungible_store::primary_store(user_addr, pool.reward_metadata);
                fungible_asset::deposit(user_primary_reward_store, withdrawn_rewards);
            };
        };

        if (boosted_amount > 0) {
            pool.total_boosted = if (pool.total_boosted >= boosted_amount) {
                pool.total_boosted - boosted_amount 
            } else { 
                0 
            };
        };

        let maybe_withdrawn_fa: Option<FungibleAsset> = if (amount > 0) {
            let withdrawn_stake_assets = fungible_asset::withdraw(
                &resource_signer,
                pool.stake_store,
                amount
            );
            option::some(withdrawn_stake_assets)
        } else {
            option::none()
        };

        event::emit(EmergencyUnstakeEvent {
            pool_key,
            user_address: user_addr,
            unstaked_amount: amount,
            nft_withdrawn: nft_was_present,
        });

        (amount, maybe_withdrawn_fa, nft)
    }


    public fun withdraw_to_treasury(
        treasury_signer: &signer,
        pool_key: PoolIdentifier,
        amount: u64
    ): FungibleAsset acquires PoolsManager, ModuleSignerStorage {
        assert!(amount > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO));
        let treasury_addr = signer::address_of(treasury_signer);
        assert!(treasury_addr == hodl_fa_config::get_treasury_admin_address(), error::permission_denied(ERR_NOT_TREASURY));
        
        let resource_signer = get_module_resource_signer();
        let resource_addr = signer::address_of(&resource_signer);
        let grace_period = hodl_fa_config::get_treasury_withdraw_grace_period();

        let pools_manager = borrow_global_mut<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow_mut(&mut pools_manager.pools, pool_key);

        if (!is_emergency_inner(pool)) {
            assert!(is_finished_inner(pool), error::invalid_state(ERR_NOT_WITHDRAW_PERIOD));
            let withdraw_allowed_after = pool.end_timestamp + grace_period;
            assert!(withdraw_allowed_after > pool.end_timestamp, error::out_of_range(ERR_DURATION_OVERFLOW));
            assert!(timestamp::now_seconds() >= withdraw_allowed_after, error::invalid_state(ERR_NOT_WITHDRAW_PERIOD));
        };

        let withdrawn_reward_assets = fungible_asset::withdraw(
            &resource_signer,
            pool.reward_store,
            amount
        );

        event::emit(TreasuryWithdrawalEvent {
            pool_key,
            treasury_address: treasury_addr,
            amount,
        });

        withdrawn_reward_assets
    }

    #[view]
    public fun get_start_timestamp(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        pool.start_timestamp
    }

    #[view]
    public fun is_boostable(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        ); 
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        
        let pool = table::borrow(&pools_manager.pools, pool_key);
        option::is_some(&pool.nft_boost_config)
    }

    #[view]
    public fun get_boost_config(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): (address, String, u128) acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);

        assert!(option::is_some(&pool.nft_boost_config), ERR_NON_BOOST_POOL);
        let boost_config = option::borrow(&pool.nft_boost_config);
        (boost_config.collection_owner, boost_config.collection_name, boost_config.boost_percent)
    }

    #[view]
    public fun is_finished(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        is_finished_inner(pool)
    }

    #[view]
    public fun get_end_timestamp(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        pool.end_timestamp
    }

    #[view]
    public fun get_unlocked_stake_amount(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(pool_creator_addr, stake_addr, reward_addr);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        
        if (!table::contains(&pool.stakes, user_addr)) {
            return 0
        };

        let user_stake = table::borrow(&pool.stakes, user_addr);

        calculate_max_unlocked_amount(pool, user_stake)
    }

    #[view]
    public fun pool_exists(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        if (!exists<PoolsManager>(resource_addr)) {
            return false
        };
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        table::contains(&pools_manager.pools, pool_key)
    }

    #[view]
    public fun stake_exists(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        if (!exists<PoolsManager>(resource_addr)) {
            return false
        };
        if (!table::contains(&pools_manager.pools, pool_key)) {
            return false
        };
        let pool = table::borrow(&pools_manager.pools, pool_key);
        table::contains(&pool.stakes, user_addr)
    }

    #[view]
    public fun get_pool_total_stake(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        fungible_asset::balance(pool.stake_store)
    }

    #[view]
    public fun get_pool_total_boosted(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): u128 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        pool.total_boosted
    }

    #[view]
    public fun get_user_stake_or_zero(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        if (!exists<PoolsManager>(resource_addr)) {
            return 0
        };
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        if (!table::contains(&pools_manager.pools, pool_key)) {
            return 0
        };
        let pool = table::borrow(&pools_manager.pools, pool_key);
        if (!table::contains(&pool.stakes, user_addr)) {
            return 0
        };
        let user_stake = table::borrow(&pool.stakes, user_addr);
        user_stake.amount
    }

    #[view]
    public fun is_boosted(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));
        let user_stake = table::borrow(&pool.stakes, user_addr);
        option::is_some(&user_stake.nft)
    }
    
    #[view]
    public fun get_user_boosted(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): u128 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));
        let user_stake = table::borrow(&pool.stakes, user_addr);
        user_stake.boosted_amount
    }

    #[view]
    public fun get_pending_user_rewards(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ): u64 acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        assert!(table::contains(&pool.stakes, user_addr), error::not_found(ERR_NO_STAKE));

        let user_stake = table::borrow(&pool.stakes, user_addr);
        
        let current_pool_accum_reward = pool.accum_reward;
        let time_now_for_calc = get_time_for_last_update(pool);
        if (time_now_for_calc > pool.last_updated) {
            let delta_accum = accum_rewards_since_last_updated(pool, time_now_for_calc);
            if (delta_accum > 0) {
                current_pool_accum_reward = current_pool_accum_reward + delta_accum;
            };
        };
        let user_current_stake_raw_with_boost = user_stake_amount_with_boosted(user_stake);
        let pending_scaled_points = 0u256;

        if (user_current_stake_raw_with_boost > 0) {
            let total_entitlement_points = (current_pool_accum_reward as u256) * (user_current_stake_raw_with_boost as u256);

            if (total_entitlement_points >= user_stake.reward_points_debt) {
                pending_scaled_points = total_entitlement_points - user_stake.reward_points_debt;
            }
        };

        let already_earned_unscaled_u256 = (user_stake.earned_reward as u256);
        let newly_pending_unscaled_u256 = pending_scaled_points / (ACCUM_REWARD_SCALE as u256);
        let total_pending_unscaled_u256 = already_earned_unscaled_u256 + newly_pending_unscaled_u256;

        if (total_pending_unscaled_u256 >= (MAX_U64 as u256)) {
            MAX_U64
        } else {
            (total_pending_unscaled_u256 as u64)
        }
    }

    #[view]
    public fun is_emergency(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        is_emergency_inner(pool)
    }

    #[view]
    public fun is_local_emergency(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
    ): bool acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(
            pool_creator_addr,
            stake_addr,
            reward_addr
        );
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        assert!(table::contains(&pools_manager.pools, pool_key), error::not_found(ERR_NO_POOL));
        let pool = table::borrow(&pools_manager.pools, pool_key);
        pool.emergency_locked
    }

    #[view]
    public fun get_module_resource_address(): address acquires ModuleSignerStorage {
        borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT).resource_address
    }

    #[view]
    public fun new_pool_identifier(
        creator_addr: address,
        stake_addr: address,
        reward_addr: address
    ): PoolIdentifier {
        PoolIdentifier {
            creator_addr,
            stake_addr,
            reward_addr,
        }
    }

    #[view]
    public fun get_user_staked_pools(user_addr: address): vector<PoolIdentifier> acquires UserPoolsTracker, ModuleSignerStorage {
        let resource_addr = get_module_resource_address();
        if (!exists<UserPoolsTracker>(resource_addr)) {
            return vector::empty<PoolIdentifier>()
        };

        let tracker = borrow_global<UserPoolsTracker>(resource_addr);
        if (table::contains(&tracker.user_to_pools, user_addr)) {
            *table::borrow(&tracker.user_to_pools, user_addr)
        } else {
            vector::empty<PoolIdentifier>()
        }
    }

    #[view]
    public fun get_user_boosted_pools(user_addr: address): vector<PoolIdentifier> acquires UserPoolsTracker, PoolsManager, ModuleSignerStorage {
        let all_staked_pools = get_user_staked_pools(user_addr);
        let boosted_pools = vector::empty<PoolIdentifier>();

        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);

        let i = 0;
        let len = vector::length(&all_staked_pools);
        while (i < len) {
            let pool_key = *vector::borrow(&all_staked_pools, i);
            
            if (table::contains(&pools_manager.pools, pool_key)) {
                let pool = table::borrow(&pools_manager.pools, pool_key);
                if (table::contains(&pool.stakes, user_addr)) {
                    let user_stake = table::borrow(&pool.stakes, user_addr);
                    if (option::is_some(&user_stake.nft)) {
                        vector::push_back(&mut boosted_pools, pool_key);
                    }
                }
            };
            i = i + 1;
        };

        boosted_pools
    }

    #[view]
    public fun get_user_stake_details(
        pool_creator_addr: address,
        stake_addr: address,
        reward_addr: address,
        user_addr: address
    ) : (u64, u64, u64, u64, u128) acquires PoolsManager, ModuleSignerStorage {
        let pool_key = new_pool_identifier(pool_creator_addr, stake_addr, reward_addr);
        let resource_addr = get_module_resource_address();
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        
        if (!table::contains(&pools_manager.pools, pool_key) || !table::contains(&table::borrow(&pools_manager.pools, pool_key).stakes, user_addr)) {
            return (0, 0, 0, 0, 0)
        };

        let pool = table::borrow(&pools_manager.pools, pool_key);
        let user_stake = table::borrow(&pool.stakes, user_addr);

        (
            user_stake.amount,
            user_stake.unlocked_balance,
            user_stake.locked_amount,
            user_stake.locked_start_time,
            user_stake.boosted_amount
        )
    }

    fun stake_internal(
        pool: &mut StakePoolData,
        pool_key: &PoolIdentifier,
        resource_addr: address,
        beneficiary_addr: address,
        stake_amount: u64,
        _is_creator_action: bool
    ) acquires UserPoolsTracker {
        assert!(stake_amount > 0, error::invalid_argument(ERR_AMOUNT_CANNOT_BE_ZERO));
        assert!(!is_emergency_inner(pool), error::invalid_state(ERR_EMERGENCY));
        assert!(!pool.stakes_closed, error::invalid_state(ERR_STAKES_ALREADY_CLOSED));

        update_accum_reward(pool);
        let current_time = timestamp::now_seconds();
        
        update_stake_seconds(pool, beneficiary_addr);

        if (!table::contains(&pool.stakes, beneficiary_addr)) {
            let tracker = borrow_global_mut<UserPoolsTracker>(resource_addr);
            if (!table::contains(&tracker.user_to_pools, beneficiary_addr)) {
                table::add(&mut tracker.user_to_pools, beneficiary_addr, vector::singleton(*pool_key));
            } else {
                let user_pools_vector = table::borrow_mut(&mut tracker.user_to_pools, beneficiary_addr);
                if (!vector::contains(user_pools_vector, pool_key)) {
                    vector::push_back(user_pools_vector, *pool_key);
                }
            };
            let new_stake = UserStake {
                amount: stake_amount,
                reward_points_debt: pool.accum_reward * (stake_amount as u256),
                earned_reward: 0,
                nft: option::none(),
                boosted_amount: 0,
                unlocked_balance: 0,
                locked_amount: stake_amount,
                locked_start_time: current_time,
                acc_stake_seconds: 0,
                last_stake_seconds_updated: current_time,
            };
            table::add(&mut pool.stakes, beneficiary_addr, new_stake);
        } else {
            let pool_unstake_period = pool.unstake_period_seconds;
            let user_stake = table::borrow_mut(&mut pool.stakes, beneficiary_addr);
            
            update_user_reward_state(pool.accum_reward, user_stake);
            
            update_unlocked_balance(pool_unstake_period, user_stake);
            
            user_stake.amount = user_stake.amount + stake_amount;
            
            let new_locked = user_stake.locked_amount + stake_amount;
            if (new_locked > 0) {
                user_stake.locked_start_time = (math128::mul_div(
                    (user_stake.locked_amount as u128),
                    (user_stake.locked_start_time as u128),
                    (new_locked as u128)
                ) as u64) + (math128::mul_div(
                    (stake_amount as u128),
                    (current_time as u128),
                    (new_locked as u128)
                ) as u64);
            } else {
                user_stake.locked_start_time = current_time;
            };
            user_stake.locked_amount = new_locked;
            
            if (option::is_some(&user_stake.nft)) {
                let boost_config_val = option::borrow(&pool.nft_boost_config);
                let boost_percent = boost_config_val.boost_percent;
                pool.total_boosted = pool.total_boosted - user_stake.boosted_amount; 
                user_stake.boosted_amount = ((user_stake.amount as u128) * boost_percent) / 100; 
                pool.total_boosted = pool.total_boosted + user_stake.boosted_amount; 
            };
            
            user_stake.reward_points_debt = pool.accum_reward * (user_stake_amount_with_boosted(user_stake) as u256);
        };
        
        event::emit(StakeEvent {
            user_address: beneficiary_addr,
            pool_key: *pool_key,
            amount: stake_amount
        });
    }

    fun remove_pool_from_tracker(
        resource_addr: address,
        user_addr: address,
        pool_key: &PoolIdentifier
    ) acquires UserPoolsTracker {
        let tracker = borrow_global_mut<UserPoolsTracker>(resource_addr);
        if (table::contains(&tracker.user_to_pools, user_addr)) {
            let user_pools_vector = table::borrow_mut(&mut tracker.user_to_pools, user_addr);
            
            let (found, index) = vector::index_of(user_pools_vector, pool_key);
            if (found) {
                vector::remove(user_pools_vector, index);
            };

            if (vector::is_empty(user_pools_vector)) {
                table::remove(&mut tracker.user_to_pools, user_addr);
            }
        }
    }
    fun get_module_resource_signer(): signer acquires ModuleSignerStorage {
        let signer_storage = borrow_global<ModuleSignerStorage>(MODULE_ADMIN_ACCOUNT);
        account::create_signer_with_capability(&signer_storage.signer_cap)
    }

    fun is_emergency_inner(pool: &StakePoolData): bool {
        pool.emergency_locked || hodl_fa_config::is_global_emergency()
    }

    public fun is_hodl_period_finished(
        resource_addr: address,
        pool_key: PoolIdentifier
    ): bool acquires PoolsManager {
        let pools_manager = borrow_global<PoolsManager>(resource_addr);
        if (!table::contains(&pools_manager.pools, pool_key)) {
            return false
        };
        let pool = table::borrow(&pools_manager.pools, pool_key);
        is_finished_inner(pool)
    }

    fun is_finished_inner(pool: &StakePoolData): bool {
        timestamp::now_seconds() >= pool.end_timestamp
    }

    fun update_accum_reward(pool: &mut StakePoolData) {
        let current_time = get_time_for_last_update(pool);
        if (current_time <= pool.last_updated) {
            return
        };

        let new_accum_rewards = accum_rewards_since_last_updated(pool, current_time);
        pool.last_updated = current_time;
        if (new_accum_rewards > 0) {
            pool.accum_reward = pool.accum_reward + new_accum_rewards;
        };
    }

    fun accum_rewards_since_last_updated(pool: &StakePoolData, current_time: u64): u256 {
        if (current_time <= pool.last_updated) return 0;
        let seconds_passed = current_time - pool.last_updated;
        if (seconds_passed == 0) return 0;

        let total_effective_stake = pool_total_staked_with_boosted(pool);
        
        if (total_effective_stake == 0 || pool.reward_per_sec == 0) {
            return 0
        };

        (pool.reward_per_sec * (seconds_passed as u256)) / (total_effective_stake as u256)
    }

    fun update_user_reward_state(pool_accum_reward: u256, user_stake: &mut UserStake): u256 {
        let user_current_stake_raw_with_boost = user_stake_amount_with_boosted(user_stake);
        let pending_scaled_points = 0u256;
        let current_total_entitlement_points = 0u256;

        if (user_current_stake_raw_with_boost > 0) {
            current_total_entitlement_points = pool_accum_reward * (user_current_stake_raw_with_boost as u256);

            assert!(current_total_entitlement_points >= user_stake.reward_points_debt, error::invalid_state(ERR_NEGATIVE_PENDING_REWARD));
            pending_scaled_points = current_total_entitlement_points - user_stake.reward_points_debt;
        };

        if (pending_scaled_points > 0) {
            let reward_to_add_unscaled = pending_scaled_points / (ACCUM_REWARD_SCALE as u256);
            if (reward_to_add_unscaled > 0) {
                let new_total_earned_u256 = (user_stake.earned_reward as u256) + reward_to_add_unscaled;
                user_stake.earned_reward = if (new_total_earned_u256 >= (MAX_U64 as u256)) {
                    MAX_U64
                } else {
                    (new_total_earned_u256 as u64)
                };
            }
        };

        user_stake.reward_points_debt = current_total_entitlement_points;
        pending_scaled_points
    }

    fun get_time_for_last_update(pool: &StakePoolData): u64 {
        math64::min(pool.end_timestamp, timestamp::now_seconds())
    }

    fun pool_total_staked_with_boosted(pool: &StakePoolData): u128 {
        (fungible_asset::balance(pool.stake_store) as u128) + pool.total_boosted
    }

    fun user_stake_amount_with_boosted(user_stake: &UserStake): u128 {
        (user_stake.amount as u128) + user_stake.boosted_amount
    }

    fun calculate_max_unlocked_amount(
        pool: &StakePoolData,
        user_stake: &UserStake
    ): u64 {
        let pool_unstake_period = pool.unstake_period_seconds;
        if (pool_unstake_period == 0) {
            return user_stake.amount
        };

        let current_time = timestamp::now_seconds();
        let seconds_since_stake = if (current_time > user_stake.locked_start_time) { current_time - user_stake.locked_start_time } else { 0 };
        
        let total_unlocked_should_be = if (seconds_since_stake >= pool_unstake_period) {
            user_stake.locked_amount
        } else {
            (math128::mul_div(
                (user_stake.locked_amount as u128), 
                (seconds_since_stake as u128), 
                (pool_unstake_period as u128)
            ) as u64)
        };

        let already_unlocked = user_stake.unlocked_balance + (user_stake.locked_amount - user_stake.amount);
        let newly_unlocked = if (total_unlocked_should_be > already_unlocked) {
            total_unlocked_should_be - already_unlocked
        } else {
            0
        };

        user_stake.unlocked_balance + newly_unlocked
    }

    fun update_unlocked_balance(pool_unstake_period: u64, user_stake: &mut UserStake) {
        if (pool_unstake_period == 0) {
            let newly_unlocked = user_stake.amount - user_stake.unlocked_balance;
            user_stake.unlocked_balance = user_stake.unlocked_balance + newly_unlocked;
            return
        };

        let current_time = timestamp::now_seconds();
        let seconds_since_stake = if (current_time > user_stake.locked_start_time) { current_time - user_stake.locked_start_time } else { 0 };
        
        let total_unlocked_should_be = if (seconds_since_stake >= pool_unstake_period) {
            user_stake.locked_amount
        } else {
            (math128::mul_div(
                (user_stake.locked_amount as u128), 
                (seconds_since_stake as u128), 
                (pool_unstake_period as u128)
            ) as u64)
        };

        let already_unlocked = user_stake.unlocked_balance + (user_stake.locked_amount - user_stake.amount);
        let newly_unlocked = if (total_unlocked_should_be > already_unlocked) {
            total_unlocked_should_be - already_unlocked
        } else {
            0
        };

        user_stake.unlocked_balance = user_stake.unlocked_balance + newly_unlocked;
    }

    // Helper for HODL pools (Stake-Seconds logic)
    fun update_stake_seconds(
        pool: &mut StakePoolData,
        user_addr: address
    ) {
        if (!pool.is_hodl_pool) {
            return
        };
        let current_time_raw = timestamp::now_seconds();
        let current_time = if (pool.stakes_closed && pool.end_timestamp > 0 && current_time_raw > pool.end_timestamp) {
            pool.end_timestamp
        } else {
            current_time_raw
        };
        
        let pool_delta_t = if (current_time > pool.last_stake_seconds_updated) {
            current_time - pool.last_stake_seconds_updated
        } else { 0 };
        
        if (pool_delta_t > 0) {
            let pool_total_effective = pool_total_staked_with_boosted(pool);
            pool.accum_stake_seconds = pool.accum_stake_seconds + (pool_total_effective * (pool_delta_t as u128));
            pool.last_stake_seconds_updated = current_time;
        };

        if (table::contains(&pool.stakes, user_addr)) {
            let user_stake = table::borrow_mut(&mut pool.stakes, user_addr);
            let user_delta_t = if (current_time > user_stake.last_stake_seconds_updated) {
                current_time - user_stake.last_stake_seconds_updated
            } else { 0 };

            if (user_delta_t > 0) {
                let user_effective = user_stake_amount_with_boosted(user_stake);
                user_stake.acc_stake_seconds = user_stake.acc_stake_seconds + (user_effective * (user_delta_t as u128));
                user_stake.last_stake_seconds_updated = current_time;
            };
        };
    }
}
