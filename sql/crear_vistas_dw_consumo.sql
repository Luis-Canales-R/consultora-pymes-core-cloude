-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Vistas de Consumo del Data Warehouse (Capa 4: Consumo y
--         Gobierno de Accesos) -- Fase B
-- ====================================================================
-- PRERREQUISITO: sql/crear_esquema_dw.sql y sql/sp_cargar_dw.sql deben
-- estar ejecutados, y dw.sp_cargar_dw_completo debe haberse corrido al
-- menos una vez (estas vistas leen de dw.fact_asientos_contables, no del
-- esquema transaccional).
--
-- PROPÓSITO: demostrar -- y dejar disponible para BI/consumo -- que
-- Balance General y Estado de Resultados se pueden reconstruir
-- EXACTAMENTE igual desde la tabla de hechos central (fact_asientos_
-- contables) que desde el OLTP (dbo.tbl_asientos_detalle). La lógica de
-- cálculo es intencionalmente idéntica a dbo.vw_balance_general /
-- dbo.vw_estado_resultados (ver sql/crear_vistas_reportes_gestion.sql);
-- solo cambia la fuente (dw.* en vez de dbo.*).
--
-- v8 (SCD Tipo 2) -- criterio de join usado en cada vista:
--   - Balance General: snapshot "a hoy". Suma TODO el histórico de cada
--     cuenta (join por clave NATURAL, sin filtrar por fecha) pero la
--     muestra con su clasificación VIGENTE hoy (dc.es_vigente = 1) --
--     igual convención que un plan de cuentas reclasificado en un
--     sistema contable real: no se reexpresa el balance acumulado con
--     clasificaciones antiguas.
--   - Estado de Resultados (global y por centro de costo) y Margen por
--     Ítem: reportes POR PERIODO. Se unen por la clave SURROGADA (sk_*)
--     que cada hecho ya resolvió point-in-time al cargarse (ver
--     sp_cargar_dw.sql) -- así, si una cuenta o un ítem cambió de
--     clasificación entre dos periodos, cada periodo reporta con la
--     clasificación que tenía VIGENTE EN ESE MOMENTO, no con la actual.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dw.vw_dw_balance_general', 'V') IS NOT NULL DROP VIEW dw.vw_dw_balance_general;
GO
CREATE VIEW dw.vw_dw_balance_general AS
SELECT
    dc.id_cuenta,
    dc.codigo_cuenta,
    dc.nombre_cuenta,
    dc.tipo_cuenta,
    dc.naturaleza,
    CASE WHEN dc.naturaleza = 'DEUDORA'
         THEN ISNULL(SUM(f.debe), 0.00) - ISNULL(SUM(f.haber), 0.00)
         ELSE ISNULL(SUM(f.haber), 0.00) - ISNULL(SUM(f.debe), 0.00)
    END AS saldo
FROM dw.dim_cuenta_contable dc
LEFT JOIN dw.fact_asientos_contables f ON f.id_cuenta = dc.id_cuenta -- v8: por clave NATURAL, suma todo el histórico de la cuenta
WHERE dc.es_vigente = 1 -- v8: se muestra con la clasificación VIGENTE hoy (snapshot a la fecha)
  AND dc.es_imputable = 1
  AND dc.tipo_cuenta IN ('ACTIVO', 'PASIVO', 'PATRIMONIO')
GROUP BY dc.id_cuenta, dc.codigo_cuenta, dc.nombre_cuenta, dc.tipo_cuenta, dc.naturaleza;
GO

IF OBJECT_ID('dw.vw_dw_estado_resultados', 'V') IS NOT NULL DROP VIEW dw.vw_dw_estado_resultados;
GO
CREATE VIEW dw.vw_dw_estado_resultados AS
SELECT
    f.periodo_contable,
    dc.tipo_cuenta,
    dc.id_cuenta,
    dc.codigo_cuenta,
    dc.nombre_cuenta,
    CASE WHEN dc.tipo_cuenta = 'INGRESO'
         THEN ISNULL(SUM(f.haber), 0.00) - ISNULL(SUM(f.debe), 0.00)
         ELSE ISNULL(SUM(f.debe), 0.00) - ISNULL(SUM(f.haber), 0.00)
    END AS monto_periodo
FROM dw.fact_asientos_contables f
INNER JOIN dw.dim_cuenta_contable dc ON dc.sk_cuenta_contable = f.sk_cuenta_contable -- v8: point-in-time (clasificación vigente AL MOMENTO del asiento)
WHERE dc.tipo_cuenta IN ('INGRESO', 'COSTO', 'GASTO')
GROUP BY f.periodo_contable, dc.tipo_cuenta, dc.id_cuenta, dc.codigo_cuenta, dc.nombre_cuenta;
GO

IF OBJECT_ID('dw.vw_dw_estado_resultados_por_centro_costo', 'V') IS NOT NULL DROP VIEW dw.vw_dw_estado_resultados_por_centro_costo;
GO
CREATE VIEW dw.vw_dw_estado_resultados_por_centro_costo AS
SELECT
    f.periodo_contable,
    ISNULL(cc.codigo_cc, 'SIN_CC') AS codigo_cc,
    ISNULL(cc.nombre_cc, 'Sin Centro de Costo Asignado') AS nombre_cc,
    dc.tipo_cuenta,
    dc.id_cuenta,
    dc.codigo_cuenta,
    dc.nombre_cuenta,
    CASE WHEN dc.tipo_cuenta = 'INGRESO'
         THEN ISNULL(SUM(f.haber), 0.00) - ISNULL(SUM(f.debe), 0.00)
         ELSE ISNULL(SUM(f.debe), 0.00) - ISNULL(SUM(f.haber), 0.00)
    END AS monto_periodo
FROM dw.fact_asientos_contables f
INNER JOIN dw.dim_cuenta_contable dc ON dc.sk_cuenta_contable = f.sk_cuenta_contable -- v8: point-in-time
LEFT JOIN dw.dim_centro_costo cc ON cc.sk_centro_costo = f.sk_centro_costo -- v8: point-in-time
WHERE dc.tipo_cuenta IN ('INGRESO', 'COSTO', 'GASTO')
GROUP BY f.periodo_contable, cc.codigo_cc, cc.nombre_cc, dc.tipo_cuenta, dc.id_cuenta, dc.codigo_cuenta, dc.nombre_cuenta;
GO

-- ====================================================================
-- (v4 / Fase B) Margen de contribución por producto / periodo, directo
-- desde fact_margen_venta. Complementa el Estado de Resultados: muestra
-- el margen YA NETO del costeo directo por flujo de venta, sin necesidad
-- de volver a calcular CPP ni MOD+MPD en cada consulta de BI.
-- ====================================================================
IF OBJECT_ID('dw.vw_dw_margen_por_item', 'V') IS NOT NULL DROP VIEW dw.vw_dw_margen_por_item;
GO
CREATE VIEW dw.vw_dw_margen_por_item AS
SELECT
    dt.periodo_contable,
    di.id_item,
    di.sku_codigo,
    di.nombre,
    di.modo_obtencion, -- v8: point-in-time (modo_obtencion vigente AL MOMENTO de cada venta, vía sk_item -- no el actual)
    SUM(m.cantidad)              AS cantidad_vendida,
    SUM(m.ingreso_neto)          AS ingreso_neto,
    SUM(m.costo_directo)         AS costo_directo,
    SUM(m.margen_contribucion)   AS margen_contribucion
FROM dw.fact_margen_venta m
INNER JOIN dw.dim_item di ON di.sk_item = m.sk_item -- v8: point-in-time
INNER JOIN dw.dim_tiempo dt ON dt.id_fecha = m.id_fecha
GROUP BY dt.periodo_contable, di.id_item, di.sku_codigo, di.nombre, di.modo_obtencion;
GO

-- ====================================================================
-- VALIDACIÓN DE PARIDAD OLTP vs. DW: si el DW está al día (se corrió
-- dw.sp_cargar_dw_completo después de la última carga transaccional),
-- estas dos consultas deben devolver EXACTAMENTE los mismos totales.
-- Útil como chequeo de integridad tras cada refresh del DW.
-- ====================================================================
-- SELECT 'OLTP' AS fuente, tipo_cuenta, SUM(saldo) AS total FROM dbo.vw_balance_general GROUP BY tipo_cuenta
-- UNION ALL
-- SELECT 'DW'   AS fuente, tipo_cuenta, SUM(saldo) AS total FROM dw.vw_dw_balance_general GROUP BY tipo_cuenta
-- ORDER BY tipo_cuenta, fuente;

PRINT 'Vistas de consumo del Data Warehouse (dw.vw_dw_*) creadas exitosamente.';
GO
