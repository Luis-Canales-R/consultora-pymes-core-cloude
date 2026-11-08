# Módulo: Data Warehouse en Estrella (esquema `dw`) — v5 (Fase B) / v8 (SCD Tipo 2) / v9 (Carga Incremental) / v12 (Costeo Point-in-Time)

## Objetivo
Dar soporte analítico (Capa 3: Enriquecimiento/Negocio/Core Analítico y Linaje, y Capa 4: Consumo y Gobierno de Accesos, del framework de 4 capas) sin tocar el esquema transaccional (`dbo`), que sigue siendo la fuente de verdad operativa (OLTP).

## Por qué un esquema separado y no una base de datos aparte
Se eligió explícitamente un esquema (`dw`) dentro de la misma base `consultora_pymes_core`, en vez de una base de datos analítica separada. Razones: (1) simplifica el despliegue y las conexiones (un solo connection string); (2) a la escala de una PyME, el volumen de datos no justifica aislar físicamente el motor de cómputo; (3) las vistas de carga (`sql/sp_cargar_dw.sql`) pueden hacer `JOIN` directo entre `dbo.*` y `dw.*` sin necesidad de *linked servers* ni replicación.

## Arquitectura: Dimensiones y Hechos

### Dimensiones (Tipo 2 — SCD, historizadas desde v8; Tipo 1 hasta v7)
| Dimensión | Espejo de | Notas |
|---|---|---|
| `dw.dim_tiempo` | — (generada) | Calendario día a día. Aditiva (nunca se borra), generada por `dw.sp_cargar_dw_dim_tiempo`. **No** se historiza (no aplica SCD: un día no cambia de atributos). |
| `dw.dim_cuenta_contable` | `dbo.cat_plan_cuentas` | Incluye `tipo_cuenta` (clave para Balance/EERR). SCD Tipo 2 desde v8. |
| `dw.dim_centro_costo` | `dbo.tbl_centros_costo` | SCD Tipo 2 desde v8. |
| `dw.dim_tercero` | `dbo.tbl_terceros` | Agrega `es_cliente`/`es_proveedor`, derivados de las tablas de extensión 1:1. SCD Tipo 2 desde v8. |
| `dw.dim_empleado` | `dbo.tbl_empleados_usuarios` | SCD Tipo 2 desde v8. |
| `dw.dim_item` | `dbo.tbl_productos_servicios` | Incluye `modo_obtencion` (v4) para segmentar por flujo de venta. SCD Tipo 2 desde v8 — es el caso motivador de la historización (ver abajo). |

**v8 — SCD Tipo 2, qué significa y cómo funciona aquí**: hasta v7, cada dimensión (excepto `dim_tiempo`) era Tipo 1 (sobrescritura completa) — si un atributo cambiaba (p. ej. un ítem que pasa de `COMPRADO_REVENTA` a `FABRICADO`), el DW reflejaba solo el valor vigente al momento de la carga, perdiendo el histórico. Desde v8:
- Cada dimensión tiene su propia **clave surrogada** (`sk_*`, PK real, `IDENTITY`) y la clave natural (`id_*`) deja de ser única por sí sola — se repite una fila por cada versión histórica.
- Cada fila agrega `fecha_inicio_vigencia`, `fecha_fin_vigencia` (`NULL` = versión vigente) y `es_vigente` (índice único filtrado: a lo sumo una fila vigente por clave natural).
- `dw.sp_cargar_dw_dimensiones` ya **no borra** las dimensiones: en cada ejecución, cierra (`fecha_fin_vigencia`, `es_vigente = 0`) la versión vigente de toda fila cuyos atributos cambiaron en `dbo` (comparación NULL-safe vía `EXCEPT`) e inserta la versión nueva. Una clave natural nunca vista antes nace con `fecha_inicio_vigencia` en una fecha "época" (`1900-01-01`), no "hoy", para que los hechos históricos que la referencian puedan resolverla.
- Los hechos (`fact_asientos_contables`, `fact_margen_venta`) guardan **ambas** claves: la natural (`id_*`, degenerada, para filtros por "estado actual") y la surrogada (`sk_*`, resuelta **por fecha** en la carga — la versión de la dimensión vigente *al momento de la transacción*, no la vigente hoy). Esto es lo que hace que un reporte por periodo (Estado de Resultados, margen por ítem) sea **point-in-time correcto**: si una cuenta o un ítem cambia de clasificación después de un asiento/venta, ese asiento/venta sigue reportando con la clasificación que tenía vigente en ese momento.
- El Balance General es la excepción deliberada: es un snapshot "a hoy", así que suma el histórico completo de cada cuenta (por clave natural) pero la muestra con su clasificación **vigente hoy** (`es_vigente = 1`) — igual convención que un plan de cuentas reclasificado en un sistema contable real.

### Hechos
- **`dw.fact_asientos_contables`** — tabla **CENTRAL** del modelo (tal como se definió explícitamente): grano = 1 fila por línea de `dbo.tbl_asientos_detalle`. Desde aquí se reconstruyen Balance General y Estado de Resultados (`dw.vw_dw_balance_general`, `dw.vw_dw_estado_resultados`, `dw.vw_dw_estado_resultados_por_centro_costo`), con la misma lógica de cálculo que las vistas equivalentes del esquema transaccional. Desde v8 incluye `sk_cuenta_contable`/`sk_centro_costo` (point-in-time).
- **`dw.fact_margen_venta`** — hecho secundario: grano = 1 fila por línea de `dbo.tbl_ventas_detalle`, con `costo_directo` y `margen_contribucion` ya resueltos (Costeo Directo por Flujo de Venta de v4/v6/v7 — cubre `COMPRADO_REVENTA`, `FABRICADO` y, desde v6, `SERVICIO`), consumido por `dw.vw_dw_margen_por_item`. Desde **v7**, la porción MPD/Insumos de `FABRICADO`/`SERVICIO` ya no se recalcula a costo estándar: se LEE el costo real ya consumido del kardex (`dbo.tbl_movimientos_inventario`), igual que ya se hacía para `COMPRADO_REVENTA` — ver limitación de atribución por línea (cuando dos líneas de una misma venta comparten insumo) en `CHANGELOG.md` (v7). Desde v8 incluye `sk_item`/`sk_tercero`/`sk_centro_costo`/`sk_empleado` (point-in-time). Desde **v12**, el **cálculo** de `costo_directo` (y la columna `modo_obtencion` almacenada en el hecho) también usan el `modo_obtencion` **point-in-time** del ítem (vía `di.modo_obtencion`, ya resuelto por el JOIN con `dim_item`) en vez del actual en `dbo` — cierra la limitación que quedaba abierta desde v8 (ver abajo).

## Carga del Data Warehouse

Desde **v9** hay dos orquestadores — uno para el **bootstrap** (primera carga, o una reconstrucción forzada) y otro para la **operación rutinaria**:

### Carga completa (bootstrap / reconstrucción forzada)
```sql
EXEC dw.sp_cargar_dw_completo;
```
Reconstruye los **HECHOS** desde cero (full refresh: `DELETE` + reload) y **versiona** las dimensiones (v8: nunca se borran, solo se cierra la versión vigente y se inserta la nueva si cambió algo), en una única transacción atómica. Úsese:
- La primera vez que se despliega el DW (cuando `dw.tbl_control_carga_incremental` todavía no tiene filas).
- Para forzar una reconstrucción total si se sospecha que el DW quedó desalineado respecto a `dbo` (ver limitación v9 más abajo).

**Importante (v8):** como las dimensiones ya no se borran, correr `dw.sp_cargar_dw_completo` repetidamente es seguro — no se pierde historial — pero una dimensión cuyo atributo cambió y volvió a su valor original entre dos cargas generará 3 versiones (no se "colapsan" versiones idénticas no consecutivas), porque la comparación es siempre contra la versión vigente más reciente.

### Carga incremental (operación rutinaria, desde v9)
```sql
EXEC dw.sp_cargar_dw_incremental;
```
Recomendado para el día a día — en vez de reconstruir los HECHOS completos, **solo inserta** las filas de `dbo.tbl_asientos_detalle` / `dbo.tbl_ventas_detalle` cuya clave natural es mayor a la última ya cargada (alta marca / *high-water mark*, guardada en `dw.tbl_control_carga_incremental`). Las dimensiones se versionan igual que en la carga completa (SCD Tipo 2 ya es incremental por naturaleza), y `dim_tiempo` se extiende solo para el rango de fechas de las filas nuevas. Se recomienda ejecutarlo:
- Después de cada corrida relevante de `dbo.sp_procesar_etl_fase3` / `dbo.sp_procesar_venta_externa`, si se requiere BI al día.
- Siempre después de `dbo.sp_prorratear_cif_periodo`, en el cierre de cada periodo contable, para que la absorción de CIF ya esté reflejada en los asientos antes de refrescar el DW.

`dw.sp_cargar_dw_completo` y `dw.sp_cargar_dw_incremental` son intercambiables sin provocar huecos ni duplicados: ambos sincronizan `dw.tbl_control_carga_incremental` al terminar, así que alternar entre uno y otro (por ejemplo, forzar una carga completa puntual y luego volver a la incremental) es seguro.

Los SPs individuales (`dw.sp_cargar_dw_dimensiones`, `dw.sp_cargar_dw_dim_tiempo`, `dw.sp_cargar_dw_fact_asientos_contables[_incremental]`, `dw.sp_cargar_dw_fact_margen_venta[_incremental]`) también se pueden ejecutar por separado si solo se necesita refrescar una parte.

## Limitaciones que permanecen

**v9 — carga incremental asume OLTP solo-inserción:** `dw.sp_cargar_dw_incremental` funciona porque se verificó (revisión de todo el código) que `dbo.tbl_asientos_detalle` y `dbo.tbl_ventas_detalle` nunca reciben `UPDATE` ni `DELETE` — toda corrección se registra como un asiento o una venta **nueva**. Si alguna vez se corrige una fila histórica directamente en `dbo` (fuera de los flujos transaccionales normales), la carga incremental **no lo detectará**: hay que ejecutar `dw.sp_cargar_dw_completo` para forzar una reconstrucción total y dejar el DW consistente otra vez.

**v12 — costeo point-in-time, qué NO cubre.** El fix de v12 resuelve `modo_obtencion` point-in-time (vía `dim_item`/`sk_item`), pero el costo **estándar** de MOD/Honorarios (tarifas de `cat_perfiles_hh`) y la composición del BOM (`tbl_item_composicion_hh`/`tbl_item_composicion_insumos`) que usa la fórmula de `costo_directo` siguen leyéndose de las tablas OLTP **actuales**, sin historizar. Si la tarifa de un perfil HH o la composición del BOM de un ítem cambia después de ventas ya costeadas, un refresh del DW recosteará esas ventas antiguas con la tarifa/composición vigente **hoy**, no con la que estaba vigente al momento de la venta — a diferencia de `modo_obtencion`, estas tablas no tienen SCD Tipo 2. Queda como mejora futura si se requiere trazabilidad histórica completa de tarifas y BOM.

## Validación de paridad OLTP vs. DW
Al final de `sql/crear_vistas_dw_consumo.sql` hay una consulta comentada que compara los totales de `dbo.vw_balance_general` / `dbo.vw_estado_resultados` contra sus equivalentes `dw.vw_dw_*`. Si el DW está al día, ambos deben coincidir exactamente — es el chequeo de que la estrella reproduce correctamente los reportes financieros.

## Prerrequisito de despliegue
`sql/crear_esquema_dw.sql` requiere **todo** el esquema transaccional desplegado (incluyendo v4: kardex de inventario y cuentas CIF). Ver el orden completo en `README.md`.
