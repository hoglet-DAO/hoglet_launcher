module hoglet_core::launch_vault {
    // =================================================================
    // launch_vault yield collector for the launcher v3
    //
    // The launcher's resource account participates in the PoEL ecosystem
    // when the buffer route seeds liquidity iasset (the remainder of an
    // `exchange_coin_for_launch` returned by the router remains in the
    // resource's store, and if in the future a treasury share is enabled,
    // it will also be positioned there).
    //
    // 1:1 replica of the AMM's `amm_pair::claim_and_sweep` pattern:
    //  - PoEL 86400s phase cycle: in the EVEN phase the rewards are CLAIMED
    //    (the lockup timer starts); in the ODD phase they can already be withdrawn
    //    (lockup passed).
    //  - `poel::claim/withdraw_rewards` sends SupraCoin FROM the PoEL vault
    //    DIRECTLY to the account (resource) then this balance is swept here
    //    towards `platform_fee_address` (standard keeper model: the entry is
    //    permissionless and the indexer bot schedules it every phase).
    //  - If there is nothing to collect, it is a silent no-op (same
    //    defensive pattern as `coin_wrapper::claim_and_sweep_poel`).
    // =================================================================
    use std::signer::address_of;
    use supra_framework::account;
    use supra_framework::coin;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::timestamp;
    use supra_framework::supra_account;
    use dfmm_framework::iAsset;
    use dfmm_framework::poel;
    use hoglet_core::launch_config;

    const PHASE_LENGTH_SECONDS: u64 = 86400;

    /// Keeper permissionless: harvests PoEL rewards from the launcher's
    /// position (resource account) and transfers the collected balance to the
    /// platform's fee address. Follows the 2-phase cycle of PoEL.
    public entry fun harvest_launch_vault() {
        let resource_signer = launch_config::get_resource_signer();
        let resource_addr = address_of(&resource_signer);

        // 1) PoEL cycle phase (claim in even phase, withdraw in odd).
        let current_time = timestamp::now_seconds();
        let phases_since_epoch = current_time / PHASE_LENGTH_SECONDS;

        let rewards = iAsset::get_user_rewards(resource_addr);
        let (allocated, withdrawable) = {
            let (a, w, _, _, _) = iAsset::deconstruct_user_rewards(&rewards);
            (a, w)
        };

        if (phases_since_epoch % 2 == 0) {
            // Even phase (day 1): claim to start the lockup timer.
            if (allocated > 0) {
                poel::claim_rewards(&resource_signer);
            };
        } else {
            // Odd phase (day 2): lockup expired, safe to withdraw.
            if (withdrawable > 0) {
                poel::withdraw_rewards(&resource_signer);
            };
        };

        // 2) Sweep of the accumulated balance in the resource's native store.
        //    Any SupraCoin present there is pure profit/donation
        //    (curve custody lives in FA never operational balance).
        let total_balance = coin::balance<SupraCoin>(resource_addr);
        if (total_balance > 0) {
            let (_, _, _, platform_fee_address) = launch_config::get_platform_fees();
            supra_account::transfer_coins<SupraCoin>(&resource_signer, platform_fee_address, total_balance);
        };
    }

    #[view]
    public fun get_launch_vault_pending(): (u64, u64) {
        let resource_address = launch_config::get_resource_address();
        if (!account::exists_at(resource_address)) {
            return (0, 0)
        };
        let rewards = iAsset::get_user_rewards(resource_address);
        {
            let (allocated, withdrawable, _, _, _) = iAsset::deconstruct_user_rewards(&rewards);
            (allocated, withdrawable)
        }
    }
}
