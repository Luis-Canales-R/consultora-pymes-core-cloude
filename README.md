# consultora-pymes-core

Sistema RDBMS en SQL Server para la gestión operativa, financiera y de calidad de datos de PyMEs, modelado en Tercera Forma Normal (3FN), con un motor ETL de homologación y auditoría para la ingesta de datos desde planillas Excel, y una capa de **Control de Gestión**: cada transacción se imputa a un Centro de Costo / Empleado y genera automáticamente su asiento contable de partida doble, habilitando Balance General y Estado de Resultados (global y por centro de costo) con **costeo directo real** según el flujo de venta (producto comprado para reventa, producto fabricado o servicio) y absorción de Costos Indirectos de Fabricación (CIF) al cierre de cada periodo. Incluye además un **Data Warehouse en modelo estrella** (esquema `dw`), con `fact_asientos_contables` como tabla central, desde donde se reconstruyen los mismos reportes financieros.

> Este repositorio es la **versión v12 (Costeo de Margen Point-in-Time)** del proyecto original. Ver [`CHANGELOG.md`](./CHANGELOG.md) para el detalle completo de qué se corrigió/agregó y por qué.

## Estructura del repositorio (Docs-as-Code)

```
dbml/   Modelado conceptual de datos (DBML), fuente de verdad del diseño relacional
sql/    Scripts DDL ejecutables y stored procedures (SQL Server)
docs/   Documentación técnica y manuales de operación por fase/módulo
```

## Módulos del sistema

1. **Terceros** (`tbl_terceros`): maestro unificado de clientes, proveedores y sponsors (patrón Business Partner).
2. **Centros de Costo y Empleados**: dimensiones organizacionales (taxonomía APQC). Desde v3, toda transacción y toda línea contable puede imputarse a un centro de costo y a un empleado/responsable.
3. **Contabilidad y Transacciones** (`cat_plan_cuentas`, `tbl_asientos_*`): partida doble con plan de cuentas estándar Chile, clasificación `tipo_cuenta` (ACTIVO/PASIVO/PATRIMONIO/INGRESO/COSTO/GASTO) y el SP reutilizable `sp_registrar_asiento_contable` que usan los módulos transaccionales para contabilizar automáticamente.
4. **Productos y Servicios** (`tbl_productos_servicios`): catálogo unificado con extensiones ERP 1:1, estructura de costos BOM/CBS, mapeo contable por ítem (`id_cuenta_ingreso` / `id_cuenta_costo_gasto`) y `modo_obtencion` (`COMPRADO_REVENTA` / `FABRICADO` / `SERVICIO` desde v6 / NULL sin clasificar) que determina cómo se costea cada venta.
5. **Inventario y Costeo** (`tbl_movimientos_inventario`, `sp_registrar_movimiento_inventario`): kardex de Costo Promedio Ponderado (CPP), polimórfico-pero-tipado (`id_item` XOR `id_insumo`), con saldo de cantidad/valor/CPP recalculado en cada movimiento (entrada por compra, salida por venta/consumo). Desde v7 el kardex de insumos está activo de punta a punta (antes solo lo estaba el de ítems `COMPRADO_REVENTA`).
6. **Transacciones Granulares** (`tbl_ordenes_compra`, `tbl_ventas_devengadas`, `tbl_movimientos_caja`): ciclo comercial y tesorería, cada una generando su asiento automático al cargarse, incluyendo el leg de costo directo (CPP del kardex para `COMPRADO_REVENTA`; MOD a costo estándar + MPD a costo **real de kardex** desde v7 para `FABRICADO`; Honorarios a costo estándar + Insumos a costo **real de kardex** desde v7 para `SERVICIO`). `tbl_compras_detalle` admite comprar un ítem o un insumo (`id_item` XOR `id_insumo`, v7). Los `TRASPASO_DESDE`/`TRASPASO_HASTA` de `tbl_movimientos_caja` también generan asiento automático desde **v11** (se emparejan por fecha/monto/glosa dentro del mismo lote del ETL).
7. **Mapeo y Homologación** (`map_clientes`, `map_productos`, `map_insumos` desde v7): traducción de datos informales de Excel a IDs canónicos.
8. **Motor ETL (Fase 3)** (`tbl_staging_carga`, `tbl_log_errores_etl`, `sp_procesar_etl_fase3`): validación, auditoría, carga masiva al Core, contabilización automática y costeo directo por flujo de venta (a costo real de kardex para la porción de insumos, desde v7).
9. **Costos Indirectos de Fabricación (CIF)** (cuentas `5.2.01.*`/`5.2.02.001`, `sp_prorratear_cif_periodo`): absorción del CIF incurrido en el periodo hacia los productos `FABRICADO` vendidos, prorrateado por costo directo (MOD a costo estándar + MPD a costo **real de kardex** desde **v10**), dejando la variancia sobre/sub-absorbida visible en el Estado de Resultados.
10. **Reportes de Control de Gestión** (`vw_balance_general`, `vw_estado_resultados`, `vw_estado_resultados_por_centro_costo`): vistas construidas sobre `tbl_asientos_detalle`.
11. **Data Warehouse en Estrella (Fase B, esquema `dw`)**: `fact_asientos_contables` (grano = 1 línea de `tbl_asientos_detalle`, tabla CENTRAL) y `fact_margen_venta` (grano = 1 línea de `tbl_ventas_detalle`, con `costo_directo`/`margen_contribucion` ya resueltos), más 6 dimensiones (`dim_tiempo`, `dim_cuenta_contable`, `dim_centro_costo`, `dim_tercero`, `dim_empleado`, `dim_item`). Desde **v8** las 5 dimensiones no aditivas son **SCD Tipo 2** (historizadas, con clave surrogada `sk_*` propia) en vez de Tipo 1 — los hechos resuelven esa `sk_*` por fecha (point-in-time), y desde **v12** el cálculo de `costo_directo` también ramifica por el `modo_obtencion` point-in-time del ítem (no el actual). Desde **v9**, los HECHOS pueden cargarse en **full refresh** (`dw.sp_cargar_dw_completo`, recomendado para el despliegue inicial o una reconstrucción forzada) o en **carga incremental** (`dw.sp_cargar_dw_incremental`, recomendado para la operación rutinaria — solo trae lo nuevo desde `dbo`, usando `dw.tbl_control_carga_incremental` como alta marca por tabla de hechos). Se consume con `dw.vw_dw_balance_general` (snapshot a hoy) / `dw.vw_dw_estado_resultados` / `dw.vw_dw_estado_resultados_por_centro_costo` / `dw.vw_dw_margen_por_item` (estos 3 últimos, point-in-time desde v8).

## Despliegue desde cero

Ejecutar en SQL Server Management Studio (SSMS), **en este orden exacto**. El orden cambió en v3: Centros de Costo/Empleados y Contabilidad se adelantaron porque `tbl_asientos_detalle` y `tbl_productos_servicios` ahora dependen de ellos (ver [`CHANGELOG.md`](./CHANGELOG.md)):

```sql
-- 1. Terceros (prerrequisito de todo el modelo transaccional)
:r sql/crear_modulo_terceros.sql

-- 2. Centros de costo y empleados
:r sql/crear_modulo_centros_costo_empleados.sql

-- 3. Contabilidad y plan de cuentas (incluye TYPE + SP de asiento automático)
:r sql/crear_modulo_contabilidad_transacciones.sql

-- 4. Productos, servicios y BOM/CBS (incluye mapeo contable por ítem)
:r sql/crear_modulo_productos_servicios.sql

-- 5. Kardex de inventario y costeo directo (v4 - Costeo Directo por Flujo
--    de Venta; v7 - Kardex Real de Insumos). Requiere el paso 4
--    (tbl_productos_servicios, modo_obtencion, cat_insumos_recursos).
:r sql/crear_modulo_inventario_costeo.sql

-- 6. Transacciones granulares (compras, ventas, caja). tbl_compras_detalle
--    admite id_item O id_insumo desde v7 (requiere el paso 4).
:r sql/crear_tablas_transaccionales_granular.sql

-- 7. Tablas de mapeo / homologación (Fase 2; incluye map_insumos desde v7)
:r sql/crear_tablas_mapeo.sql

-- 8. Staging y auditoría de errores (Fase 3)
:r sql/crear_tabla_staging.sql
:r sql/crear_tabla_log_errores.sql

-- 9. Stored procedures
:r sql/sp_procesar_transaccion_externa.sql
:r sql/sp_procesar_etl_fase3.sql
:r sql/sp_prorratear_cif_periodo.sql

-- 10. Vistas de reporte (Control de Gestión)
:r sql/crear_vistas_reportes_gestion.sql

-- 11. Data Warehouse en Estrella (v5 - Fase B). Requiere todo lo anterior.
:r sql/crear_esquema_dw.sql
:r sql/sp_cargar_dw.sql
:r sql/crear_vistas_dw_consumo.sql
```

Tras el despliegue, para poblar el Data Warehouse por **primera vez** (bootstrap -- no hay nada todavía en `dw.tbl_control_carga_incremental`):

```sql
EXEC dw.sp_cargar_dw_completo;
```

Para refrescar el DW **de ahí en adelante** (operación rutinaria -- recomendado desde **v9**, trae solo lo nuevo desde `dbo`):

```sql
EXEC dw.sp_cargar_dw_incremental;
```

`dw.sp_cargar_dw_completo` sigue disponible para forzar una reconstrucción total (por ejemplo, si se corrige una fila histórica directamente en `dbo` con `UPDATE`/`DELETE` -- ver limitación v9 en [`CHANGELOG.md`](./CHANGELOG.md)).

Ver el detalle operativo completo en [`docs/manual_operacion_fase1.md`](./docs/manual_operacion_fase1.md) y [`docs/fase3_manual_operacion_fase3.md`](./docs/fase3_manual_operacion_fase3.md).

## Documentación

| Fase | Documento |
|---|---|
| Fase 1 (Core) | `docs/manual_operacion_fase1.md` |
| Fase 2 (Homologación) | `docs/manual_operacion_fase2.md` |
| Fase 3 (Motor ETL) | `docs/fase3_manual_operacion_fase3.md` |
| Módulos individuales | `docs/modulo_*.md` (incluye `docs/modulo_inventario_costeo.md` v4, `docs/modulo_dw.md` v5) |
