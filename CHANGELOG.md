# Changelog

## v12 — Costeo de Margen Point-in-Time (Nov 2026)

Cierra la última limitación documentada del Data Warehouse: desde v8, `dw.sp_cargar_dw_fact_margen_venta` ya resolvía `sk_item` point-in-time (la versión de `dim_item` vigente al momento de la venta), pero la fórmula de `costo_directo` seguía ramificando por `ps.modo_obtencion` — el modo de obtención **actual** del ítem en `dbo.tbl_productos_servicios`, no el histórico. Si un ítem cambiaba de modo de obtención después de ventas ya costeadas, un refresh del DW recosteaba esas ventas antiguas con la fórmula del modo **actual** en vez de la vigente cuando ocurrieron.

### Diseño

No se necesitó ningún cambio de esquema ni de `dw.sp_cargar_dw_dimensiones`: `dim_item` ya historiza `modo_obtencion` desde v8 (es, de hecho, el caso motivador explícito de la historización) y el JOIN con point-in-time hacia `di` ya existía en ambas SP de carga del hecho. El único cambio es **qué columna lee la fórmula**: la decisión de la rama (`COMPRADO_REVENTA` / `FABRICADO`/`SERVICIO`) y la columna `modo_obtencion` almacenada en el hecho pasan de `ps.modo_obtencion` (actual, OLTP) a `di.modo_obtencion` (point-in-time, ya resuelto por el JOIN con `dim_item` que usa `fecha_inicio_vigencia <= fecha_emision AND (fecha_fin_vigencia IS NULL OR fecha_emision < fecha_fin_vigencia)`).

### Cambios

1. **`dw.sp_cargar_dw_fact_margen_venta`** / **`dw.sp_cargar_dw_fact_margen_venta_incremental`**: las 3 referencias a `ps.modo_obtencion` (columna `modo_obtencion` del INSERT, y las 2 ramas del `CASE` de `costo_directo`) cambian a `di.modo_obtencion`. `ps` (`dbo.tbl_productos_servicios`) se mantiene en el `JOIN` solo como verificación de existencia del ítem en el OLTP; ya no se lee ninguna de sus columnas.

### Consecuencia

2. La columna `modo_obtencion` de `dw.fact_margen_venta` ahora es, igual que `sk_item`, consistentemente point-in-time: un refresh del DW (completo o incremental) nunca vuelve a recostear una venta histórica con la fórmula de un modo de obtención que el ítem adoptó **después** de esa venta.

## v11 — Asiento Automático para Traspasos de Caja (Nov 2026)

Cierra la limitación documentada desde v3: los movimientos de caja `TRASPASO_HASTA`/`TRASPASO_DESDE` se cargaban al Core pero no generaban asiento automático, porque un traspaso real involucra **dos filas separadas** del Excel (origen y destino, cada una con su propia cuenta bancaria) que deben conciliarse antes de poder armar un asiento de 2 líneas correcto — a diferencia de `INGRESO`/`EGRESO`, que son autocontenidos en una sola fila.

### Diseño

**Regla de negocio explícita (requisito operativo nuevo):** para que un traspaso se concilie automáticamente, ambas filas del Excel (la `TRASPASO_DESDE` y la `TRASPASO_HASTA`) deben compartir exactamente la misma `fecha_movimiento`, el mismo `monto_absoluto` y la misma `glosa_movimiento` — es la única correlación disponible sin agregar una columna nueva al Excel (p. ej. un "ID de traspaso"), y es una convención razonable de captura (quien registra un traspaso en ambas filas normalmente escribe la misma descripción para las dos).

**Emparejamiento sin ambigüedad:** dentro del mismo lote recién cargado, se agrupan las filas `TRASPASO_DESDE` y las `TRASPASO_HASTA` por `(fecha_movimiento, monto_absoluto, glosa_movimiento)` usando `COUNT(*) OVER (PARTITION BY ...)`. Solo se empareja un `TRASPASO_DESDE` con un `TRASPASO_HASTA` cuando **ambos lados tienen exactamente 1 candidato** con esa combinación — si hay 0 o 2+ candidatos de cualquiera de los dos lados (por ejemplo, dos traspasos distintos el mismo día por el mismo monto con la misma glosa), el emparejamiento es ambiguo y el par queda **sin asiento automático**, exactamente como antes de v11 (se informa por `PRINT` y se registra manualmente).

### Cambios

1. **`sql/sp_procesar_etl_fase3.sql`** (sección 4.3c, nueva): tras el ciclo existente que genera asientos de `INGRESO`/`EGRESO`, se agrega un paso que empareja `TRASPASO_DESDE` con `TRASPASO_HASTA` del lote (CTEs `desde`/`hasta` con `COUNT(*) OVER (PARTITION BY ...)`, tabla `@traspasos_pareados`) y, por cada par emparejado sin ambigüedad, genera un asiento de 2 líneas: **Debe** la cuenta bancaria de destino (`TRASPASO_HASTA`) / **Haber** la cuenta bancaria de origen (`TRASPASO_DESDE`), cada línea con el centro de costo de su propia fila. Los pares no emparejados se informan por `PRINT` para registro manual.
2. **`sp_procesar_transaccion_externa.sql`** no se modifica: esa SP no procesa `tbl_movimientos_caja` (es exclusiva del flujo de ventas), así que la limitación de traspasos solo aplicaba al motor ETL de Fase 3.

### Limitación que permanece (v11)

3. El emparejamiento depende de que ambas filas de un mismo traspaso compartan **exactamente** la misma glosa (coincidencia de texto exacta, no homologada). Si el Excel registra la misma operación con glosas distintas en cada fila (p. ej. "Traspaso a Caja Chica" vs. "Recepción desde Banco Principal"), el emparejamiento automático no ocurre y el traspaso queda para asiento manual — se documenta como convención operativa requerida, no como un defecto a corregir en esta fase.

## v10 — CIF sobre Costo Real de Kardex (Nov 2026)

Cierra la limitación documentada desde v6 (sección "Limitación que permanece", ítem 8): `sp_prorratear_cif_periodo` prorrateaba el CIF del periodo usando como base el costo **estándar** (BOM) de MOD+MPD de cada venta `FABRICADO`, aunque desde v7 la MPD ya se consume y se contabiliza a su costo **real** de kardex — una divergencia menor entre la base de absorción de CIF y el costo real ya registrado para esa misma MPD.

### Diseño

La base de prorrateo pasa a ser: **MOD a costo estándar** (sin cambios — la mano de obra no pasa por kardex, no existe una fuente "real" distinta de la tarifa de referencia) **+ MPD a costo real** ya consumido del kardex de insumos (misma fuente que usa `dw.sp_cargar_dw_fact_margen_venta` desde v7 para `costo_directo`: `SUM(costo_unitario_movimiento * cantidad)` de las salidas de `dbo.tbl_movimientos_inventario` asociadas a esa venta). No se tocó la cuenta ni el mecanismo de prorrateo (tasa = CIF pendiente / base total, aplicada línea a línea) — solo la fórmula de la base.

### Cambios

1. **`sql/sp_prorratear_cif_periodo.sql`**: tanto el cálculo de `@base_total` (SELECT agregado) como el cursor `cur_lineas` (prorrateo línea a línea) cambian la porción MPD de `ISNULL((SELECT SUM(ci.cantidad * ir.costo_unitario_referencia) FROM tbl_item_composicion_insumos ci JOIN cat_insumos_recursos ir ...), 0)` (costo estándar BOM) a `ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad) FROM tbl_movimientos_inventario mi WHERE ... AND mi.id_referencia = vv.id_venta_devengada AND mi.id_insumo IN (...)), 0)` (costo real de kardex) — idéntica fórmula en ambos lugares para que la tasa de prorrateo y el prorrateo línea a línea usen la misma base.

### Consecuencia operativa

2. Si se ejecuta `sp_prorratear_cif_periodo` para un periodo en que las compras de insumos todavía no se registraron (o el kardex no tiene saldo suficiente para alguna línea FABRICADO), la base de esa línea puede ser menor a la que tendría con costo estándar — esto es consistente con la limitación ya documentada en v7 (una venta `FABRICADO`/`SERVICIO` falla con "stock insuficiente" si no se compraron antes los insumos), así que no introduce un caso nuevo, solo hereda esa misma precondición operativa.

### Limitación que permanece

3. Igual que antes de v10: si una misma venta tiene 2+ líneas `FABRICADO` que comparten un mismo insumo en su BOM, el costo real de ese insumo se atribuye a ambas líneas sin discriminar cuál consumió cuánto (limitación de atribución de v7, heredada aquí sin cambios).

## v9 — Carga Incremental del Data Warehouse (Nov 2026)

Cierra la última limitación documentada del DW: desde su primera versión, `dw.sp_cargar_dw_completo` hacía `DELETE` + reconstrucción total de ambos hechos (`fact_asientos_contables`, `fact_margen_venta`) en cada ejecución — correcto pero cada vez más costoso a medida que crece el histórico, ya que vuelve a leer y recalcular *todo* el OLTP aunque solo haya un puñado de asientos/ventas nuevas desde la última carga.

### Diseño

**Verificación previa**: se confirmó por revisión de todo el código (`grep` de `UPDATE` contra `tbl_asientos_detalle` y `tbl_ventas_detalle` en todos los `.sql`) que ambas tablas son de **solo-inserción** — ninguna corrección contable o comercial se modela editando una fila existente; siempre se registra como un asiento o una venta nueva. Esto habilita una estrategia de **alta marca (high-water mark)** sobre la clave natural, mucho más simple que CDC o comparación por timestamp: basta guardar, por cada hecho, la clave natural máxima ya cargada, y en la siguiente corrida traer solo lo que esté por encima.

Nueva tabla de control **`dw.tbl_control_carga_incremental`** (`nombre_hecho` PK, `ultima_clave_cargada`, `fecha_ultima_carga`) — una fila por tabla de hechos.

### Cambios de esquema

1. **`crear_esquema_dw.sql`**: nueva tabla `dw.tbl_control_carga_incremental`. Se recrea vacía cada vez que se despliega el esquema desde cero (igual que el resto del script), pero nunca se vacía durante la operación normal.

### Motor de carga del DW

2. **`dw.sp_cargar_dw_fact_asientos_contables_incremental`** / **`dw.sp_cargar_dw_fact_margen_venta_incremental`** (nuevas): mismo cálculo línea-a-línea que las versiones completas (incluida la resolución `sk_*` point-in-time de v8 y el costeo real de kardex de v7), pero con un `WHERE id_*_detalle > @ultima_clave_cargada` y sin `DELETE` previo — solo `INSERT` de lo nuevo. Al final, cada una actualiza (o inserta, si es la primera corrida) su fila en `dw.tbl_control_carga_incremental` con `MAX(id_*_detalle)` de `dbo`.
3. **`dw.sp_cargar_dw_fact_asientos_contables`** / **`dw.sp_cargar_dw_fact_margen_venta`** (full-refresh existentes): sin cambios en su lógica de carga; se les agregó la misma sincronización de la tabla de control al final, para que alternar entre carga completa e incremental nunca produzca huecos ni duplicados.
4. **`dw.sp_cargar_dw_incremental`** (nuevo orquestador): corre `dw.sp_cargar_dw_dimensiones` (sin cambios — SCD Tipo 2 ya es incremental por naturaleza), extiende `dim_tiempo` solo para el rango de fechas de las filas *nuevas* de cada hecho (no todo el histórico), y llama a las dos SP incrementales. Mismo patrón `BEGIN TRY/CATCH` + transacción explícita que `dw.sp_cargar_dw_completo`.
5. **`dw.sp_cargar_dw_completo`** (full-refresh existente) se mantiene disponible sin cambios de comportamiento — recomendado para el despliegue inicial (bootstrap, cuando `dw.tbl_control_carga_incremental` todavía no tiene filas) o para forzar una reconstrucción total.

### Limitación que permanece (v9)

6. Este enfoque asume que `dbo.tbl_asientos_detalle` y `dbo.tbl_ventas_detalle` seguirán siendo de solo-inserción. Si en el futuro se corrige una fila histórica directamente en `dbo` con un `UPDATE` o `DELETE` manual (fuera de los flujos transaccionales de este sistema, que nunca hacen esto), la carga incremental **no lo detectará** silenciosamente — el DW quedaría desalineado respecto a `dbo` hasta que se ejecute `dw.sp_cargar_dw_completo` para forzar una reconstrucción total.

## v8 — SCD Tipo 2 en el Data Warehouse (Nov 2026)

Cierra una de las dos limitaciones documentadas que quedaban desde v5 (Fase B): las dimensiones del DW eran Tipo 1 (sobrescritura completa) — "Historización (Tipo 2) queda como mejora futura si se requiere trazar cambios de atributos en el tiempo" (`crear_esquema_dw.sql`, v5). El caso motivador explícito: un ítem puede cambiar de `modo_obtencion` (p. ej. de `COMPRADO_REVENTA` a `FABRICADO`) y, con Tipo 1, el DW perdía la clasificación que tenía *al momento de cada venta histórica*, reescribiéndola retroactivamente con la clasificación actual en cada full refresh.

### Diseño

Se historizan las 5 dimensiones no aditivas (`dim_cuenta_contable`, `dim_centro_costo`, `dim_tercero`, `dim_empleado`, `dim_item`); `dim_tiempo` se deja igual (aditiva, no aplica SCD). Cada una pasa a tener:
- Una **clave surrogada** propia (`sk_*`, `IDENTITY`, PK real) — la clave natural (`id_*`) deja de ser PK y se repite una fila por versión histórica.
- `fecha_inicio_vigencia` / `fecha_fin_vigencia` (`NULL` = vigente) / `es_vigente`, con un índice único filtrado (`WHERE es_vigente = 1`) que garantiza una sola versión vigente por clave natural.

**Mecánica de carga** (`dw.sp_cargar_dw_dimensiones`, reemplaza el `DELETE` + reload de Tipo 1): por cada dimensión, (1) cierra la versión vigente de toda fila cuyos atributos ya no coinciden con el origen (`dbo`), comparando con `EXCEPT` (NULL-safe, evita una cadena larga de `ISNULL(...)<>ISNULL(...)` por columna); (2) inserta una versión nueva para toda clave natural sin versión vigente — ya sea porque es nueva (nace con `fecha_inicio_vigencia = '1900-01-01'`, una fecha "época", para que los hechos históricos ya cargados con fechas pasadas puedan resolverla) o porque su versión vigente se acaba de cerrar en el paso anterior (nace con `fecha_inicio_vigencia = @hoy`, porque es la primera vez que el sistema detecta el cambio — no hay CDC, solo comparación por lote en cada carga).

**Resolución point-in-time en los hechos**: `fact_asientos_contables` y `fact_margen_venta` ahora guardan, para cada dimensión referenciada, tanto la clave natural (`id_*`, degenerada) como la clave surrogada (`sk_*`). La `sk_*` se resuelve en la carga del hecho buscando la versión de la dimensión cuya vigencia (`[fecha_inicio_vigencia, fecha_fin_vigencia)`) cubre la fecha del asiento/venta — no necesariamente la versión vigente hoy. Esto es lo que hace point-in-time correcto un reporte por periodo: si una cuenta o un ítem cambia de clasificación después de una transacción, esa transacción sigue reportando con la clasificación que tenía vigente cuando ocurrió.

### Cambios de esquema

1. **`crear_esquema_dw.sql`**: las 5 dimensiones ganan `sk_*` (PK), `fecha_inicio_vigencia`, `fecha_fin_vigencia`, `es_vigente`, un índice no-único por clave natural + vigencia, y un índice único filtrado por clave natural vigente. Los hechos ganan `sk_cuenta_contable`/`sk_centro_costo` (`fact_asientos_contables`) y `sk_item`/`sk_tercero`/`sk_centro_costo`/`sk_empleado` (`fact_margen_venta`), con FK hacia la `sk_*` de cada dimensión (la FK hacia la clave natural ya no es posible, porque esa columna dejó de ser única por sí sola).

### Motor de carga del DW

2. **`dw.sp_cargar_dw_dimensiones`**: reescrito de cero -- ya NO hace `DELETE` de ninguna dimensión (eso destruiría el historial); versiona cada una con el patrón cerrar-vigente + insertar-nueva descrito arriba.
3. **`dw.sp_cargar_dw_fact_asientos_contables`** / **`dw.sp_cargar_dw_fact_margen_venta`**: ahora resuelven `sk_*` por fecha (`INNER`/`LEFT JOIN` con la condición `fecha_inicio_vigencia <= fecha_transacción AND (fecha_fin_vigencia IS NULL OR fecha_transacción < fecha_fin_vigencia)`), además de seguir guardando la clave natural.
4. **`dw.sp_cargar_dw_completo`**: sin cambios de lógica, solo de comentarios -- el orden (hechos → dimensiones → `dim_tiempo` → hechos) ya era correcto para esta mecánica.

### Vistas de consumo

5. **`dw.vw_dw_balance_general`**: se mantiene como snapshot "a hoy" -- suma el histórico completo de cada cuenta (join por clave natural) pero la muestra con su clasificación **vigente hoy** (`es_vigente = 1`), igual convención que un plan de cuentas reclasificado en un sistema contable real (no se reexpresa retroactivamente el balance acumulado).
6. **`dw.vw_dw_estado_resultados`**, **`dw.vw_dw_estado_resultados_por_centro_costo`**, **`dw.vw_dw_margen_por_item`**: pasan a unir por la clave surrogada (`sk_*`) resuelta point-in-time en la carga del hecho, en vez de por la clave natural -- estos sí son reportes point-in-time correctos.

### Limitaciones que permanecen (decisión explícita)

7. El **cálculo** de `costo_directo` en `dw.sp_cargar_dw_fact_margen_venta` sigue ramificando por el `modo_obtencion` **actual** de `dbo.tbl_productos_servicios` (sin cambios respecto a v7), no por el histórico. Si un ítem cambia de modo de obtención después de ventas ya costeadas y se corre un full refresh, esas ventas se recostean con la fórmula del modo actual, aunque la columna `modo_obtencion` que exponen las vistas de consumo (vía `sk_item`) sí sea point-in-time. Cerrar esto del todo requeriría leer el costo ya posteado en `tbl_asientos_detalle` en vez de recalcularlo -- fuera de alcance de esta fase.
8. Re-ejecutar `dw.sp_cargar_dw_completo` repetidamente es seguro (no se pierde historial), pero si un atributo cambia y vuelve a su valor original entre dos cargas, se generan 3 versiones en vez de colapsarlas a 1 -- la comparación siempre es contra la versión vigente más reciente, no contra todo el historial.
9. `dim_centro_padre` (en `dim_centro_costo`) y `dim_empleado.id_centro_costo` siguen referenciando la clave **natural** del centro de costo padre/asociado, no su `sk` -- no se encadenó la resolución point-in-time recursivamente a través de relaciones dimensión-a-dimensión, por simplicidad.

## v7 — Kardex Real de Insumos (Nov 2026)

Cierra otra de las limitaciones documentadas desde v4/v6: la MPD de `FABRICADO` y los Insumos de `SERVICIO` se calculaban a **costo estándar de referencia** (`cat_insumos_recursos.costo_unitario_referencia`), porque la compra de insumos no estaba modelada transaccionalmente — los insumos no se compraban, solo se declaraban con un costo de referencia fijo. El kardex ya soportaba un `id_insumo` (rama polimórfica-pero-tipada junto a `id_item`), pero quedó sin uso en Fase A. Esta fase activa ese flujo completo: **comprar insumos → kardex ENTRADA → consumir a costo promedio ponderado (CPP) real al vender/producir → kardex SALIDA**.

### Diseño

1. **Homologación de insumos**: nueva tabla `map_insumos` (mismo patrón que `map_productos`), que homologa la descripción libre de Excel de la pestaña `Compras_y_Gastos` hacia `cat_insumos_recursos.id_insumo`. Una fila de `Compras_y_Gastos` ahora puede homologar contra `map_productos` (compra de un ítem) **o** contra `map_insumos` (compra de un insumo/materia prima) — nunca ambos.
2. **`tbl_compras_detalle`**: se vuelve polimórfica-pero-tipada igual que `tbl_movimientos_inventario` — `id_item` pasa a ser `NULL`-able, se agrega `id_insumo` (`NULL`-able, FK a `cat_insumos_recursos`), y un `CHECK` (`ck_compra_detalle_una_entidad`) exige exactamente uno de los dos.
3. **Cuenta nueva en `cat_plan_cuentas`**: `1143 Inventario de Insumos y Materias Primas` (subgrupo `1.1.04`, mismo patrón que `1141`, que es inventario de mercaderías para reventa — se mantienen separados porque son naturalezas de inventario distintas).

### Motor ETL / venta puntual

4. **`sp_procesar_etl_fase3`**: la validación `ITEM_NO_HOMOLOGADO` ahora acepta homologación contra `map_productos` O `map_insumos` para `Compras_y_Gastos` (sin cambios para `Ventas_Devengadas`, que nunca vende un insumo). El `INSERT` a `tbl_compras_detalle` puebla `id_item` o `id_insumo` según cuál mapeo resolvió. El cursor de ENTRADA a kardex (antes solo para `COMPRADO_REVENTA`) se extiende para procesar también toda compra de insumo. El asiento automático de compra resuelve la cuenta Debe con un `CASE` de 3 ramas: insumo → `1143`, `COMPRADO_REVENTA` → `1141`, resto → cuenta de costo/gasto del ítem (fallback `6215`).
5. **La MPD de `FABRICADO` y los Insumos de `SERVICIO` ya NO se calculan a costo estándar**: se reemplaza la fórmula BOM-agregada por un cursor que recorre cada componente de insumo del BOM (`tbl_item_composicion_insumos`) y llama a `sp_registrar_movimiento_inventario` (SALIDA) para obtener el costo promedio ponderado (CPP) real vigente en el kardex al momento de la venta — misma mecánica ya usada para la salida de `COMPRADO_REVENTA`. El MOD de `FABRICADO` y los Honorarios de `SERVICIO` (mano de obra) **no cambian**: siguen a costo estándar, porque la mano de obra no se inventaría. Cambio aplicado en paralelo en `sp_procesar_etl_fase3` (por lote) y `sp_procesar_venta_externa` (venta puntual).
6. **`dw.sp_cargar_dw_fact_margen_venta`**: la fórmula de `costo_directo` para `FABRICADO`/`SERVICIO` se reconcilia con el cambio anterior — el MOD/Honorarios sigue a costo estándar, pero la MPD/Insumos ahora se LEE del costo real ya registrado en el kardex (`tbl_movimientos_inventario`, salidas con `id_referencia` = la venta y `id_insumo` entre los componentes del BOM del ítem), igual filosofía que la lectura ya existente para `COMPRADO_REVENTA`.

### Comportamiento operacional nuevo

7. Una venta `FABRICADO`/`SERVICIO` ahora **falla con "stock insuficiente"** (error propio de `sp_registrar_movimiento_inventario`) si los insumos de su BOM no fueron comprados (ingresados a kardex) en cantidad suficiente antes de la venta. Esto es la contraparte esperada de pasar a costo real: ya no hay un costo de referencia que "cubra" la falta de inventario.

### Limitación que permanece (decisión explícita, no un olvido)

8. **`sp_prorratear_cif_periodo`** no se modifica: la base de prorrateo de CIF sigue usando el costo estándar (BOM) de MPD/MOD, no el costo real de kardex. Esto introduce una divergencia menor entre la base de absorción de CIF y el costo real ya registrado para la MPD — se documenta como simplificación conocida; cerrarla implicaría rediseñar `sp_prorratear_cif_periodo` para leer el consumo real del período en vez de la composición estándar, lo que queda fuera de alcance de esta fase.
9. El kardex solo referencia `id_venta_devengada` (no `id_venta_detalle`): si una misma venta tiene 2+ líneas `FABRICADO`/`SERVICIO` que comparten un mismo insumo en su BOM, el costo real de ese insumo se atribuye a ambas líneas en `dw.fact_margen_venta` sin poder discriminar cuánto consumió cada una — caso de borde poco frecuente (una venta con múltiples ítems fabricados que comparten materia prima), no corregido en esta fase.

## v6 — Costeo Directo de Servicios (Nov 2026)

Cierra una de las limitaciones documentadas desde v4: en esa fase, la venta de un ítem de tipo Servicio (`modo_obtencion` NULL) no generaba ningún leg de costo directo — el usuario había pedido explícitamente desde el principio *"venta de servicios asociar los costos de insumos y honorarios de forma directa al servicio"*, y esa parte quedó pendiente.

### Diseño

Se extiende `modo_obtencion` con un tercer valor explícito, **`SERVICIO`**, en vez de seguir usando NULL para "servicio sin costeo". Esto deja la clasificación de todo ítem (PRODUCTO comprado, PRODUCTO fabricado, SERVICIO) expresada de forma uniforme en una sola columna, consistente con el resto del motor de costeo directo. NULL se mantiene como valor válido para un ítem aún sin clasificar (comportamiento legado: sin leg de costo).

La mecánica de costeo para `SERVICIO` es intencionalmente **análoga a `FABRICADO`** — misma fuente BOM (`tbl_item_composicion_hh` + `tbl_item_composicion_insumos`), misma fórmula de cálculo — pero reinterpretada y con cuentas contables propias:
- **Honorarios** (antes "MOD"): costo de las horas profesionales (propias o subcontratadas) consumidas para prestar el servicio.
- **Insumos**: costo de los insumos consumidos, a costo estándar de referencia (BOM) — misma limitación que la MPD de `FABRICADO` (no se consume contra un kardex real de compras de insumos).
- **Sin CIF**: los Costos Indirectos de Fabricación son, por definición, exclusivos de producción; no se prorratean hacia servicios.

### Cambios de esquema

1. **`tbl_productos_servicios.modo_obtencion`**: el `CHECK` ahora admite `'SERVICIO'` además de `'COMPRADO_REVENTA'` y `'FABRICADO'`.
2. **Cuentas nuevas en `cat_plan_cuentas`** (subgrupo `2.1.02`, mismo patrón que `2123`): `2124 Insumos Aplicados a Servicios por Regularizar` y `2125 Honorarios Profesionales por Pagar (Servicios)`, ambas PASIVO/ACREEDORA.

### Motor de costeo directo

3. **`sp_procesar_etl_fase3`** y **`sp_procesar_venta_externa`**: ambos agregan una rama `SERVICIO` (análoga a la rama `FABRICADO`) que calcula Honorarios + Insumos y postea: Debe Costo/Gasto del ítem (fallback `5113 Honorarios/Servicios Subcontratados`, en vez de `5111` que es para mercadería) / Haber `2125` (porción honorarios) y Haber `2124` (porción insumos).
4. **`dw.sp_cargar_dw_fact_margen_venta`**: la fórmula de `costo_directo` ahora cubre `FABRICADO` y `SERVICIO` con el mismo cálculo (antes solo cubría `FABRICADO`), por lo que `dw.vw_dw_margen_por_item` ya refleja el margen de los servicios.

### Limitación que permanece

5. Igual que la MPD de `FABRICADO`, los Insumos de un `SERVICIO` se aplican a costo estándar de referencia (BOM), no contra un kardex real de compras de insumos — misma causa raíz documentada en v4 (la compra de insumos no está modelada transaccionalmente en este esquema).

## v5 — Data Warehouse en Estrella (Fase B) (Nov 2026)

Implementación del Data Warehouse solicitado explícitamente desde v3: *"debemos tener un data warehouse con modelo estrella y que la tabla mas importante de todo esto desde donde se obtienen los indicadores es 'fact_asientos_contables'"*, confirmando después *"recuerda que todos los resultados deben terminar en la estrella 'FACT_ASIENTOS_CONTABLES' y desde ahí deberíamos obtener el balance general y estado de resultados"*. El usuario decidió explícitamente: (1) construir directo (no solo diseño), y (2) esquema separado (`dw`) dentro de la misma base `consultora_pymes_core` (no una base de datos aparte).

Esta fase mapea el framework de 4 capas que el usuario describió (Origen/Ingesta → Transformación/Calidad → Enriquecimiento/Negocio/Core Analítico y Linaje → Consumo/Gobierno) así: **Capa 1-2** ya existían (staging + ETL de Fase 3); **Capa 3** es el nuevo esquema `dw` (dimensiones + hechos); **Capa 4** son las nuevas vistas `dw.vw_dw_*`.

### Esquema `dw` (`sql/crear_esquema_dw.sql`)

1. **6 dimensiones Tipo 1** (sobrescritura completa, sin historizar cambios — ver limitación): `dim_tiempo` (calendario, aditiva), `dim_cuenta_contable`, `dim_centro_costo`, `dim_tercero`, `dim_empleado`, `dim_item` (incluye `modo_obtencion` de v4).
2. **`dw.fact_asientos_contables`** (tabla **CENTRAL**, tal como pidió el usuario): grano = 1 fila por línea de `dbo.tbl_asientos_detalle`. Es la misma fuente que ya alimenta `vw_balance_general`/`vw_estado_resultados` en el esquema transaccional — por eso se puede reconstruir el Balance General y el Estado de Resultados exactamente igual desde aquí (ver punto 5).
3. **`dw.fact_margen_venta`** (hecho secundario): grano = 1 fila por línea de `dbo.tbl_ventas_detalle`, con `costo_directo` y `margen_contribucion` ya resueltos según el Costeo Directo por Flujo de Venta de v4 — evita que cada consulta de BI tenga que recalcular CPP/MOD+MPD.

### Carga (`sql/sp_cargar_dw.sql`)

4. **Estrategia v1: FULL REFRESH** (`TRUNCATE`/`DELETE` + reconstrucción completa) en cada corrida de `dw.sp_cargar_dw_completo`, en vez de una carga incremental. Es la opción más simple y menos propensa a errores para el volumen esperado de una PyME. El orden de carga importa por las FK: primero se vacían los HECHOS (referencian a las dimensiones), luego se recargan las DIMENSIONES, luego `dim_tiempo` (cubriendo el rango de fechas del OLTP), y por último se reconstruyen los HECHOS. `dw.fact_margen_venta.costo_directo` se resuelve leyendo el costo real ya registrado en el kardex (`COMPRADO_REVENTA`) o recalculando MOD+MPD a costo estándar (`FABRICADO`), con la misma lógica que ya usan `sp_procesar_etl_fase3` / `sp_procesar_venta_externa`.

### Consumo (`sql/crear_vistas_dw_consumo.sql`)

5. **`dw.vw_dw_balance_general`, `dw.vw_dw_estado_resultados`, `dw.vw_dw_estado_resultados_por_centro_costo`**: réplicas exactas (misma lógica de cálculo, respetando `naturaleza`/`tipo_cuenta`) de las vistas homónimas del esquema transaccional, pero leyendo desde `dw.fact_asientos_contables` — la prueba de que la estrella reproduce correctamente ambos reportes financieros, como pidió el usuario. Incluye una consulta de validación de paridad OLTP-vs-DW comentada al final del archivo.
6. **`dw.vw_dw_margen_por_item`**: margen de contribución por ítem y periodo contable, agregado desde `fact_margen_venta`.

### Limitaciones documentadas

7. **Dimensiones Tipo 1 (sin historizar).** Si cambia un atributo de una dimensión (p. ej. se reasigna un empleado a otro centro de costo), el DW refleja el valor VIGENTE al momento de la carga, no el que tenía cuando ocurrió cada transacción histórica. Para este esquema transaccional (pequeño, cambios poco frecuentes) no se consideró necesario implementar Slowly Changing Dimensions (SCD Tipo 2); queda como mejora futura si se requiere trazar la evolución de atributos en el tiempo.
8. **Carga full-refresh, no incremental.** `dw.sp_cargar_dw_completo` reconstruye todo el DW desde cero en cada ejecución. Para un volumen de datos significativamente mayor, convendría una carga incremental (solo las filas nuevas/modificadas desde la última corrida, vía una tabla de control de alta marca); no implementada en esta fase.
9. **Sin automatización de la carga.** `dw.sp_cargar_dw_completo` debe ejecutarse manualmente (o vía un job/tarea programada externa al alcance de este repositorio) — no se dispara automáticamente desde el ETL transaccional. Se recomienda ejecutarlo después de `dbo.sp_prorratear_cif_periodo` en cada cierre de periodo.

## v4 — Costeo Directo por Flujo de Venta (Nov 2026)

Extensión funcional solicitada explícitamente a partir de v3: la plataforma de Control de Gestión ya relaciona cada transacción con su entidad y genera partida doble automática, pero el Estado de Resultados no reflejaba el **costo real** de lo vendido — solo el gasto puntual de cada compra. El usuario señaló que faltaba "el mundo de los costos indirectos de producción" y que una empresa puede vender productos comprados, productos fabricados, servicios, o una combinación de los tres, requiriendo trazar el costo de forma **directa según el flujo de venta**: *"venta de producto comprado asociar el costo directo de la compra, venta de productos fabricados, asociar la mano de obra directa y los costos de materia prima directa (mediante los movimientos de bodega), venta de servicios asociar los costos de insumos y honorarios de forma directa al servicio"*. Esta fase ("Fase A") implementa el mecanismo de costeo para los flujos de producto; el costeo de servicios y el Data Warehouse en estrella (`fact_asientos_contables`) quedan para una fase posterior ("Fase B"), aún no iniciada.

### Cambios de esquema

1. **`tbl_productos_servicios.modo_obtencion`** (nueva columna, NULL para servicios): `COMPRADO_REVENTA` o `FABRICADO`. Determina qué mecanismo de costeo aplica a cada ítem al venderse.
2. **`tbl_movimientos_inventario`** (tabla nueva, `sql/crear_modulo_inventario_costeo.sql`): kardex de Costo Promedio Ponderado (CPP), con FK polimórfica pero tipada (`id_item` XOR `id_insumo`, vía CHECK) y saldo de cantidad/valor/CPP resultante grabado en cada fila (auditable sin recalcular historial). El SP `sp_registrar_movimiento_inventario` encapsula la lógica de entrada/salida y valida stock suficiente antes de una salida.
3. **Cuentas nuevas en `cat_plan_cuentas`**: subgrupo `5.2 Costos Indirectos de Fabricación (CIF)` con 3 cuentas "incurridas" (`5.2.01.001/002/003`: arriendo+depreciación de planta, supervisión/MOI, servicios básicos) y 1 contra-cuenta de absorción (`5.2.02.001 CIF Absorbido a Productos`), todas en el mismo subgrupo para que la variancia sobre/sub-absorbida quede visible como el saldo neto de 5.2 en el Estado de Resultados. También `2.1.02.003 Materia Prima Aplicada a Producción por Regularizar` (PASIVO), contra-cuenta de la MPD aplicada a costo estándar mientras no se regularice contra la compra real del insumo.

### Motor de costeo directo

4. **Producto `COMPRADO_REVENTA`**: cada compra genera una `ENTRADA` al kardex (a `precio_unitario` de la compra) y cada venta genera una `SALIDA` al CPP vigente. El asiento de la compra activa el monto a Inventario (`1141`) en vez de cargarlo directo a Costo/Gasto; el asiento de la venta agrega Debe Costo/Gasto del ítem / Haber Inventario (`1141`) por el CPP consumido.
5. **Producto `FABRICADO`**: cada venta calcula Mano de Obra Directa (desde `tbl_item_composicion_hh`) y Materia Prima Directa a costo estándar de referencia (desde `tbl_item_composicion_insumos`), y agrega al asiento de la venta: Debe Costo/Gasto del ítem por MOD+MPD / Haber `2131 Remuneraciones por Pagar` (porción MOD) / Haber `2123 Materia Prima Aplicada a Producción por Regularizar` (porción MPD). Se eligió contra-cuentas de tipo PASIVO (no COSTO) para que el Debe Costo de Ventas no se autocancele en `vw_estado_resultados` (que suma `debe-haber` agrupado por `tipo_cuenta`; dos cuentas COSTO debitada/acreditada por el mismo monto se anularían entre sí).
6. **`sp_prorratear_cif_periodo`** (nuevo SP, a ejecutar al cierre de cada periodo contable): prorratea el CIF incurrido en 5.2.01.* de cada centro de costo hacia los productos `FABRICADO` vendidos en el periodo, usando como base el costo directo (MOD+MPD) de esas ventas. Si un centro de costo no vendió productos `FABRICADO` en el periodo, su CIF queda explícitamente sin absorber (se imprime como aviso) y se refleja como costo del periodo.
7. **`sp_procesar_etl_fase3`** y **`sp_procesar_venta_externa`**: ambos ahora resuelven `modo_obtencion` del ítem vendido/comprado y generan el leg de costo directo descrito arriba (kardex para `COMPRADO_REVENTA`, MOD+MPD para `FABRICADO`), dentro de la misma transacción atómica que ya generaba el asiento de ingreso/compra.

### Limitaciones documentadas (alcance explícitamente acotado para esta fase)

8. **MPD a costo estándar, no a kardex real de insumos.** El usuario mencionó "mediante los movimientos de bodega" para la materia prima directa. Se evaluó extender el kardex para registrar también compras reales de insumos (`cat_insumos_recursos`), pero el esquema actual no modela la compra de insumos de forma transaccional (`tbl_compras_detalle.id_item` solo referencia `tbl_productos_servicios`, no insumos) — hacerlo habría requerido una extensión mayor (nueva tabla de compra de insumos, nueva homologación en el ETL, etc.), fuera del alcance de esta fase. Por ahora la MPD se aplica a su costo estándar de referencia (BOM) y se provisiona contra `2123` hasta regularizarse manualmente contra la compra real. Queda como mejora futura si se requiere trazabilidad real de insumos.
9. **Servicios sin cambios de costeo.** Para ítems de tipo Servicio (`modo_obtencion` NULL), esta fase no modifica el leg de costo — asociar honorarios/insumos a una venta de servicio específica requiere un mecanismo de vinculación que no existe aún en el esquema. Documentado como limitación, no implementado.
10. **CIF requiere ejecución manual al cierre.** `sp_prorratear_cif_periodo` no se dispara automáticamente: debe ejecutarse explícitamente al cerrar cada periodo contable (análogo a `TRASPASO_HASTA/DESDE` en v3, que tampoco se automatizó).

## v3 — Plataforma de Control de Gestión (Nov 2026)

Extensión funcional solicitada explícitamente: "lo que estamos construyendo es una plataforma de control de gestión, por lo tanto cada transacción debe relacionarse a su entidad correspondiente y además mantener el principio de partida doble de las cuentas contables, para que al final los resultados me muestren el balance general y estado de resultados correcto". Dos decisiones de diseño fueron confirmadas explícitamente: (1) imputar **ambas** dimensiones, Centro de Costo y Empleado/Responsable, a cada transacción; (2) generar los asientos contables de forma **automática** (no manual) desde el ETL y desde la venta puntual.

### Cambios de esquema

1. **`cat_plan_cuentas.tipo_cuenta`** (nueva columna NOT NULL): clasificación explícita ACTIVO/PASIVO/PATRIMONIO/INGRESO/COSTO/GASTO, backfillada desde el dígito raíz de `codigo_cuenta`. Es la fuente de verdad que usan las nuevas vistas de reporte (no se parsea `codigo_cuenta` en tiempo de consulta).
2. **`tbl_asientos_detalle.id_centro_costo`** (nueva columna, FK a `tbl_centros_costo`): permite un Estado de Resultados segmentado por centro de costo.
3. **`tbl_productos_servicios.id_cuenta_ingreso` / `id_cuenta_costo_gasto`** (nuevas columnas, FK a `cat_plan_cuentas`): cada ítem declara a qué cuenta de Ingreso se abona al venderse y a qué cuenta de Costo/Gasto se carga al comprarse. Si un ítem no tiene mapeo propio, el motor usa cuentas "default" nuevas (`4.1.01.003 Otros Ingresos Operacionales`, `6.2.01.005 Gastos Operacionales Generales`) para no bloquear la contabilización automática.
4. **`id_centro_costo` / `id_empleado`** agregadas a `tbl_ventas_devengadas`, `tbl_ordenes_compra` y `tbl_movimientos_caja` (FK a `tbl_centros_costo` / `tbl_empleados_usuarios`), ambas NULL-ables.
5. **`tbl_staging_carga.centro_costo_raw` / `empleado_raw`**: nuevas columnas, comunes a las 3 pestañas del Excel. A diferencia de cliente/ítem, se validan por código/RUT directo (sin homologación), ya que son campos internos de la operación, no texto libre externo.
6. **Reordenamiento del despliegue**: Centros de Costo/Empleados pasó del paso 4 al 2, y Contabilidad del paso 2 al 3, porque `tbl_asientos_detalle` y `tbl_productos_servicios` ahora dependen de ellos. Ver `README.md`.

### Motor de contabilización automática

7. **`dbo.tipo_asiento_detalle`** (nuevo TYPE, tabla de parámetro) y **`sp_registrar_asiento_contable`** (nuevo SP reutilizable): punto único de entrada para registrar un asiento de partida doble, con validación dura de `SUM(debe) = SUM(haber)` y de mínimo 2 líneas antes de insertar. Evita reimplementar el `INSERT` a `tbl_asientos_cabecera/detalle` en cada módulo transaccional.
8. **`sp_procesar_etl_fase3`**: tras cargar cada venta, compra o movimiento de caja nuevo al Core, genera automáticamente su asiento (Debe Clientes / Haber Ingreso+IVA Débito para ventas; Debe Costo/Gasto+IVA Crédito / Haber Proveedores para compras; Debe/Haber Caja según `tipo_flujo` para movimientos de caja). Se agregan también las validaciones `CENTRO_COSTO_NO_EXISTE` y `EMPLEADO_NO_EXISTE`.
9. **`sp_procesar_venta_externa`**: recibe `@id_centro_costo`/`@id_empleado` opcionales y genera su asiento automático dentro de la misma transacción atómica que la venta.
10. **Limitación documentada**: `TRASPASO_HASTA`/`TRASPASO_DESDE` en Movimientos de Caja **no** generan asiento automático en v3 — un traspaso real involucra dos filas del Excel (origen y destino) que deben conciliarse antes de armar un asiento correcto de 2 líneas; se deja como asiento manual.

### Reportes

11. **`sql/crear_vistas_reportes_gestion.sql`** (nuevo archivo): `vw_balance_general` (fotografía a la fecha, respeta la naturaleza DEUDORA/ACREEDORA de cada cuenta), `vw_estado_resultados` (por periodo contable) y `vw_estado_resultados_por_centro_costo` (por periodo y centro de costo). Nota: el Balance General solo cuadra exactamente contra Pasivo+Patrimonio si se suma también el resultado acumulado del Estado de Resultados, porque v3 no implementa el asiento de cierre de periodo que traspasa Ingreso/Costo/Gasto a la cuenta `3.1.04.001 Resultado del Ejercicio` — queda documentado como paso manual/futuro.

## v2 — Auditoría y corrección integral (Nov 2026)

Corrección derivada de una auditoría arquitectónica completa del repositorio original (`consultora-pymes-core`), cubriendo DBML, SQL y documentación.

### Críticos

1. **FKs faltantes de `id_tercero`.** `tbl_transacciones_cabecera`, `tbl_ordenes_compra`, `tbl_ventas_devengadas` y `tbl_movimientos_caja` declaraban `id_tercero` solo en comentario, sin `CONSTRAINT FOREIGN KEY` real ni en SQL ni en DBML. Se agregaron las 4 FKs hacia `tbl_terceros`.
2. **Orden de despliegue incompleto.** El manual de Fase 1 nunca incluía `crear_modulo_terceros.sql`, por lo que siguiendo el manual al pie de la letra `tbl_terceros` jamás se creaba. Se corrigió el orden y se agregó como paso obligatorio inicial.
3. **`map_productos` nunca se creaba.** Estaba documentada, modelada en DBML y referenciada en `sp_procesar_transaccion_externa.sql`, pero no existía ningún `CREATE TABLE map_productos`. Se agregó en `sql/crear_tablas_mapeo.sql`, con `UNIQUE` y FK hacia `tbl_productos_servicios` (y se agregó la FK que también faltaba en `map_clientes`).
4. **`sp_procesar_venta_externa` no insertaba nada en el Core.** El `INSERT` hacia `tbl_ventas_devengadas`/`tbl_ventas_detalle` estaba comentado como "ejemplo conceptual". Se implementó el insert real, con cálculo de neto/IVA/total según `aplica_iva` del ítem homologado.
5. **El motor ETL (`sp_procesar_etl_fase3`) solo auditaba, nunca cargaba al Core**, y validaba apenas 2 de las ~10 reglas que la propia especificación (`docs/fase3_motor_etl.md`) exigía (faltaban: formato de fecha, homologación de producto, reglas de `Movimientos_Caja`, distinción entre las 3 pestañas). Se reescribió completo: valida por archivo/pestaña, cubre todas las reglas documentadas, y carga las filas válidas al Core dentro de una transacción atómica.
6. **`tbl_staging_carga` no podía representar las 3 pestañas del Excel.** Tenía un esquema genérico (cliente/producto/cantidad/monto) sin campos para `estado_venta`/`estado_oc`, `tipo_flujo`, `cuenta_bancaria` ni `glosa`, y columnas tipadas (`DATE`, `DECIMAL`) que rechazaban silenciosamente cualquier fila mal formateada antes de poder auditarla. Se rediseñó con columnas `VARCHAR` crudas para las 3 pestañas, más `nombre_archivo` y `pestana_origen` para aislar cada corrida de carga.

### Medios

7. **Fan-out (producto cartesiano) en `vw_productos_servicios_costeo`.** El doble `LEFT JOIN` (horas-hombre × insumos) inflaba los costos cuando un ítem tenía líneas en ambas composiciones. Se corrigió agregando cada costo en una CTE independiente antes de unir 1:1 por ítem.

### Menores

8. Typo en DBML: `cat_insumos_recursos.id_insumos` → `id_insumo`.
9. Desalineación de nombres: DBML usaba `id_cc_padre`, el SQL real usa `id_centro_padre`. Se alineó el DBML.
10. `docs/fase3_manual_operacion_fase3.md` estaba incompleto (cortaba a mitad del Paso 1). Se completó con los 6 pasos operativos y la tabla de códigos de error.
11. Se actualizaron `docs/fase3_especificacion_staging.md`, `docs/fase3_especificacion_etl.md` y `docs/fase3_motor_etl.md` para reflejar fielmente el diseño v2.

### Sin cambios (evaluado y considerado correcto)

- Modelo relacional de Fase 1 (Terceros, Productos/Servicios, Contabilidad): 3FN correctamente aplicada, patrón Business Partner, patrón de extensión ERP 1:1, partida doble y plan de cuentas chileno. No se encontraron deficiencias que justificaran cambios estructurales.
- Estrategia de llaves primarias manuales (no `IDENTITY`) en las tablas transaccionales: se mantuvo sin cambios para no alterar los scripts de demostración existentes; el motor ETL calcula el siguiente ID de forma segura (`MAX() + ROW_NUMBER()`) dentro de la misma transacción.
