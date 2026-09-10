# Ciclo de Vida v3 — Launchpad Multi-Quote (hoglet_core v3)

Ciclo de vida completo de un token lanzado con **cualquier quote whitelisted** (BTC, PEPE, bwsup, …)
de las fases 0–2 curva/migración/seeding/graduación igual a la v2; se resaltan cómo se difiere.

> Prerrequisito de contrato: el upgrade del AMM que permite a un launcher whitelisted
> crear pares bloqueados con quotes arbitrarios (`amm_router::create_locked_pair_for_launchpad`).

---

## Fase 0: Setup de plataforma (solo admin, una vez por activo)

1. **Whitelist del launcher en el AMM:** `amm_factory::add_launcher_to_whitelist(amm_admin, address_recurso_v3)`
   — la misma whitelist que hoy autoriza al battery v2; el `create_pair_locked` exige que el
   creador del par esté whitelisted (anti-squatting).
2. **Registro de quotes con pivote SUPRA:** `launch_config::add_quote_with_oracle(admin, quote)`.
   - Toma UN snapshot TWAP del oráculo del AMM (`amm_oracle::get_average_price_v2`).
   - Deriva del pivote SUPRA y congela en el quote: `price_ratio`, `raising_min/max`, `min_trade`.
   - La configuración queda en unidades del quote y el runtime **jamás vuelve a consultar el
     oráculo** (deploy/buy/sell/migración son independientes del uptime de keepers).
   - anti-flashloan-por-diseño: no hay ventana de oráculo en ningún flujo de usuarios.
3. **Mantenimiento del pivote (opcional):** `refresh_quote_with_oracle` re-deriva ante drift
   de mercado; `update_quote_params` es el override manual; `set_quote_enabled` desactiva.

## Fase 1: Nacimiento (Deploy)

`hoglet_core::deploy / deploy_and_buy_for_exact_quote` — atómico, exactamente como v2 pero
**pivoteado al quote elegido**:

1. **Peaje de entrada:** `deploy_fee` en SUPRA nativo (siempre, independiente del quote) → `platform_fee_address`.
2. **Forja del token (`asset_manager::create_fa`):** FA estándar, supply inicial 0,
   `MintRef`+`BurnRef` (+ `SmartTokenCap` solo para DAOs). Nunca `MutatorRef` para usuarios.
3. **Quote validado:** el deploy exige que el quote esté en la whitelist y habilitado
   (`launch_config::require_quote_config`); la dirección es AMM-canónica por construcción
   (pure FA o wrapper de coin legacy — los gateway-paired son rechazados al registrar).
4. **Asegurando el terreno en el DEX:** UN solo par bloqueado `[Token / Quote]` creado
   vía `amm_router::create_locked_pair_for_launchpad` (vacío, locked hasta la migración).
5. **Nacimiento del DAO (si no es meme):** `petra::create_dao_inflationary_from_launcher`
   con el gauge del pool `[Token/Quote]` referenciado.
6. **Curva de unión:** `pool::create_pool` inicializa reservas virtuales en unidades
   del quote (`v_quote = raising * virtual_mult`; `v_token` derivado del `price_ratio`
   congelado en el pivote) y fija `target_threshold` = `raising` (en RAW del quote).

## Fase 2: La Carrera (Bonding Curve en el quote)

1. **Comercio:** `buy_tokens` / `sell_tokens` / `swap_quote_for_exact_tokens`.
   El usuario **paga y cobra en el quote** que eligió el creador al lanzar (SF pago único;
   la curva vive entera en esa moneda). Si el quote es un legacy coin (SUPRA→bwsup, etc.),
   el front wrap/unwraps automático con las entradas del router del AMM — dentro del
   contrato todo es FA canónico.
2. **Comisiones:** Platform + Creator fees en el propio quote (stores FA creados on-demand,
   nunca abortan por falta de store — sin dirección fallback necesaria).
3. **HODL (memes):** `stake`/`unstake`/`harvest` en `hodl_fa`, denominado en el token
   lanzado (independiente del quote). Bloqueado tras completar la curva (anti flash-stake).
4. **Cruzando la meta:** el `quote` real acumulado en la bóveda iguala `target_threshold`
   → `is_completed = true` (freeze). **No hay oráculo aquí**: la meta es literal.

## Fase 3: La Graduación (Migración token/quote directo)

`migration::orchestrate_migration_to_amm` — la más simple de las tres versiones:

1. **Extracción:** el pool entrega TODO el quote real (`extract_all_quote`).
2. **Exceso:** si la curva pasó del target (compras exactas), el exceso va al
   `benefitiary_address_for_excess` **en el quote recaudado** (sin conversiones).
3. **Economía de apertura:** se acuña `tokens_for_lp` desde el snapshot final de la curva
   para que el precio de apertura DEX sea idéntico al último precio de curva (cero gap).
4. **Inyección:** `amm_router::add_liquidity_from_launchpad_fa_beta(token, quote, …)`
   — desbloquea el par, siembra liquidez, LP quemado. **Sin oráculo, sin buffer, sin conversiones.**
5. **Recompensas:** migrator reward (al que paga gas), staking reward (memes), dev reward
   (DAOs: mint directo; memes: depositado y stakeado en HODL para el dev).
6. **Purga de permisos:** memes → supply inmutable; DAOs → MintRef al `jubilee`,
   TaxFreeCap al DAO, administración al DAO, `burn_ref`/`transfer_ref` destruidos.
7. **Gauge:** se activa el gauge del pool sembrado `[Token/Quote]`;
   el resto nace inactivo hasta tener liquidez orgánica (vía gobernanza).

## Fase 4: Madurez

- **Memes:** trading libre en el DEX `[Token/Quote]`; tras el período HODL el dev puede
  crear su Static DAO con `activate_delayed_dao`.
- **DAOs:** herald (stake/voto) → anchor (propuestas) → jubilee (inflación con el MintRef
  heredado) → zeal (gauges sobre el pool `[Token/Quote]`, farmeo de LP de liquidez).

---

## Serie de seguridad específica de v3 (oracle / flash-loan)

| Vector | Mitigación |
|---|---|
| Flash-loan infla el TWAP → "meta gigante" | El oráculo solo corre en la tx del admin (`add/refresh_quote`); ningún flujo de usuario lo consulta |
| Manipular la curva | El precio es matemática de reservas virtuales internas, no spot del AMM |
| Pump la meta con liquidez prestada | Exige **retener el quote real** en la bóveda; tras completar, sell está bloqueado → el flash-loan no puede deshacer |
| Squatting del par | El par nace bloqueado en el deploy (único que puede seedear es el launcher whitelisted) |
| Quote identity fork | `add_quote` rechaza gateway-paired FAs; se guarda la dirección AMM-canonical |
| Quotes demasiado baratos (u64) | `add/refresh` aborta con `ERROR_QUOTE_RAISE_EXCEEDS_U64` en vez de truncar |

## Track SUPRA nativa (single-structure)

Los pools con quote = el **FA nativo de red de SUPRA** (`0xA`, creado por el framework en
el genesis como metadata emparejada del Coin nativo) funcionan sin ningún bridge propio:

- **Custodia 1:1 con el resto de quotes** (FungibleStore + contador interno) — no hay
  estructura dual: el launcher es un único código FA para todos los quotes.
- **Buy**: si el wallet no tiene suficiente 0xA-FA, el launcher retira SUPRA nativa
  (`coin::withdraw<SupraCoin>` — el framework mezcla CoinStore + store 0xA del wallet) y la
  convierte con `coin::coin_to_fungible_asset` (pública del framework). El usuario paga SUPRA
  cruda, una sola tx, cero wrappers en su vida.
- **Sell**: el vendedor recibe 0xA-FA — la representación estándar de su balance SUPRA
  (retiros futuros del framework la mezclan de vuelta automáticamente).
- **Par**: creado en la identidad de trading del AMM `(token, bwsup)` vía la rama original
  `is_supra` del gate — mientras la custodia de curva vive en 0xA.
- **Migración**: vía `add_liquidity_from_launchpad_fa_beta` (pública): canonicaliza 0xA→bwsup
  → resuelve el par → el `smart_withdraw` del router cae al fallback nativo — que con el
  withdraw-mixto del framework recoge el 0xA-FA depositado en el resource store y lo envuelve.
  El gauge se activa sobre el pool `(token, bwsup)` (`seeded_pool` explícito).
- El pivote del SUPRA quote es **trivial** (1 SUPRA = SUPRA_RAW_PER_WHOLE): ni oráculo se usa.

## Ruta futura: compras multi-token (Aggregator)

Contrato independiente (sugerido: `smart_contract/quote_agg/`) que compone:

```
usuario tiene X → AMM swap (amm_router) X → quote_del_pool → hoglet_core::buy_tokens
```

Sin tocar v3: el atacante/agente simplemente garantiza quote pasada a la curva. Puede
ser entry único (swap+buy atómico) o dos txs con el router ya existente.

---

## SCOPE FINAL de quotes v1 (fresado al cierre)

| Clase de quote | Soporte | Mecánica |
|---|---|---|
| **SUPRA nativa** (Coin legacy de la red) | ✅ tratamiento nativo completo | custodia = `0xA` (la FA nativa de la red, creada por el framework en el genesis); buy con `coin::withdraw` mixto + `coin_to_fungible_asset` pública; payout en `0xA`-FA (balance SUPRA estándar-framework); par en `(token, bwsup)`; migración por `fa_beta` (canonicaliza 0xA→bwsup; el `smart_withdraw` fallback con el mixed-withdraw del framework recoge la custodia). Pivote trivial (sin oráculo). |
| **Todo FA puro** (BTC-FA, PEPE-FA, iassets iSUPRA/iWBTC/iETH, wrappers existentes…) | ✅ ilimitado vía whitelist | track FA-genérico cero-código-por-token; pivote via snapshot TWAP al registrar |
| **FA-parejadas de coins legacy sin wrapper estable** | ❌ excluidas DELIBERADAMENTE | la validación del whitelist (`paired_coin` check) las rechaza por construcción |

Supra es el único coin legacy real relevante — **su identidad AMM (bwsup) existe desde la
genesis del AMM** → el canónico es estable para siempre (no-flip por orden de resolución:
wrapper-check primero).

## EXTENSIÓN FUTURA: coin legacy sin FA propia (patrón documentado)Si algún día se quisiera soportar un coin legacy arbitrario (que hoy es inviable):

1. **Wrapper-first**: crear su wrapper en el AMM oficialmente (fecha-1, identidad
   determinística estilo bwsup — evita el FLIP adversarial del canónico: verificado que
   `get_canonical_address` se reordena a wrapper si existe (`is_wrapper` primero), y que la
   creación del wrapper es lazy en operaciones rutinarias (router.move:753) → un paired-FA
   sin wrapper puede flippear adversarialmente y hacer huérfanos los pares).
2. **Whitelist**: guardar la dirección del wrapper (NO la paired-FA).
3. **1 helper permissionado en el AMM** (genérico): `wrap/unwrap_for_launchpad<CoinType>`
   assertion `is_whitelisted(launcher)` —转化 nativo⇆wrapper para buy/sell del launcher.
4. Custody = wrapper-FA → **cero cambios en Pool, cero ramas duales** — el launcher sigue
   siendo un solo código FA. Los typeargs los alimenta el frontend por-quote.

---

## BUFFER ROUTE (V3-BUFFER-ROUTE � opt-in admin)

Los pools cuyo quote es SUPRA-nativa pueden migrar sembrando liquidez **iSUPRA**
(ruta buffer) cuando el admin la habilita (`set_buffer_target(iSUPRA, true)`):

- **Deploy**: se pre-crean DOS pares bloqueados � `(token, bwsup)` (identidad de
  trading) y `(token, iSUPRA)` (destino de siembra PoEL) � y AMBOS pools nacen
  como gauges del DAO-track (`amm_pool_addresses` con 2 entries, inactivos hasta
  la siembra - paridad v2). [AUDIT V3-9: sin esto, `activate_seeded_gauge`
  abortaba GAUGE_NOT_FOUND en la ruta buffer para tokens DAO]
- **Migracin**: la ruta se resuelve TEMPRANO (determinstica, antes del
  `mint_and_distribute_rewards` para que la exenci�n de taxes del smart token y
  la activaci�n de gauge sean consistentes con el pool sembrado).
  Precondiciones TODAS upfront: launcher whitelisted en el buffer, buffer no
  pausado, stock >= recolectado, target != 0x0. Cualquier falla -> fallback
  fail-open a la siembra bwsup canonica (corrige el defecto v2 que solo
  verificaba stock - AUDIT_REPORT:128).
- **Rate guard [AUDIT V3-10]**: el exchange del buffer debe devolver al menos
  `(10000 - slippage_bps)/10000` del 1:1 SUPRA esperado � si no, la tx aborta
  (`ERROR_BUFFER_RATE_DEGRADED`): fondos seguros, migrador reintenta.
  Sin esto un seed subrespaldado seria drenado por arbitraje en el 1er bloque.
- Conversion custodia->SUPRA nativa: via `coin::withdraw<SupraCoin>` (el
  withdraw mixto publico del framework: CoinStore + store 0xA-FA).
- Custodia default OFF: sin `is_buffer_enabled`, todo queda en el track
  canonico bwsup sin dependencias externas.
