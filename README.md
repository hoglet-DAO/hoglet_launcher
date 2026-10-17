# Hoglet Launcher

**Automated bonding curve token launchpad and HODL staking protocol built on Supra Move.**  
Launch memecoins and protocol tokens with deterministic linear/exponential price discovery, virtual liquidity pools, atomic DEX AMM migration, and anti-dump HODL staking with NFT multipliers.

🌐 **Platform:** [https://hoglet.xyz](https://hoglet.xyz)  
📖 **Lifecycle & Curve Math Guide:** [`LAUNCHER_LIFECYCLE.md`](../LAUNCHER_LIFECYCLE.md)  
🛡️ **Security Audits:** [`audits/`](../audits/)  
📄 **License:** [`LICENSE.md`](./LICENSE.md)

---

## ⚡ Overview & Features

**Hoglet Launcher** solves token launch liquidity fragmentation by bootstrapping price discovery on-chain before migrating directly to AMM decentralized exchanges:

- **Bonding Curve Price Discovery:** Deterministic virtual pool reserves (`pool.move`) ensure guaranteed buy/sell liquidity with configurable slippage protection.
- **Strict Accounting Isolation:** Raw FA store balances are decoupled from the bonding curve's mathematical state (`quote_balance_internal`), preventing flash-loan manipulation or un-tracked donation attacks.
- **Atomic DEX AMM Migration:** When the target raise is fulfilled, `migration.move` automatically seeds liquidity pairs (`spike_amm`), locks LP tokens, and transitions the token to the DAO governance track.
- **HODL Staking & NFT Boost:** Memecoins deploy an automated staking vault (`hodl_fa.move`) with customizable lock periods, continuous stake-second accounting, and NFT boost multipliers.

---

## 🏛️ Architecture & Modules

```
launcher/
├── hoglet_core/        # Bonding curve & migration engine
│   ├── hoglet_core.move    # Deploy, buy, sell & graduation orchestration
│   ├── pool.move           # Internal reserve state & virtual pool math
│   ├── migration.move      # Atomic AMM pair seeding & DAO handoff
│   ├── asset_manager.move  # Fungible asset minting & capability destruction
│   ├── launch_config.move  # Curve parameters, fee structures & PoEL buffer
│   ├── launch_vault.move   # Protocol yield harvesting & keeper sweeps
│   └── math.move           # u256 fixed-point arithmetic & ideal supply
└── hodl_fa/            # Token staking & liquidity lockups
    ├── hodl_fa.move        # Stake-seconds, boost mechanics & emergency safety
    └── hodl_fa_config.move # Registration fees & whitelisted launcher contracts
```

---

## 🛡️ Security & Audits

The Launcher has undergone comprehensive security reviews documented in [`audits/`](../audits/).

- **Inviolable Reserves:** Funds cannot be drained via un-tracked direct deposits.
- **Atomic Migrations:** Capability burn and admin transfer to the DAO happen within a single atomic Move transaction.

---

## 📄 License

This software is released under the **Hoglet Launcher Smart Contracts License (Source-Available & Restricted Commercial Use)**.  
See [`LICENSE.md`](./LICENSE.md) for full terms.
