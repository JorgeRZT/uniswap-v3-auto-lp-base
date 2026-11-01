# Especificación técnica — Automated Uniswap V3 Liquidity Manager en Base

**Documento para Claude Code**  
**Versión:** 0.1 — MVP  
**Fecha:** 1 de noviembre de 2026  
**Estado:** Especificación inicial; no apta para desplegar capital real sin revisión, pruebas y auditoría.

---

## 1. Objetivo

Desarrollar un sistema automatizado para gestionar una posición de **liquidez concentrada de Uniswap V3 en Base**, inicialmente sobre el par **WETH/USDC**.

La lógica de decisión y ejecución debe residir principalmente en Solidity. Un proceso externo muy ligero, escrito en TypeScript, actuará como *keeper*: comprobará periódicamente si hay trabajo que hacer y enviará una transacción únicamente cuando el contrato indique que procede.

El objetivo no es maximizar el APR anunciado por una pool, sino investigar y optimizar la **rentabilidad neta** después de comisiones, impermanent loss, swaps, gas y periodos fuera de rango.

### Principio de diseño

- El contrato es la autoridad sobre el estado, las reglas, los límites y la ejecución.
- El keeper no calcula precios, rangos ni decisiones estratégicas.
- El keeper no debe poder imponer parámetros arbitrarios ni retirar fondos por su cuenta.
- Las llamadas de lectura (`eth_call`) no deben generar transacciones.
- Solo se envía una transacción cuando una evaluación on-chain indica que existe una acción ejecutable.

---

## 2. Alcance del MVP

### Incluido

1. Una única posición gestionada por el contrato.
2. Una única pool Uniswap V3 en Base.
3. Par inicial: WETH/USDC.
4. Fee tier configurable, inicialmente configurable entre `500` (0,05 %) y `3000` (0,30 %), siempre verificando que la pool existe.
5. Gestión de la posición NFT mediante `NonfungiblePositionManager`.
6. Lectura on-chain del precio y del estado de la posición.
7. Cálculo on-chain de un rango objetivo simétrico alrededor del precio de referencia.
8. Evaluación de cuándo conviene rebalancear.
9. Retirada de liquidez, recogida de comisiones, swaps necesarios y creación de una nueva posición.
10. Controles de slippage, desviación de precio, frecuencia y límites de ejecución.
11. Eventos para reconstruir el historial de operaciones.
12. Tests unitarios, tests de integración y tests en fork de Base.

### Fuera del MVP

- Gestión simultánea de varias pools o posiciones.
- Selección automática de pools.
- Yield farming o incentivos externos.
- Préstamos, apalancamiento o flash loans.
- Predicción de precios mediante modelos externos.
- Gestión de activos distintos de WETH/USDC.
- Estrategias direccionales complejas.
- Recompounding automático independiente del rebalanceo, salvo que se añada como fase posterior.
- Interfaz web completa.

No ampliar el alcance sin documentar primero el cambio y sus implicaciones de seguridad.

---

## 3. Red y protocolos

### Red

- Blockchain: Base Mainnet.
- Chain ID: `8453`.
- Red de desarrollo: Base Sepolia, además de Anvil/Hardhat local cuando proceda.

### Integración Uniswap

Usar Uniswap V3, no Uniswap V2 ni Uniswap V4.

Componentes esperados:

- `IUniswapV3Factory`: validar y localizar la pool.
- `IUniswapV3Pool`: consultar `slot0`, `liquidity`, `observe` y parámetros de la pool.
- `INonfungiblePositionManager`: crear, consultar, aumentar, disminuir y cerrar posiciones NFT; recoger tokens.
- Router de swaps compatible con la infraestructura desplegada en Base, con interfaces oficiales y direcciones verificadas.

**Importante:** no asumir ni inventar direcciones de contratos. Antes de implementar, consultar la documentación oficial vigente de Uniswap y Base, verificar las direcciones para Base Mainnet y Base Sepolia y añadirlas a un archivo de configuración claramente identificado. Documentar la fuente y fecha de verificación.

Documentación de referencia:

- Uniswap Developers: https://developers.uniswap.org/
- Uniswap V3 Core: https://github.com/Uniswap/v3-core
- Uniswap V3 Periphery: https://github.com/Uniswap/v3-periphery
- Base: https://docs.base.org/

No copiar direcciones de blogs, tutoriales antiguos ni repositorios sin verificar.

---

## 4. Arquitectura propuesta

### 4.1 Smart contracts

Mantener una separación modular, evitando fragmentar innecesariamente el sistema en muchos contratos desplegables.

#### `LiquidityManager.sol`

Contrato principal y punto de entrada.

Responsabilidades:

- Mantener la configuración de la estrategia.
- Mantener la referencia a la posición NFT gestionada.
- Exponer `checkUpkeep()` o una función equivalente de solo lectura.
- Exponer `executeStrategy()` para ejecutar una acción si las condiciones siguen siendo válidas.
- Coordinar análisis, cálculo de rango, swaps y gestión de la posición.
- Aplicar permisos, pausas y límites.
- Emitir eventos completos.

#### `StrategyEngine.sol` o librería equivalente

Responsabilidades:

- Calcular el rango objetivo.
- Evaluar la distancia a los límites.
- Aplicar umbrales de rebalanceo.
- Determinar si el rebalanceo supera los criterios mínimos de conveniencia.
- No depender de datos que no estén disponibles on-chain.

#### `PoolAnalyzer.sol` o librería equivalente

Responsabilidades:

- Leer el estado de la pool.
- Obtener precio spot y TWAP.
- Calcular ticks y convertir entre precio y tick.
- Comprobar la antigüedad y validez de las observaciones.
- Detectar desviaciones anómalas entre spot y TWAP.

#### `PositionManager.sol` o módulo equivalente

Responsabilidades:

- Consultar la posición NFT.
- Retirar liquidez.
- Recoger tokens y comisiones.
- Crear una nueva posición.
- Gestionar approvals de forma segura y limitada.

#### `SwapManager.sol` o módulo equivalente

Responsabilidades:

- Ejecutar swaps necesarios para aproximar la proporción de tokens requerida por el nuevo rango.
- Aplicar límites de slippage y precio mínimo/máximo.
- No utilizar rutas arbitrarias suministradas por un keeper sin validación.

Si una separación en contratos aumenta la superficie de ataque o el coste de gas sin aportar claridad, utilizar librerías internas o módulos dentro del contrato principal.

### 4.2 Keeper TypeScript

Proceso externo mínimo:

1. Cada 30 segundos (configurable), llamar mediante `eth_call` a `checkUpkeep()` o función equivalente.
2. Si la respuesta indica `upkeepNeeded == false`, no hacer nada.
3. Si indica que existe una acción, enviar una transacción a `executeStrategy()`.
4. Esperar confirmación y registrar hash, bloque, gas utilizado, resultado y eventos.
5. Aplicar reintentos limitados ante errores transitorios.
6. Evitar transacciones concurrentes.
7. Alertar si el contrato permanece pausado, falla repetidamente o no puede ejecutarse.

El keeper no debe tener permiso para cambiar el rango, el slippage, los límites de capital ni las direcciones de tokens. La autorización para llamar a `executeStrategy()` puede ser pública o estar restringida a una lista de keepers; documentar la decisión y sus consecuencias.

**No enviar una transacción cada 30 segundos por defecto.** Las lecturas periódicas son gratuitas para el contrato (aunque el proveedor RPC puede aplicar límites); las transacciones solo se envían cuando sean necesarias.

---

## 5. Configuración inicial de la estrategia

Todos los parámetros deben ser configurables por el administrador, sujetos a límites de seguridad.

| Parámetro | Valor inicial propuesto | Notas |
|---|---:|---|
| Red | Base Mainnet | Chain ID 8453 |
| Par | WETH/USDC | Validar direcciones y decimales |
| Fee tier | 3000 | 0,30 %; comparar también 500 |
| Rango inicial | ±15 % | Hipótesis inicial, no óptimo demostrado |
| Umbral de evaluación | 70 % del recorrido hacia un límite | Solo empieza a evaluar |
| Umbral de rebalanceo | 85 % del recorrido hacia un límite | No obliga a ejecutar si no es rentable |
| Intervalo del keeper | 30 segundos | Solo lecturas periódicas |
| TWAP inicial | 1 hora | Configurable; requiere observaciones suficientes |
| Desviación spot/TWAP máxima | Configurable | Si se supera, no operar |
| Slippage máximo inicial | 0,5 % | Límite estricto, no objetivo |
| Cooldown entre rebalanceos | Configurable | Evita operaciones repetidas |
| Máximo de rebalanceos | Configurable por ventana temporal | Protección frente a bucles |
| Reinversión de fees | No automática en la primera iteración | Recoger y contabilizar por separado |

Los valores son parámetros de partida para pruebas, no recomendaciones financieras ni garantías de rentabilidad.

### Rango de precios

El rango inicial se calcula alrededor del precio de referencia:

- `lowerPrice = referencePrice * (1 - rangePercent)`
- `upperPrice = referencePrice * (1 + rangePercent)`

Después debe convertirse correctamente a `tickLower` y `tickUpper`, respetando:

- `tickSpacing` de la pool.
- Orden de ticks.
- Límites `MIN_TICK` y `MAX_TICK`.
- Convenciones de token0/token1.
- Decimales de WETH y USDC.
- Orientación del precio según el orden real de los tokens.

No asumir que WETH es siempre `token0` o que USDC es siempre `token1`. Consultar la pool y calcular correctamente la orientación.

La implementación debe incluir tests específicos para evitar errores de escala, decimales y precio invertido.

---

## 6. Precio, TWAP y protección contra manipulación

No utilizar exclusivamente el precio spot (`slot0`) para decidir una operación.

### Requisitos

1. Leer `slot0` para obtener el precio spot y tick actuales.
2. Consultar `observe()` para calcular un TWAP con una ventana configurable.
3. Comprobar que la pool dispone de observaciones suficientes.
4. Manejar correctamente el redondeo del tick medio, especialmente para valores negativos.
5. Calcular la desviación entre spot y TWAP.
6. Si la desviación supera el límite configurado, bloquear la ejecución y emitir un evento o devolver un motivo legible.
7. Revalidar precio, TWAP y condiciones dentro de la misma transacción que ejecuta el rebalanceo.

No considerar el TWAP una protección absoluta: una pool puede tener poca liquidez, una ventana insuficiente o estar expuesta a manipulación. La estrategia debe poder pausarse si los datos no son fiables.

---

## 7. Lógica de decisión y rebalanceo

### 7.1 Estados posibles

Definir estados explícitos, por ejemplo:

- `UNINITIALIZED`: aún no existe una posición.
- `IN_RANGE`: precio dentro del rango y sin necesidad de actuar.
- `EVALUATION_ZONE`: precio ha alcanzado el umbral de evaluación.
- `REBALANCE_REQUIRED`: se cumplen las condiciones para considerar un rebalanceo.
- `PAUSED`: operaciones deshabilitadas.
- `ERROR/INVALID_ORACLE`: datos insuficientes o no fiables.

La función de lectura debe devolver un motivo de decisión legible, no solo un booleano.

### 7.2 Umbral relativo

Calcular qué proporción del recorrido hacia el límite más cercano ha recorrido el precio. No comparar únicamente una distancia porcentual fija al precio actual.

Al alcanzar el umbral de evaluación, el contrato debe analizar:

- Precio spot y TWAP.
- Rango actual y rango objetivo.
- Tiempo desde el último rebalanceo.
- Número de rebalanceos en la ventana temporal.
- Coste estimado de gas y swaps, cuando sea posible.
- Valor aproximado de la posición.
- Slippage esperado.
- Si el precio sigue dentro del rango.

El 85 % es un umbral inicial de prueba. El contrato no debe rebalancear automáticamente solo por alcanzarlo.

### 7.3 Criterio económico

No ejecutar un rebalanceo si el beneficio esperado no supera un umbral configurable que cubra:

- Gas de retirada y creación de posición.
- Costes de swap.
- Slippage.
- Riesgo de ejecución.
- Margen de seguridad adicional.

No asumir que Solidity puede conocer con precisión el coste futuro total de una operación. El keeper puede estimar el gas para decidir si merece la pena enviar la transacción, pero esa estimación no debe poder alterar las reglas de seguridad on-chain.

Para el MVP, si no existe una estimación on-chain suficientemente fiable del beneficio esperado, utilizar un criterio conservador y documentar claramente sus limitaciones. No inventar una fórmula de rentabilidad que confunda comisiones históricas con comisiones futuras.

### 7.4 Ejecución atómica

Cuando se ejecuta un rebalanceo, el flujo esperado es:

1. Validar permisos y estado de pausa.
2. Comprobar cooldown y límite de operaciones.
3. Revalidar pool, posición, precio spot y TWAP.
4. Comprobar que la acción sigue siendo necesaria.
5. Disminuir la liquidez de la posición actual.
6. Recoger los tokens y las comisiones pendientes.
7. Determinar los saldos disponibles.
8. Calcular el nuevo rango y la proporción de tokens necesaria.
9. Ejecutar los swaps imprescindibles, respetando slippage y límites de precio.
10. Crear la nueva posición NFT.
11. Actualizar el `tokenId` gestionado y los datos de la estrategia.
12. Emitir eventos con los importes, ticks, precio y motivo.

Si un paso falla, la transacción debe revertir completamente, salvo que el diseño documente expresamente una operación no atómica. No dejar fondos en routers ni contratos auxiliares.

**No cerrar ni recrear una posición en cada evaluación.** La evaluación puede producirse cada 30 segundos, pero la ejecución debe ser excepcional y estar protegida por umbrales y cooldown.

---

## 8. Gestión de tokens, swaps y posición NFT

### Posición

La posición de Uniswap V3 es un NFT. El contrato debe:

- Guardar el `tokenId` que gestiona.
- Verificar que el NFT pertenece al contrato.
- Leer `token0`, `token1`, `fee`, `tickLower`, `tickUpper`, `liquidity` y datos de fees.
- Rechazar posiciones que no correspondan a la pool configurada.
- No gestionar NFTs ajenos.

### Swaps

- Utilizar contratos oficiales y direcciones verificadas.
- Establecer `amountOutMinimum` calculado de forma segura.
- Aplicar deadline o mecanismo equivalente de caducidad.
- Restringir tokens y rutas permitidos.
- No permitir que el keeper suministre calldata arbitraria para swaps.
- Revocar approvals cuando ya no sean necesarios o utilizar approvals limitados cuando sea viable.
- Evitar approvals ilimitados por defecto.

### Proporción de tokens

La proporción requerida para una posición depende del precio y de los ticks del rango. Utilizar las librerías matemáticas oficiales de Uniswap V3 (`TickMath`, `LiquidityAmounts` o equivalentes compatibles) y verificar las unidades.

No utilizar cálculos de punto flotante. Solidity debe operar con enteros y escalas explícitas.

---

## 9. Seguridad y controles obligatorios

El contrato controla fondos reales. Estas protecciones son requisitos del MVP, no mejoras opcionales.

### Acceso y administración

- `Ownable2Step` o control de acceso equivalente.
- Preferir una wallet multisig para administración en producción.
- Función `pause()` y `unpause()`.
- Función de emergencia que detenga nuevas operaciones.
- El administrador no debe poder retirar fondos de usuarios si el modelo de custodia no lo contempla.
- Documentar quién puede cambiar cada parámetro.
- Emitir eventos en cada cambio de configuración.

### Protecciones de ejecución

- `ReentrancyGuard` donde corresponda.
- Checks-Effects-Interactions.
- Validación de direcciones no nulas.
- Validación de pool, tokens y fee tier.
- Límites máximos de slippage.
- Límites máximos de desviación spot/TWAP.
- Cooldown entre operaciones.
- Límite de rebalanceos por periodo.
- Protección frente a llamadas concurrentes o reentradas.
- Comprobación de balances antes y después de cada operación.
- No confiar en valores enviados por el keeper sin validarlos on-chain.
- No permitir que una llamada externa cambie el destino de los fondos.

### Recuperación de emergencia

Definir cuidadosamente qué sucede si:

- El router deja de estar disponible.
- La pool tiene datos de oracle insuficientes.
- Un swap falla.
- El contrato se pausa mientras mantiene una posición.
- Hay tokens residuales tras un rebalanceo.
- Se pierde el acceso al keeper.

La pausa debe impedir nuevas operaciones automáticas, pero no bloquear injustificadamente la recuperación segura de los activos por parte del administrador autorizado.

---

## 10. Contabilidad y métricas

El contrato debe emitir suficientes eventos para que el servidor reconstruya el historial sin tener que inferirlo.

Eventos sugeridos:

- `PositionCreated`
- `PositionRebalanced`
- `PositionLiquidityRemoved`
- `FeesCollected`
- `SwapExecuted`
- `StrategyConfigUpdated`
- `StrategyPaused`
- `StrategyUnpaused`
- `ExecutionSkipped`
- `EmergencyAction`

Registrar, cuando corresponda:

- `tokenId` anterior y nuevo.
- Precio spot y TWAP.
- `tickLower` y `tickUpper` anteriores y nuevos.
- Cantidades de token0 y token1 retiradas.
- Fees recogidas.
- Cantidades intercambiadas.
- Cantidades depositadas.
- Slippage efectivo.
- Motivo del rebalanceo.
- Timestamp y bloque.

### Métricas que calculará TypeScript

La contabilidad histórica y los informes pueden mantenerse off-chain. El servidor debe calcular:

- Fees brutas acumuladas.
- Costes de gas.
- Costes de swaps.
- Número de rebalanceos.
- Tiempo dentro/fuera de rango.
- Valor de la posición.
- Valor de los activos si se hubieran mantenido sin aportar liquidez.
- Pérdida o ganancia relativa frente a holding.
- Rentabilidad neta y anualizada.

No presentar una APR como rentabilidad garantizada. Diferenciar claramente:

- APR observada o estimada de la pool.
- Fees realmente obtenidas por la posición.
- Rentabilidad total de la estrategia.
- Resultado frente a holding.
- Resultado neto de costes.

El impermanent loss debe calcularse frente a una referencia explícita de holding con los mismos activos y cantidades iniciales, ajustando depósitos, retiradas y flujos de caja.

---

## 11. Interfaces externas del contrato

Diseñar una interfaz sencilla y estable. Como mínimo:

```solidity
function checkUpkeep()
    external
    view
    returns (
        bool upkeepNeeded,
        uint8 reason,
        int24 currentTick,
        int24 targetTickLower,
        int24 targetTickUpper
    );

function executeStrategy()
    external;

function pause()
    external;

function unpause()
    external;

function updateStrategyConfig(/* parámetros */)
    external
    onlyOwner;

function getStrategyState()
    external
    view
    returns (/* estado estructurado */);
```

La firma definitiva puede cambiar si hay una razón técnica. Documentar los motivos y mantener una interfaz fácil de consumir desde TypeScript.

`checkUpkeep()` debe ser de solo lectura y no modificar estado. Debe devolver un motivo concreto cuando no se recomienda operar, por ejemplo:

- `NO_ACTION`
- `PRICE_NOT_NEAR_BOUNDARY`
- `COOLDOWN_ACTIVE`
- `MAX_REBALANCES_REACHED`
- `SPOT_TWAP_DEVIATION`
- `INSUFFICIENT_ORACLE_DATA`
- `REBALANCE_NOT_ECONOMIC`
- `PAUSED`

Evitar devolver datos ambiguos o depender de mensajes de error como única forma de diagnóstico.

---

## 12. Tests obligatorios

No considerar terminado el contrato hasta que existan tests automatizados.

### Unit tests

- Conversión precio/tick en ambas orientaciones de tokens.
- Decimales de WETH y USDC.
- Cálculo de rango y alineación a `tickSpacing`.
- Límites de ticks.
- Cálculo del porcentaje recorrido hacia un límite.
- Umbrales de evaluación y rebalanceo.
- Cooldown.
- Límite de rebalanceos.
- Desviación spot/TWAP.
- Datos de oracle insuficientes.
- Slippage máximo.
- Validación de pool y fee tier.
- Accesos no autorizados.
- Pausa y reanudación.

### Integration tests

- Crear una posición.
- Leer correctamente su estado.
- Retirar liquidez.
- Recoger fees.
- Ejecutar un swap.
- Crear una nueva posición.
- Rebalanceo completo.
- Reversión completa si falla cualquier etapa.
- Gestión de saldos residuales.
- Comportamiento cuando el precio sale del rango.

### Fork tests de Base

Usar un fork de Base Mainnet con bloque fijado para reproducibilidad.

- Interactuar con direcciones reales verificadas.
- Probar las pools disponibles para WETH/USDC y fee tiers seleccionados.
- Probar creación y cierre de posiciones.
- Simular cambios de precio cuando sea posible.
- Medir gas de las operaciones.
- Verificar que no se pueden extraer fondos de forma no autorizada.

### Fuzzing e invariantes

Incluir pruebas fuzz para:

- Precios extremos.
- Ticks extremos.
- Cantidades muy pequeñas y muy grandes.
- Redondeos.
- Secuencias repetidas de rebalanceo.
- Reentradas y fallos de integraciones.

Invariantes mínimas:

1. El contrato nunca debe gastar tokens por encima de sus balances y allowances disponibles.
2. El keeper no puede cambiar los parámetros protegidos.
3. El contrato no debe operar con una pool distinta de la configurada.
4. Una ejecución fallida no debe dejar una posición parcialmente modificada.
5. La posición gestionada debe pertenecer al contrato.
6. Si la estrategia está pausada, no se debe producir un rebalanceo automático.

---

## 13. Desarrollo y herramientas

Elegir una pila moderna y compatible, justificando versiones:

- Solidity.
- Foundry para compilación, tests, fuzzing y fork tests.
- OpenZeppelin para componentes de seguridad.
- TypeScript para keeper y monitorización.
- Viem o ethers para interacción RPC.
- Variables de entorno para RPC y claves.
- `.env.example` sin secretos.
- Linter y formatter.
- CI para ejecutar tests en cada cambio.

No incluir claves privadas en el repositorio, logs, imágenes Docker ni archivos de configuración versionados.

El keeper debe poder utilizar una wallet dedicada con fondos limitados para gas. La wallet del keeper no debe ser la wallet propietaria ni tener permisos administrativos innecesarios.

---

## 14. Entregables esperados

Claude Code debe producir:

1. Repositorio organizado y compilable.
2. Contratos Solidity comentados.
3. Interfaces de Uniswap necesarias.
4. Configuración de direcciones por red, con fuentes verificables.
5. Tests unitarios, de integración y fork.
6. Keeper TypeScript funcional.
7. `.env.example`.
8. Scripts de despliegue para Base Sepolia.
9. Script de verificación de configuración y direcciones.
10. README con instalación, tests y ejecución local.
11. Diagrama de arquitectura.
12. Documento de riesgos y limitaciones conocidas.
13. Estimación de gas de las operaciones principales.
14. Instrucciones para pausar el sistema y recuperar los fondos.

No desplegar en Base Mainnet ni mover capital real automáticamente.

---

## 15. Orden de implementación solicitado

Trabajar por fases y no intentar desarrollar todo de una vez.

### Fase 0 — Investigación técnica

Antes de escribir contratos:

- Revisar la documentación oficial actual de Uniswap V3 y Base.
- Verificar direcciones oficiales de contratos.
- Identificar las pools WETH/USDC disponibles en Base y sus fee tiers.
- Confirmar la compatibilidad de los routers y del `NonfungiblePositionManager`.
- Documentar las decisiones y posibles incompatibilidades.

No asumir que una dirección o integración de Ethereum Mainnet es válida en Base.

### Fase 1 — Análisis de pool y estrategia

Implementar solo:

- Lectura de pool.
- Precio spot y TWAP.
- Lectura de posición NFT.
- Cálculo de ticks y rango objetivo.
- `checkUpkeep()`.
- Tests matemáticos y de lectura.

Todavía no permitir swaps ni rebalanceos.

### Fase 2 — Gestión de posición

Implementar:

- Crear posición.
- Retirar liquidez.
- Recoger fees.
- Validar propiedad y configuración del NFT.
- Tests de integración y fork.

### Fase 3 — Rebalanceo atómico

Implementar:

- Cálculo de cantidades.
- Swaps limitados.
- Slippage.
- Creación de nueva posición.
- Cooldown y límites de frecuencia.
- Tests de reversión y seguridad.

### Fase 4 — Keeper y observabilidad

Implementar:

- Polling cada 30 segundos.
- Lecturas mediante `eth_call`.
- Envío de transacciones solo cuando proceda.
- Gestión de nonce, reintentos y concurrencia.
- Logs, métricas y alertas.

### Fase 5 — Pruebas controladas

- Ejecutar en Base Sepolia cuando las integraciones lo permitan.
- Ejecutar fork tests de Base Mainnet.
- Revisar gas y comportamiento ante volatilidad.
- Realizar pruebas con cantidades pequeñas en un entorno controlado.
- Someter el contrato a revisión independiente antes de considerar capital significativo.

---

## 16. Decisiones que Claude Code NO debe tomar por su cuenta

Si una decisión afecta a la seguridad o cambia la estrategia, documentarla y solicitar confirmación antes de implementarla.

En particular:

- No cambiar WETH/USDC por otro par.
- No cambiar el fee tier por defecto sin explicar el motivo.
- No convertir el rango dinámico en una estrategia predictiva.
- No añadir leverage, lending o flash loans.
- No habilitar retiros administrativos arbitrarios.
- No permitir swaps con rutas o calldata sin validar.
- No desplegar en Mainnet.
- No asumir que un APR observado representa el rendimiento esperado.
- No tratar el umbral del 85 % o el rango ±15 % como valores óptimos demostrados.

---

## 17. Criterio de aceptación del MVP

El MVP se considera técnicamente completo cuando:

- El contrato identifica y valida la pool configurada.
- Lee correctamente precio, TWAP y posición.
- Calcula rangos y ticks correctamente.
- Informa al keeper cuándo existe una acción necesaria.
- No envía operaciones cuando no se cumplen las condiciones.
- Puede retirar, recoger fees, intercambiar tokens y crear una nueva posición de forma atómica.
- Aplica límites de slippage, desviación, frecuencia y permisos.
- Pasa los tests unitarios, integración, fork y fuzz definidos.
- El keeper solo realiza lecturas periódicas y envía transacciones bajo demanda.
- Existe documentación suficiente para desplegar primero en testnet y detener el sistema de emergencia.

**Prioridad absoluta: seguridad de los fondos y corrección matemática. La rentabilidad y la optimización del APR son objetivos posteriores.**
