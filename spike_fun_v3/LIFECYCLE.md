# Ciclo de Vida v3 â Launchpad Multi-Quote (hoglet_core v3)

Ciclo de vida completo de un token lanzado con **cualquier quote whitelisted** (BTC, PEPE, bwsup, â¦)
de las fases 0â2 curva/migraciÃ³n/seeding/graduaciÃ³n igual a la v2; se resaltan cÃ³mo se difiere.

> Prerrequisito de contrato: el upgrade del AMM que permite a un launcher whitelisted
> crear pares bloqueados con quotes arbitrarios (`amm_router::create_locked_pair_for_launchpad`).

---

## Fase 0: Setup de plataforma (solo admin, una vez por activo)

1. **Whitelist del launcher en el AMM:** `amm_factory::add_launcher_to_whitelist(amm_admin, address_recurso_v3)`
   â la misma whitelist que hoy autoriza al battery v2; el `create_pair_locked` exige que el
   creador del par estÃ© whitelisted (anti-squatting).
2. **Registro de quotes con pivote SUPRA:** `launch_config::add_quote_with_oracle(admin, quote)`.
   - Toma UN snapshot TWAP del orÃ¡culo del AMM (`amm_oracle::get_average_price_v2`).
   - Deriva del pivote SUPRA y congela en el quote: `price_ratio`, `raising_min/max`, `min_trade`.
   - La configuraciÃ³n queda en unidades del quote y el runtime **jamÃ¡s vuelve a consultar el
     orÃ¡culo** (deploy/buy/sell/migraciÃ³n son independientes del uptime de keepers).
   - anti-flashloan-por-diseÃ±o: no hay ventana de orÃ¡culo en ningÃºn flujo de usuarios.
3. **Mantenimiento del pivote (opcional):** `refresh_quote_with_oracle` re-deriva ante drift
   de mercado; `update_quote_params` es el override manual; `set_quote_enabled` desactiva.

## Fase 1: Nacimiento (Deploy)

`hoglet_core::deploy / deploy_and_buy_for_exact_quote` â atÃ³mico, exactamente como v2 pero
**pivoteado al quote elegido**:

1. **Peaje de entrada:** `deploy_fee` en SUPRA nativo (siempre, independiente del quote) â `platform_fee_address`.
2. **Forja del token (`asset_manager::create_fa`):** FA estÃ¡ndar, supply inicial 0,
   `MintRef`+`BurnRef` (+ `SmartTokenCap` solo para DAOs). Nunca `MutatorRef` para usuarios.
3. **Quote validado:** el deploy exige que el quote estÃ© en la whitelist y habilitado
   (`launch_config::require_quote_config`); la direcciÃ³n es AMM-canÃ³nica por construcciÃ³n
   (pure FA o wrapper de coin legacy â los gateway-paired son rechazados al registrar).
4. **Asegurando el terreno en el DEX:** UN solo par bloqueado `[Token / Quote]` creado
   vÃ­a `amm_router::create_locked_pair_for_launchpad` (vacÃ­o, locked hasta la migraciÃ³n).
5. **Nacimiento del DAO (si no es meme):** `petra::create_dao_inflationary_from_launcher`
   con el gauge del pool `[Token/Quote]` referenciado.
6. **Curva de uniÃ³n:** `pool::create_pool` inicializa reservas virtuales en unidades
   del quote (`v_quote = raising * virtual_mult`; `v_token` derivado del `price_ratio`
   congelado en el pivote) y fija `target_threshold` = `raising` (en RAW del quote).

## Fase 2: La Carrera (Bonding Curve en el quote)

1. **Comercio:** `buy_tokens` / `sell_tokens` / `swap_quote_for_exact_tokens`.
   El usuario **paga y cobra en el quote** que eligiÃ³ el creador al lanzar (SF pago Ãºnico;
   la curva vive entera en esa moneda). Si el quote es un legacy coin (SUPRAâbwsup, etc.),
   el front wrap/unwraps automÃ¡tico con las entradas del router del AMM â dentro del
   contrato todo es FA canÃ³nico.
2. **Comisiones:** Platform + Creator fees en el propio quote (stores FA creados on-demand,
   nunca abortan por falta de store â sin direcciÃ³n fallback necesaria).
3. **HODL (memes):** `stake`/`unstake`/`harvest` en `hodl_fa`, denominado en el token
   lanzado (independiente del quote). Bloqueado tras completar la curva (anti flash-stake).
4. **Cruzando la meta:** el `quote` real acumulado en la bÃ³veda iguala `target_threshold`
   â `is_completed = true` (freeze). **No hay orÃ¡culo aquÃ­**: la meta es literal.

## Fase 3: La GraduaciÃ³n (MigraciÃ³n token/quote directo)

`migration::orchestrate_migration_to_amm` â la mÃ¡s simple de las tres versiones:

1. **ExtracciÃ³n:** el pool entrega TODO el quote real (`extract_all_quote`).
2. **Exceso:** si la curva pasÃ³ del target (compras exactas), el exceso va al
   `benefitiary_address_for_excess` **en el quote recaudado** (sin conversiones).
3. **EconomÃ­a de apertura:** se acuÃ±a `tokens_for_lp` desde el snapshot final de la curva
   para que el precio de apertura DEX sea idÃ©ntico al Ãºltimo precio de curva (cero gap).
4. **InyecciÃ³n:** `amm_router::add_liquidity_from_launchpad_fa_beta(token, quote, â¦)`
   â desbloquea el par, siembra liquidez, LP quemado. **Sin orÃ¡culo, sin buffer, sin conversiones.**
5. **Recompensas:** migrator reward (al que paga gas), staking reward (memes), dev reward
   (DAOs: mint directo; memes: depositado y stakeado en HODL para el dev).
6. **Purga de permisos:** memes â supply inmutable; DAOs â MintRef al `jubilee`,
   TaxFreeCap al DAO, administraciÃ³n al DAO, `burn_ref`/`transfer_ref` destruidos.
7. **Gauge:** se activa el gauge del pool sembrado `[Token/Quote]`;
   el resto nace inactivo hasta tener liquidez orgÃ¡nica (vÃ­a gobernanza).

## Fase 4: Madurez

- **Memes:** trading libre en el DEX `[Token/Quote]`; tras el perÃ­odo HODL el dev puede
  crear su Static DAO con `activate_delayed_dao`.
- **DAOs:** herald (stake/voto) â anchor (propuestas) â jubilee (inflaciÃ³n con el MintRef
  heredado) â zeal (gauges sobre el pool `[Token/Quote]`, farmeo de LP de liquidez).

---

## Serie de seguridad especÃ­fica de v3 (oracle / flash-loan)

| Vector | MitigaciÃ³n |
|---|---|
| Flash-loan infla el TWAP â "meta gigante" | El orÃ¡culo solo corre en la tx del admin (`add/refresh_quote`); ningÃºn flujo de usuario lo consulta |
| Manipular la curva | El precio es matemÃ¡tica de reservas virtuales internas, no spot del AMM |
| Pump la meta con liquidez prestada | Exige **retener el quote real** en la bÃ³veda; tras completar, sell estÃ¡ bloqueado â el flash-loan no puede deshacer |
| Squatting del par | El par nace bloqueado en el deploy (Ãºnico que puede seedear es el launcher whitelisted) |
| Quote identity fork | `add_quote` rechaza gateway-paired FAs; se guarda la direcciÃ³n AMM-canonical |
| Quotes demasiado baratos (u64) | `add/refresh` aborta con `ERROR_QUOTE_RAISE_EXCEEDS_U64` en vez de truncar |

## Track SUPRA nativa (single-structure)

Los pools con quote = el **FA nativo de red de SUPRA** (`0xA`, creado por el framework en
el genesis como metadata emparejada del Coin nativo) funcionan sin ningÃºn bridge propio:

- **Custodia 1:1 con el resto de quotes** (FungibleStore + contador interno) â no hay
  estructura dual: el launcher es un Ãºnico cÃ³digo FA para todos los quotes.
- **Buy**: si el wallet no tiene suficiente 0xA-FA, el launcher retira SUPRA nativa
  (`coin::withdraw<SupraCoin>` â el framework mezcla CoinStore + store 0xA del wallet) y la
  convierte con `coin::coin_to_fungible_asset` (pÃºblica del framework). El usuario paga SUPRA
  cruda, una sola tx, cero wrappers en su vida.
- **Sell**: el vendedor recibe 0xA-FA â la representaciÃ³n estÃ¡ndar de su balance SUPRA
  (retiros futuros del framework la mezclan de vuelta automÃ¡ticamente).
- **Par**: creado en la identidad de trading del AMM `(token, bwsup)` vÃ­a la rama original
  `is_supra` del gate â mientras la custodia de curva vive en 0xA.
- **MigraciÃ³n**: vÃ­a `add_liquidity_from_launchpad_fa_beta` (pÃºblica): canonicaliza 0xAâbwsup
  â resuelve el par â el `smart_withdraw` del router cae al fallback nativo â que con el
  withdraw-mixto del framework recoge el 0xA-FA depositado en el resource store y lo envuelve.
  El gauge se activa sobre el pool `(token, bwsup)` (`seeded_pool` explÃ­cito).
- El pivote del SUPRA quote es **trivial** (1 SUPRA = SUPRA_RAW_PER_WHOLE): ni orÃ¡culo se usa.

## Ruta futura: compras multi-token (Aggregator)

Contrato independiente (sugerido: `smart_contract/quote_agg/`) que compone:

```
usuario tiene X â AMM swap (amm_router) X â quote_del_pool â hoglet_core::buy_tokens
```

Sin tocar v3: el atacante/agente simplemente garantiza quote pasada a la curva. Puede
ser entry Ãºnico (swap+buy atÃ³mico) o dos txs con el router ya existente.

---

## SCOPE FINAL de quotes v1 (fresado al cierre)

| Clase de quote | Soporte | MecÃ¡nica |
|---|---|---|
| **SUPRA nativa** (Coin legacy de la red) | â tratamiento nativo completo | custodia = `0xA` (la FA nativa de la red, creada por el framework en el genesis); buy con `coin::withdraw` mixto + `coin_to_fungible_asset` pÃºblica; payout en `0xA`-FA (balance SUPRA estÃ¡ndar-framework); par en `(token, bwsup)`; migraciÃ³n por `fa_beta` (canonicaliza 0xAâbwsup; el `smart_withdraw` fallback con el mixed-withdraw del framework recoge la custodia). Pivote trivial (sin orÃ¡culo). |
| **Todo FA puro** (BTC-FA, PEPE-FA, iassets iSUPRA/iWBTC/iETH, wrappers existentesâ¦) | â ilimitado vÃ­a whitelist | track FA-genÃ©rico cero-cÃ³digo-por-token; pivote via snapshot TWAP al registrar |
| **FA-parejadas de coins legacy sin wrapper estable** | â excluidas DELIBERADAMENTE | la validaciÃ³n del whitelist (`paired_coin` check) las rechaza por construcciÃ³n |

Supra es el Ãºnico coin legacy real relevante â **su identidad AMM (bwsup) existe desde la
genesis del AMM** â el canÃ³nico es estable para siempre (no-flip por orden de resoluciÃ³n:
wrapper-check primero).

## EXTENSIÃN FUTURA: coin legacy sin FA propia (patrÃ³n documentado)Si algÃºn dÃ­a se quisiera soportar un coin legacy arbitrario (que hoy es inviable):

1. **Wrapper-first**: crear su wrapper en el AMM oficialmente (fecha-1, identidad
   determinÃ­stica estilo bwsup â evita el FLIP adversarial del canÃ³nico: verificado que
   `get_canonical_address` se reordena a wrapper si existe (`is_wrapper` primero), y que la
   creaciÃ³n del wrapper es lazy en operaciones rutinarias (router.move:753) â un paired-FA
   sin wrapper puede flippear adversarialmente y hacer huÃ©rfanos los pares).
2. **Whitelist**: guardar la direcciÃ³n del wrapper (NO la paired-FA).
3. **1 helper permissionado en el AMM** (genÃ©rico): `wrap/unwrap_for_launchpad<CoinType>`
   assertion `is_whitelisted(launcher)` âè½¬å nativoâwrapper para buy/sell del launcher.
4. Custody = wrapper-FA â **cero cambios en Pool, cero ramas duales** â el launcher sigue
   siendo un solo cÃ³digo FA. Los typeargs los alimenta el frontend por-quote.

---

## BUFFER ROUTE (V3-BUFFER-ROUTE  opt-in admin)

Los pools cuyo quote es SUPRA-nativa pueden migrar sembrando liquidez **iSUPRA**
(ruta buffer) cuando el admin la habilita (`set_buffer_target(iSUPRA, true)`):

- **Deploy**: se pre-crean DOS pares bloqueados  `(token, bwsup)` (identidad de
  trading) y `(token, iSUPRA)` (destino de siembra PoEL)  y AMBOS pools nacen
  como gauges del DAO-track (`amm_pool_addresses` con 2 entries, inactivos hasta
  la siembra - paridad v2). [AUDIT V3-9: sin esto, `activate_seeded_gauge`
  abortaba GAUGE_NOT_FOUND en la ruta buffer para tokens DAO]
- **Migracin**: la ruta se resuelve TEMPRANO (determinstica, antes del
  `mint_and_distribute_rewards` para que la exención de taxes del smart token y
  la activación de gauge sean consistentes con el pool sembrado).
  Precondiciones TODAS upfront: launcher whitelisted en el buffer, buffer no
  pausado, stock >= recolectado, target != 0x0. Cualquier falla -> fallback
  fail-open a la siembra bwsup canonica (corrige el defecto v2 que solo
  verificaba stock - AUDIT_REPORT:128).
- **Rate guard [AUDIT V3-10]**: el exchange del buffer debe devolver al menos
  `(10000 - slippage_bps)/10000` del 1:1 SUPRA esperado  si no, la tx aborta
  (`ERROR_BUFFER_RATE_DEGRADED`): fondos seguros, migrador reintenta.
  Sin esto un seed subrespaldado seria drenado por arbitraje en el 1er bloque.
- Conversion custodia->SUPRA nativa: via `coin::withdraw<SupraCoin>` (el
  withdraw mixto publico del framework: CoinStore + store 0xA-FA).
- Custodia default OFF: sin `is_buffer_enabled`, todo queda en el track
  canonico bwsup sin dependencias externas.


---

# ADDENDUM AUDIT13 (remediation record)

## Applied fixes
- **#1 (inject_rebase / inject_rewards)**: las inyecciones de rebase/rewards
  ahora rutean por el CAP del DAO (`tax_router::deposit_tax_free(dao,
  &ledger::generate_signer(dao), store, fa)`) en vez del deposit dispatchable
  crudo. Cierra el desincronismo acumulador-vs-store (DoS de compound) cuando
  el DAO enciende taxes sobre su PROPIO token, y corrige la exencion
  inefectiva (el hook compara `object::owner(store)`, no la direccion del
  store object). El signer maestro del DAO es router whitelisted (FIX
  audit13 R-1).
- **#2 (curva pre/post-tax)**: `buy_tokens` y `swap_quote_for_exact_tokens`
  derivan TODO el math (fees, pool input, tokens a mintear, eventos) del FA
  RECIBIDO post-hooks (`fungible_asset::amount`). Sin taxes activos la
  matematica es bit-identica a la anterior. Con taxes activos el usuario
  recibe la curva honrada de lo que aterrizo (sin sobre-emision de supply).
- **#4 (revoca)**: `tax_router::remove_router(dao_signer, addr)` — solo el
  signer maestro del DAO; `dao_address` (el master) no puede removese a si
  mismo (`E_ROUTER_MASTER_UNREMOVABLE`) porque los modulos internos del DAO
  dependen de el. `add_router` post-removal permitido (rotacion).
- **#8 (charter floors)**: `validate_config_value` key==2 re-aplica los pisos
  de quorum (>=1% y >=50%) contra el NUEVO denominador — la gobernanza no
  puede degradarse por debajo de los valores de nacimiento.

## Documented (accepted-by-design)
- **#3 (bootstrap intencional)**: `hoglet_genesis` NO hace handover del admin
  de la fabrica (`petra::transfer_admin` comentado a proposito mientras se
  parchen los contratos) y el supply inicial de HOG (13.7T @ 3 dec) queda en
  el deployer. Riesgo de centralizacion DECLARADO hasta sunset — decision de
  negocio, pendiente de ejecutar el Ouroboros cuando el suite se congele.
- **#5 (hodl_fa emergency)**: remediacion DEFERIDA — hodl_fa pasa a escala DAO
  (la gobernanza puede separar emergency/treasury admin via
  `transfer_emergency_admin`); el `withdraw_to_treasury` en emergencia queda
  sin grace POR DISENO.
- **#6 (MintRef externo)**: riesgo estructural de Move — un ConstructorRef
  puede producir refs ocultos que el contrato no puede auditar. Checks
  off-chain en el pipeline de listing para DAOs comunitarios externos.
- **Invariantes tax_router (R-1/R-2)**: (a) `router == dao_address` esta EXENTO
  del owner-check — NINGUN modulo friend nuevo puede pasarle una store
  controlada por el caller; (b) el launcher (`pump_v3`) solo anade su pool via
  `petra::add_tax_router` (`assert_launcher_of_dao`); (c) los routers son
  revocables por el DAO master (`remove_router`).
- **Donaciones al quote_store**: quedan congeladas por el diseno
  anti-donacion (AUDIT-V3-4) — documentado, no bug.
- **coin_legacy_router @0x1**: fallback inalcanzable (codigo muerto,
  inofensivo).
- **foundry reward_rate**: truncation a 0 para montos < duration — conocido,
  aceptado (mantener min-amount por config).
- **deploy fallback**: `coin::deposit(@hoglet_core, ...)` requiere CoinStore
  del modulo registrado; se garantiza en el bootstrap del modulo.

