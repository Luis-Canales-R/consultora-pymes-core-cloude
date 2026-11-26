-- ============================================================================
-- Flujo de Caja Proyectado -- Reporte (vistas diaria/mensual/anual,
-- proyectado vs. real, historico).
--
-- Se apoya en lo construido en la Fase A (flujo_caja_fase_a_cxc_cxp.sql):
-- vw_cuentas_por_cobrar, vw_cuentas_por_pagar.
--
-- Diseño:
-- - vw_flujo_caja_movimientos: una fila por "evento" de caja, ya sea real
--   (un movimiento de tbl_movimientos_caja ya ocurrido) o proyectado (el
--   saldo pendiente de una venta/compra, en su fecha de vencimiento).
--   Los backend endpoints agrupan esta vista por dia/mes/año.
-- - Consolidado: se suman todas las cuentas bancarias juntas. Los traspasos
--   entre cuentas propias (TRASPASO_HASTA/TRASPASO_DESDE) se excluyen -- no
--   son entrada/salida real de dinero de la empresa.
-- - Documento vencido (fecha de vencimiento ya pasada y aun con saldo
--   pendiente): se reubica en la fecha de HOY, marcado con origen
--   PROYECTADO_VENCIDO, para que no desaparezca del radar.
-- - vw_flujo_caja_saldo_real_actual: el saldo real consolidado de Caja a la
--   fecha de hoy (punto de partida para proyectar saldo acumulado hacia
--   adelante).
--
-- Idempotente.
-- ============================================================================

USE consultora_pymes_core;
GO

-- 1. Vista base: un evento de caja por fila (real o proyectado)
CREATE OR ALTER VIEW vw_flujo_caja_movimientos AS
-- Reales: movimientos de Caja ya ocurridos (excluye traspasos entre cuentas propias)
SELECT
    m.fecha_movimiento AS fecha,
    m.tipo_flujo AS tipo_flujo,
    m.monto_absoluto AS monto,
    'REAL' AS origen,
    'CAJA' AS categoria,
    m.id_movimiento AS id_referencia
FROM tbl_movimientos_caja m
WHERE m.tipo_flujo IN ('INGRESO', 'EGRESO')

UNION ALL

-- Proyectado: Ventas con saldo pendiente, por fecha de vencimiento
-- (si ya vencio, se reubica en HOY marcado como PROYECTADO_VENCIDO)
SELECT
    CASE WHEN v.fecha_vencimiento < CAST(GETDATE() AS DATE) THEN CAST(GETDATE() AS DATE) ELSE v.fecha_vencimiento END AS fecha,
    'INGRESO' AS tipo_flujo,
    v.saldo_pendiente AS monto,
    CASE WHEN v.fecha_vencimiento < CAST(GETDATE() AS DATE) THEN 'PROYECTADO_VENCIDO' ELSE 'PROYECTADO' END AS origen,
    'VENTAS' AS categoria,
    v.id_venta_devengada AS id_referencia
FROM vw_cuentas_por_cobrar v
WHERE v.saldo_pendiente > 0 AND v.fecha_vencimiento IS NOT NULL

UNION ALL

-- Proyectado: Compras con saldo pendiente, por fecha de vencimiento de pago
SELECT
    CASE WHEN c.fecha_vencimiento_pago < CAST(GETDATE() AS DATE) THEN CAST(GETDATE() AS DATE) ELSE c.fecha_vencimiento_pago END AS fecha,
    'EGRESO' AS tipo_flujo,
    c.saldo_pendiente AS monto,
    CASE WHEN c.fecha_vencimiento_pago < CAST(GETDATE() AS DATE) THEN 'PROYECTADO_VENCIDO' ELSE 'PROYECTADO' END AS origen,
    'COMPRAS' AS categoria,
    c.id_orden_compra AS id_referencia
FROM vw_cuentas_por_pagar c
WHERE c.saldo_pendiente > 0 AND c.fecha_vencimiento_pago IS NOT NULL;
GO

-- 2. Saldo real consolidado de Caja a la fecha de hoy (todas las cuentas,
--    sin traspasos -- se cancelan entre si en el consolidado)
CREATE OR ALTER VIEW vw_flujo_caja_saldo_real_actual AS
SELECT
    ISNULL(SUM(CASE
        WHEN tipo_flujo = 'INGRESO' THEN monto_absoluto
        WHEN tipo_flujo = 'EGRESO' THEN -monto_absoluto
        ELSE 0
    END), 0) AS saldo_actual
FROM tbl_movimientos_caja
WHERE tipo_flujo IN ('INGRESO', 'EGRESO')
    AND fecha_movimiento <= CAST(GETDATE() AS DATE);
GO
