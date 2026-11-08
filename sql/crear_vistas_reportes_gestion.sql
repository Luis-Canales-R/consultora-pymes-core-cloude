-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Vistas de reporte financiero (Balance General y Estado de
--         Resultados), construidas sobre tbl_asientos_detalle.
-- ====================================================================
-- PRERREQUISITO: Ejecutar previamente sql/crear_modulo_contabilidad_
-- transacciones.sql (cat_plan_cuentas.tipo_cuenta, tbl_asientos_detalle.
-- id_centro_costo) y sql/crear_modulo_centros_costo_empleados.sql.
--
-- DISEÑO:
--   - vw_balance_general es una fotografía "a la fecha" (acumula TODOS
--     los asientos históricos), porque el Balance es un informe de
--     STOCK (saldo en un punto del tiempo), no de flujo. Por eso NO se
--     filtra por periodo_contable.
--   - vw_estado_resultados y vw_estado_resultados_por_centro_costo son
--     informes de FLUJO: se agrupan por periodo_contable (y, en la
--     segunda, también por centro de costo) porque un resultado se mide
--     siempre "durante" un periodo, no "a la fecha".
--   - El saldo de cada cuenta respeta su naturaleza contable: para una
--     cuenta DEUDORA el saldo crece con el Debe; para una ACREEDORA,
--     crece con el Haber. Sumar ambos tipos sin este ajuste produciría
--     un Balance descuadrado.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.vw_balance_general', 'V') IS NOT NULL DROP VIEW dbo.vw_balance_general;
GO
CREATE VIEW dbo.vw_balance_general AS
SELECT
    cp.id_cuenta,
    cp.codigo_cuenta,
    cp.nombre_cuenta,
    cp.tipo_cuenta,
    cp.naturaleza,
    CASE WHEN cp.naturaleza = 'DEUDORA'
         THEN ISNULL(SUM(d.debe), 0.00) - ISNULL(SUM(d.haber), 0.00)
         ELSE ISNULL(SUM(d.haber), 0.00) - ISNULL(SUM(d.debe), 0.00)
    END AS saldo
FROM dbo.cat_plan_cuentas cp
LEFT JOIN dbo.tbl_asientos_detalle d ON d.id_cuenta = cp.id_cuenta
WHERE cp.es_imputable = 1
  AND cp.tipo_cuenta IN ('ACTIVO', 'PASIVO', 'PATRIMONIO')
GROUP BY cp.id_cuenta, cp.codigo_cuenta, cp.nombre_cuenta, cp.tipo_cuenta, cp.naturaleza;
GO

IF OBJECT_ID('dbo.vw_estado_resultados', 'V') IS NOT NULL DROP VIEW dbo.vw_estado_resultados;
GO
CREATE VIEW dbo.vw_estado_resultados AS
SELECT
    a.periodo_contable,
    cp.tipo_cuenta,
    cp.id_cuenta,
    cp.codigo_cuenta,
    cp.nombre_cuenta,
    CASE WHEN cp.tipo_cuenta = 'INGRESO'
         THEN ISNULL(SUM(d.haber), 0.00) - ISNULL(SUM(d.debe), 0.00)
         ELSE ISNULL(SUM(d.debe), 0.00) - ISNULL(SUM(d.haber), 0.00)
    END AS monto_periodo
FROM dbo.tbl_asientos_detalle d
INNER JOIN dbo.tbl_asientos_cabecera a ON a.id_asiento = d.id_asiento
INNER JOIN dbo.cat_plan_cuentas cp ON cp.id_cuenta = d.id_cuenta
WHERE cp.tipo_cuenta IN ('INGRESO', 'COSTO', 'GASTO')
GROUP BY a.periodo_contable, cp.tipo_cuenta, cp.id_cuenta, cp.codigo_cuenta, cp.nombre_cuenta;
GO

-- ====================================================================
-- (Control de Gestión) Estado de Resultados segmentado por Centro de
-- Costo: es la vista que justifica haber agregado id_centro_costo a
-- tbl_asientos_detalle. Las líneas de balance (Clientes, Proveedores,
-- Banco, IVA) normalmente NO llevan centro de costo (quedan NULL) y por
-- eso esta vista solo tiene sentido para INGRESO/COSTO/GASTO.
-- ====================================================================
IF OBJECT_ID('dbo.vw_estado_resultados_por_centro_costo', 'V') IS NOT NULL DROP VIEW dbo.vw_estado_resultados_por_centro_costo;
GO
CREATE VIEW dbo.vw_estado_resultados_por_centro_costo AS
SELECT
    a.periodo_contable,
    ISNULL(cc.codigo_cc, 'SIN_CC')     AS codigo_cc,
    ISNULL(cc.nombre_cc, 'Sin Centro de Costo Asignado') AS nombre_cc,
    cp.tipo_cuenta,
    cp.id_cuenta,
    cp.codigo_cuenta,
    cp.nombre_cuenta,
    CASE WHEN cp.tipo_cuenta = 'INGRESO'
         THEN ISNULL(SUM(d.haber), 0.00) - ISNULL(SUM(d.debe), 0.00)
         ELSE ISNULL(SUM(d.debe), 0.00) - ISNULL(SUM(d.haber), 0.00)
    END AS monto_periodo
FROM dbo.tbl_asientos_detalle d
INNER JOIN dbo.tbl_asientos_cabecera a ON a.id_asiento = d.id_asiento
INNER JOIN dbo.cat_plan_cuentas cp ON cp.id_cuenta = d.id_cuenta
LEFT JOIN dbo.tbl_centros_costo cc ON cc.id_centro_costo = d.id_centro_costo
WHERE cp.tipo_cuenta IN ('INGRESO', 'COSTO', 'GASTO')
GROUP BY a.periodo_contable, cc.codigo_cc, cc.nombre_cc, cp.tipo_cuenta, cp.id_cuenta, cp.codigo_cuenta, cp.nombre_cuenta;
GO

-- ====================================================================
-- VALIDACIÓN DE CUADRATURA: Activo = Pasivo + Patrimonio (+ Resultado
-- del Ejercicio acumulado implícito en el Estado de Resultados). Útil
-- como chequeo rápido tras cada corrida de ETL.
-- ====================================================================
-- SELECT
--     (SELECT ISNULL(SUM(saldo), 0) FROM dbo.vw_balance_general WHERE tipo_cuenta = 'ACTIVO')      AS total_activo,
--     (SELECT ISNULL(SUM(saldo), 0) FROM dbo.vw_balance_general WHERE tipo_cuenta = 'PASIVO')      AS total_pasivo,
--     (SELECT ISNULL(SUM(saldo), 0) FROM dbo.vw_balance_general WHERE tipo_cuenta = 'PATRIMONIO')  AS total_patrimonio,
--     (SELECT ISNULL(SUM(monto_periodo), 0) FROM dbo.vw_estado_resultados WHERE tipo_cuenta = 'INGRESO')
--       - (SELECT ISNULL(SUM(monto_periodo), 0) FROM dbo.vw_estado_resultados WHERE tipo_cuenta IN ('COSTO','GASTO')) AS resultado_acumulado;

PRINT 'Vistas vw_balance_general, vw_estado_resultados y vw_estado_resultados_por_centro_costo creadas exitosamente.';
GO
