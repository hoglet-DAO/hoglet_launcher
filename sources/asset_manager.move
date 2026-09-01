module hoglet_core::asset_manager {
    use std::option::{Self, Option};
    use std::string::{String};
    use std::bcs;
    use std::signer;

    use supra_framework::fungible_asset::{
        Self,
        MintRef,
        BurnRef,
        TransferRef,
        Metadata
    };
    use supra_framework::object::{Self, Object, ExtendRef, object_address};
    use supra_framework::primary_fungible_store;
    use dao_tokens::smart_token::{Self, SmartTokenCap};

    friend hoglet_core::hoglet_core;
    friend hoglet_core::migration;

    const E_MINTING_DISABLED: u64 = 1;
    const E_MINTING_ALREADY_DISABLED: u64 = 2;
    const E_BURNING_DISABLED: u64 = 3;

    struct LST has key {
        fa_generator_extend_ref: ExtendRef,
        token_creation_nonce: u64
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ManagedFungibleAsset has key {
        mint_ref: Option<MintRef>,
        burn_ref: Option<BurnRef>,
        transfer_ref: Option<TransferRef>,
        smart_token_cap: Option<SmartTokenCap>,
        minting_enabled: bool,
        burning_enabled: bool
    }

    fun init_module(sender: &signer) {
        let constructor_ref = object::create_named_object(sender, b"FA Generator");
        let fa_generator_extend_ref = object::generate_extend_ref(&constructor_ref);
        let lst = LST {
            fa_generator_extend_ref,
            token_creation_nonce: 0
        };
        move_to(sender, lst);
    }

    public(friend) fun create_fa(
        name: String,
        symbol: String,
        decimals: u8,
        icon_uri: String,
        project_uri: String,
        is_meme: bool
    ) : address acquires LST {
        let lst = borrow_global_mut<LST>(@hoglet_core);
        lst.token_creation_nonce = lst.token_creation_nonce + 1;

        let fa_key_seed = bcs::to_bytes(&lst.token_creation_nonce);
        let fa_generator_signer = object::generate_signer_for_extending(&lst.fa_generator_extend_ref);
        let fa_obj_constructor_ref = &object::create_named_object(&fa_generator_signer, fa_key_seed);
        let fa_obj_signer = object::generate_signer(fa_obj_constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            fa_obj_constructor_ref,
            option::none(),
            name,
            symbol,
            decimals,
            icon_uri,
            project_uri
        );

        let smart_token_cap = if (!is_meme) {
            // [Phase 1] Inject the Smart Token hooks and save the Cap
            option::some(smart_token::initialize(fa_obj_constructor_ref))
        } else {
            option::none()
        };

        let mint_ref = fungible_asset::generate_mint_ref(fa_obj_constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(fa_obj_constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(fa_obj_constructor_ref);

        move_to(
            &fa_obj_signer,
            ManagedFungibleAsset {
                mint_ref: option::some(mint_ref),
                burn_ref: option::some(burn_ref),
                transfer_ref: option::some(transfer_ref),
                smart_token_cap,
                minting_enabled: true,
                burning_enabled: true
            }
        );

        object::address_from_constructor_ref(fa_obj_constructor_ref)
    }

    public(friend) fun mint(
        token_address: address,
        to: address,
        amount: u64,
    ) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = authorized_borrow_refs(asset);
        assert!(managed_asset.minting_enabled, E_MINTING_DISABLED);
        assert!(option::is_some(&managed_asset.mint_ref), E_MINTING_DISABLED);

        let mint_ref = option::borrow(&managed_asset.mint_ref);
        let fa = fungible_asset::mint(mint_ref, amount);

        // Use deposit_with_ref to bypass dispatchable hooks (taxes) during launchpad phase
        if (option::is_some(&managed_asset.transfer_ref)) {
            let transfer_ref = option::borrow(&managed_asset.transfer_ref);
            let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
            fungible_asset::deposit_with_ref(transfer_ref, to_wallet, fa);
        } else {
            let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
            fungible_asset::deposit(to_wallet, fa);
        };
    }

    public(friend) fun disable_minting(token_address: address) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        assert!(managed_asset.minting_enabled, E_MINTING_ALREADY_DISABLED);
        managed_asset.minting_enabled = false;
        managed_asset.burning_enabled = false;
    }


    public(friend) fun burn(
        token_address: address,
        from: address,
        amount: u64,
    ) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = authorized_borrow_refs(asset);
        assert!(managed_asset.burning_enabled, E_BURNING_DISABLED);
        assert!(option::is_some(&managed_asset.burn_ref), E_MINTING_DISABLED);
        let burn_ref = option::borrow(&managed_asset.burn_ref);
        let from_wallet = primary_fungible_store::primary_store(from, asset);

        // Use withdraw_with_ref to bypass dispatchable hooks (taxes) during launchpad phase
        if (option::is_some(&managed_asset.transfer_ref)) {
            let transfer_ref = option::borrow(&managed_asset.transfer_ref);
            let fa = fungible_asset::withdraw_with_ref(transfer_ref, from_wallet, amount);
            fungible_asset::burn(burn_ref, fa);
        } else {
            fungible_asset::burn_from(burn_ref, from_wallet, amount);
        };
    }

    public(friend) fun extract_mint_ref(token_address: address): MintRef acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        assert!(managed_asset.minting_enabled, E_MINTING_DISABLED);
        managed_asset.minting_enabled = false;
        managed_asset.burning_enabled = false;
        option::extract(&mut managed_asset.mint_ref)
    }

    /// Extract the SmartTokenCap from the asset (it can only be done once, typically during migration)
    public(friend) fun extract_smart_token_cap(
        token_address: address
    ): Option<SmartTokenCap> acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        if (option::is_some(&managed_asset.smart_token_cap)) {
            let cap = option::extract(&mut managed_asset.smart_token_cap);
            option::some(cap)
        } else {
            option::none()
        }
    }

    inline fun authorized_borrow_refs(asset: Object<Metadata>): &ManagedFungibleAsset acquires ManagedFungibleAsset {
        borrow_global<ManagedFungibleAsset>(object_address(&asset))
    }

    #[view]
    public fun is_minting_enabled(token_address: address): bool acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = authorized_borrow_refs(asset);
        managed_asset.minting_enabled && option::is_some(&managed_asset.mint_ref)
    }

    #[view]
    public fun get_balance(token_address: address, owner_addr: address): u64 {
        let fa_metadata_obj: Object<Metadata> = object::address_to_object(token_address);
        primary_fungible_store::balance(owner_addr, fa_metadata_obj)
    }

    #[view]
    public fun get_total_supply(token_address: address): u128 {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let total_supply = fungible_asset::supply(asset);
        if (option::is_some(&total_supply)) {
            *option::borrow(&total_supply)
        } else { 0u128 }
    }

    #[view]
    public fun get_token_metadata(token_address: address): (String, String, u8, String, String) {
        let token_metadata = object::address_to_object<Metadata>(token_address);
        (
            fungible_asset::name(token_metadata),
            fungible_asset::symbol(token_metadata),
            fungible_asset::decimals(token_metadata),
            fungible_asset::icon_uri(token_metadata),
            fungible_asset::project_uri(token_metadata)
        )
    }

    public fun is_account_registered(token_address: address, account: address): bool {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        primary_fungible_store::primary_store_exists(account, asset)
    }

    public fun register(token_address: address, account: &signer) {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        primary_fungible_store::ensure_primary_store_exists(signer::address_of(account), asset);
    }

    public(friend) fun destroy_transfer_ref(token_address: address) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        if (option::is_some(&managed_asset.transfer_ref)) {
            let _ref = option::extract(&mut managed_asset.transfer_ref);
            // _ref is dropped
        }
    }

    /// Extracts the managed TransferRef (leaving the slot empty) so it can be
    /// exchanged for a TaxFreeCap during migration (audit10 C1a).
    /// Aborts if the ref was already extracted or destroyed.
    public(friend) fun extract_transfer_ref(token_address: address): TransferRef acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        option::extract(&mut managed_asset.transfer_ref)
    }

    public(friend) fun destroy_burn_ref(token_address: address) acquires ManagedFungibleAsset {
        let asset: Object<Metadata> = object::address_to_object(token_address);
        let managed_asset = borrow_global_mut<ManagedFungibleAsset>(object_address(&asset));
        if (option::is_some(&managed_asset.burn_ref)) {
            let _ref = option::extract(&mut managed_asset.burn_ref);
            // _ref is dropped
        }
    }
}