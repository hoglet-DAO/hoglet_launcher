module hoglet_core::math {
    use std::error;
    use aptos_std::math128;

    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO: u64 = 26;

    const U128_MAX: u128 = 340282366920938463463374607431768211455u128;

    public fun calculate_add_liquidity_cost(
        supra_reserves: u128,
        token_reserves: u128,
        token_amount: u128
    ): u128 {
        assert!(supra_reserves > 0 && token_reserves > 0 && token_amount > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        assert!(token_reserves > token_amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        
        let numerator_u256 = (supra_reserves as u256) * (token_reserves as u256);
        let denominator_u256 = (token_reserves as u256) - (token_amount as u256);
        let new_supra_reserves_u256 = (numerator_u256 + denominator_u256 - 1) / denominator_u256;
        let cost_u256 = new_supra_reserves_u256 - (supra_reserves as u256);

        assert!(cost_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (cost_u256 as u128)
    }

    public fun calculate_sell_token(
        token_reserves: u128,
        supra_reserves: u128,
        token_value: u128
    ): u128 {
        assert!(token_reserves > 0 && supra_reserves > 0 && token_value > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let numerator_u256 = (supra_reserves as u256) * (token_value as u256);
        let denominator_u256 = (token_reserves as u256) + (token_value as u256);
        let result_u256 = numerator_u256 / denominator_u256;

        assert!(result_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (result_u256 as u128)
    }

    public fun calculate_buy_token(
        token_reserves: u128,
        supra_reserves: u128,
        supra_value: u128
    ): u128 {
        assert!(token_reserves > 0 && supra_reserves > 0 && supra_value > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let numerator_u256 = (token_reserves as u256) * (supra_value as u256);
        let denominator_u256 = (supra_reserves as u256) + (supra_value as u256);
        let result_u256 = numerator_u256 / denominator_u256;

        assert!(result_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (result_u256 as u128)
    }

    public fun calculate_ideal_projected_supply_base(
        initial_v_token: u128,
        initial_v_supra: u128,
        fundraising_goal_supra: u64
    ): u128 {
        let goal_supra_u128 = (fundraising_goal_supra as u128);

        assert!(initial_v_supra > 0, error::invalid_argument(ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO));

        let k_invariant_u256 = (initial_v_token as u256) * (initial_v_supra as u256);
        let final_v_supra_ideal = initial_v_supra + goal_supra_u128;
        assert!(final_v_supra_ideal > 0, error::invalid_state(ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO));
        
        let final_v_token_ideal_u256 = k_invariant_u256 / (final_v_supra_ideal as u256);

        let ideal_circulating_supply_u256 = (initial_v_token as u256) - final_v_token_ideal_u256;
        
        let ideal_tokens_for_amm_u256 = 
            ((goal_supra_u128 as u256) * final_v_token_ideal_u256) / (final_v_supra_ideal as u256);
        
        let projected_supply_base_for_rewards_u256 = ideal_circulating_supply_u256 + ideal_tokens_for_amm_u256;
        assert!(projected_supply_base_for_rewards_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (projected_supply_base_for_rewards_u256 as u128)
    }

    public fun get_price_impact(
        supra_reserves_u128: u128,
        token_reserves_u128: u128,
        amount_u128: u128,
        is_buy: bool
    ): u64 {
        if (amount_u128 == 0) {
            return 0
        };

        if (token_reserves_u128 == 0 || supra_reserves_u128 == 0) {
            return 0
        };

        let price_precision = 100_000_000u128; // 10^8 precision scale
        
        let initial_price_u128 = math128::mul_div(supra_reserves_u128, price_precision, token_reserves_u128);
        
        let final_price_u128 = if (is_buy) {
            let supra_in = calculate_add_liquidity_cost(
                supra_reserves_u128, 
                token_reserves_u128, 
                amount_u128
            );

            let new_supra_u128 = supra_reserves_u128 + supra_in;
            
            if (token_reserves_u128 <= amount_u128) { return 10000 };
            let new_token_u128 = token_reserves_u128 - amount_u128;
            
            math128::mul_div(new_supra_u128, price_precision, new_token_u128)
        } else { 
            let supra_out = calculate_sell_token(
                token_reserves_u128, 
                supra_reserves_u128, 
                amount_u128
            );

            if (supra_reserves_u128 <= supra_out) { return 10000 };
            let new_supra_u128 = supra_reserves_u128 - supra_out;
            let new_token_u128 = token_reserves_u128 + amount_u128;

            math128::mul_div(new_supra_u128, price_precision, new_token_u128)
        };

        if (initial_price_u128 == 0) {
            return if (final_price_u128 > 0) { 10000 } else { 0 }
        };

        let price_diff_u128 = if (final_price_u128 > initial_price_u128) {
            final_price_u128 - initial_price_u128
        } else {
            initial_price_u128 - final_price_u128
        };
        
        let impact_bps_u128 = math128::mul_div(price_diff_u128, 10000, initial_price_u128);
        
        if (impact_bps_u128 > (10000 as u128)) {
            10000
        } else {
            (impact_bps_u128 as u64)
        }
    }
}
