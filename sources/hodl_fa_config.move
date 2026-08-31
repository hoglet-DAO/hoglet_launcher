module hoglet_core::hodl_fa_config {
    use std::signer;
    use std::error;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use supra_framework::event;

    const ERR_NO_PERMISSIONS: u64 = 200;
    const ERR_NOT_INITIALIZED: u64 = 201;
    const ERR_GLOBAL_EMERGENCY: u64 = 202;
    const ERR_INVALID_CONFIG_VALUE: u64 = 203;
    const ERR_CANNOT_TRANSFER_TO_SELF: u64 = 204;

    const MIN_TREASURY_GRACE_PERIOD_SECONDS: u64 = 7 * 24 * 60 * 60;
    const MAX_TREASURY_GRACE_PERIOD_SECONDS: u64 = 365 * 24 * 60 * 60;

    struct GlobalConfig has key {
        emergency_admin_address: address,
        treasury_admin_address: address,
        fee_treasury_address: address,
        global_emergency_locked: bool,
        treasury_withdraw_grace_period_seconds: u64,
        pool_registration_fee_amount: u64,
        linked_contract_address: Option<address>,
    }

    struct AdminConfig has key {
        current_admin: address,
    }

    #[event]
    struct ConfigParameterUpdatedEvent has drop, store {
        admin_address: address,
        parameter_name: String,
        new_value_u64: u64,
        new_value_address: Option<address>,
    }

    #[event]
    struct AdminTransferredEvent has drop, store {
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct EmergencyAdminTransferredEvent has drop, store {
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct TreasuryAdminTransferredEvent has drop, store {
        old_admin: address,
        new_admin: address,
    }

    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @hoglet_core, error::permission_denied(ERR_NO_PERMISSIONS));

        move_to(admin, GlobalConfig {
            emergency_admin_address: admin_addr,
            treasury_admin_address: admin_addr,
            fee_treasury_address: admin_addr,
            global_emergency_locked: false,
            treasury_withdraw_grace_period_seconds: 7257600,
            pool_registration_fee_amount: 137_000_000,
            linked_contract_address: option::none(),
        });

        move_to(admin, AdminConfig {
            current_admin: admin_addr,
        });
    }

    public entry fun transfer_emergency_admin(admin: &signer, new_admin: address) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin);
        assert!(new_admin != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));
        
        let global_config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        let old_admin = global_config.emergency_admin_address;
        global_config.emergency_admin_address = new_admin;

        event::emit(EmergencyAdminTransferredEvent {
            old_admin,
            new_admin,
        });
    }

    public entry fun transfer_treasury_admin(admin: &signer, new_admin: address) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin);
        assert!(new_admin != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));
        
        let global_config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        let old_admin = global_config.treasury_admin_address;
        global_config.treasury_admin_address = new_admin;

        event::emit(TreasuryAdminTransferredEvent {
            old_admin,
            new_admin,
        });
    }

    public entry fun set_treasury_withdraw_grace_period(
        admin_signer: &signer,
        new_period: u64
    ) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin_signer);
        assert!(
            new_period >= MIN_TREASURY_GRACE_PERIOD_SECONDS && new_period <= MAX_TREASURY_GRACE_PERIOD_SECONDS,
            error::invalid_argument(ERR_INVALID_CONFIG_VALUE)
        );
        let config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        config.treasury_withdraw_grace_period_seconds = new_period;
        event::emit(ConfigParameterUpdatedEvent {
            admin_address: signer::address_of(admin_signer),
            parameter_name: string::utf8(b"treasury_withdraw_grace_period_seconds"),
            new_value_u64: new_period,
            new_value_address: option::none(),
        });
    }

    public entry fun set_pool_registration_fee(
        admin_signer: &signer,
        new_fee_amount: u64,
        new_fee_treasury_address: address
    ) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin_signer);
        let config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        config.pool_registration_fee_amount = new_fee_amount;
        config.fee_treasury_address = new_fee_treasury_address;
        event::emit(ConfigParameterUpdatedEvent {
            admin_address: signer::address_of(admin_signer),
            parameter_name: string::utf8(b"pool_registration_fee"),
            new_value_u64: new_fee_amount,
            new_value_address: option::some(new_fee_treasury_address),
        });
    }

    public entry fun set_linked_contract_address(
        admin_signer: &signer,
        whitelisted_addr: address
    ) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin_signer);
        assert!(whitelisted_addr != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));
        let config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        config.linked_contract_address = option::some(whitelisted_addr);
        event::emit(ConfigParameterUpdatedEvent {
            admin_address: signer::address_of(admin_signer),
            parameter_name: string::utf8(b"linked_contract_address"),
            new_value_u64: 0,
            new_value_address: option::some(whitelisted_addr),
        });
    }

    public entry fun transfer_admin(
        current_admin_signer: &signer,
        new_admin_addr: address
    ) acquires AdminConfig {
        assert_is_current_admin(current_admin_signer);
        let admin_config = borrow_global_mut<AdminConfig>(@hoglet_core);
        assert!(new_admin_addr != admin_config.current_admin, error::invalid_argument(ERR_CANNOT_TRANSFER_TO_SELF));
        assert!(new_admin_addr != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));
        
        let old_admin = admin_config.current_admin;
        admin_config.current_admin = new_admin_addr;
        
        event::emit(AdminTransferredEvent {
            old_admin,
            new_admin: new_admin_addr,
        });
    }

    public entry fun enable_global_emergency(emergency_admin: &signer) acquires GlobalConfig {
        assert_is_emergency_admin(emergency_admin);
        let global_config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        assert!(!global_config.global_emergency_locked, error::invalid_state(ERR_GLOBAL_EMERGENCY));
        global_config.global_emergency_locked = true;
    }

    public entry fun disable_global_emergency(emergency_admin: &signer) acquires GlobalConfig {
        assert_is_emergency_admin(emergency_admin);
        let global_config = borrow_global_mut<GlobalConfig>(@hoglet_core);
        assert!(global_config.global_emergency_locked, error::invalid_state(ERR_GLOBAL_EMERGENCY));
        global_config.global_emergency_locked = false;
    }

    #[view]
    public fun get_emergency_admin_address(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(@hoglet_core).emergency_admin_address
    }

    #[view]
    public fun get_treasury_admin_address(): address acquires GlobalConfig {
        borrow_global<GlobalConfig>(@hoglet_core).treasury_admin_address
    }

    #[view]
    public fun get_treasury_withdraw_grace_period(): u64 acquires GlobalConfig {
        borrow_global<GlobalConfig>(@hoglet_core).treasury_withdraw_grace_period_seconds
    }

    #[view]
    public fun get_pool_registration_fee_config(): (u64, address) acquires GlobalConfig {
        let config = borrow_global<GlobalConfig>(@hoglet_core);
        (config.pool_registration_fee_amount, config.fee_treasury_address)
    }

    #[view]
    public fun get_linked_contract_address(): Option<address> acquires GlobalConfig {
        borrow_global<GlobalConfig>(@hoglet_core).linked_contract_address
    }

    #[view]
    public fun is_global_emergency(): bool acquires GlobalConfig {
        borrow_global<GlobalConfig>(@hoglet_core).global_emergency_locked
    }

    #[view]
    public fun get_current_admin(): address acquires AdminConfig {
        borrow_global<AdminConfig>(@hoglet_core).current_admin
    }



    public fun assert_is_current_admin(admin_signer: &signer) acquires AdminConfig {
        assert!(exists<AdminConfig>(@hoglet_core), error::invalid_state(ERR_NOT_INITIALIZED));
        let admin_config = borrow_global<AdminConfig>(@hoglet_core);
        assert!(signer::address_of(admin_signer) == admin_config.current_admin, error::permission_denied(ERR_NO_PERMISSIONS));
    }

    public fun assert_is_emergency_admin(admin_signer: &signer) acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@hoglet_core), error::invalid_state(ERR_NOT_INITIALIZED));
        let global_config = borrow_global<GlobalConfig>(@hoglet_core);
        assert!(signer::address_of(admin_signer) == global_config.emergency_admin_address, error::permission_denied(ERR_NO_PERMISSIONS));
    }
}