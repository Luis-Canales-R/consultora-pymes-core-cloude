-- ============================================================================
-- Flujo de Caja Proyectado -- cascada por cuenta contable: columna manual
-- para movimientos de Caja que NO nacen de una Venta ni de una Compra/Gasto
-- (aportes de capital, préstamos recibidos, reembolsos contra boleta, etc.)
-- Confirmado con el usuario 2026-11-25: "a veces un ingreso nace de un
-- aporte y un egreso puede ser un préstamo o reembolso contra boleta... se
-- debe tener la opción para registrarlo".
--
-- Para los movimientos que SÍ vienen de una Venta/Compra, la cuenta
-- contable correcta se obtiene vía tbl_aplicaciones_pago -> el detalle de
-- línea del documento -> tbl_productos_servicios.id_cuenta_ingreso /
-- id_cuenta_costo_gasto (ya existente) -- no necesitan esta columna.
--
-- Idempotente.
-- ============================================================================

USE consultora_pymes_core;
GO

-- Limpieza: las vistas de la primera versión del reporte (filas=fechas) se
-- reemplazan por la cascada por cuenta contable, calculada en el backend
-- (requiere prorratear cada documento entre sus líneas/cuentas, más
-- manejable en Python que en una vista SQL). Si corriste
-- flujo_caja_fase_reporte.sql antes, esto limpia esas 2 vistas que ya no
-- se usan.
IF OBJECT_ID('vw_flujo_caja_movimientos', 'V') IS NOT NULL DROP VIEW vw_flujo_caja_movimientos;
IF OBJECT_ID('vw_flujo_caja_saldo_real_actual', 'V') IS NOT NULL DROP VIEW vw_flujo_caja_saldo_real_actual;
GO

IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'tbl_movimientos_caja' AND COLUMN_NAME = 'id_cuenta_contable'
)
BEGIN
    ALTER TABLE tbl_movimientos_caja ADD id_cuenta_contable INT NULL;
    ALTER TABLE tbl_movimientos_caja ADD CONSTRAINT fk_caja_cuenta_contable
        FOREIGN KEY (id_cuenta_contable) REFERENCES cat_plan_cuentas(id_cuenta);
    PRINT 'Columna id_cuenta_contable agregada a tbl_movimientos_caja.';
END
ELSE
    PRINT 'tbl_movimientos_caja.id_cuenta_contable ya existía -- no se hizo nada.';
GO
