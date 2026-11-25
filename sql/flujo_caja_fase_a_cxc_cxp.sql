-- ============================================================================
-- Flujo de Caja Proyectado -- Fase A: Cuentas por Cobrar (Ventas) y
-- Cuentas por Pagar (Compras), con aplicacion de pagos (soporta pagos
-- parciales desde el inicio, por decision explicita del usuario 2026-11-25).
--
-- Diseño (patron estandar de ERP -- "cash application"):
-- - tbl_aplicaciones_pago vincula un movimiento de Caja real con el
--   documento (venta o compra) que liquida, por un monto especifico. Un
--   mismo movimiento puede repartirse entre varios documentos, y un mismo
--   documento puede recibir varios abonos -- ambos casos (pago parcial y
--   pago que cubre varias facturas) se resuelven con la misma tabla.
-- - El saldo pendiente de una venta/compra NO se guarda como columna --
--   se calcula siempre como monto_total menos la suma de aplicaciones
--   activas (vw_cuentas_por_cobrar / vw_cuentas_por_pagar). Asi nunca
--   queda desincronizado.
-- - Corregir un error (ej. un ingreso aplicado a la compra equivocada) se
--   hace desactivando la fila de aplicacion (estado_activo = 0) -- nunca
--   se borra fisicamente, mismo patron de auditoria que el resto del
--   proyecto. El saldo pendiente del documento se recalcula solo al
--   desactivarla.
--
-- Idempotente.
-- ============================================================================

USE consultora_pymes_core;
GO

-- 1. Fecha de vencimiento de pago en Compras (Ventas ya la tiene: fecha_vencimiento)
IF NOT EXISTS (
    SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_NAME = 'tbl_ordenes_compra' AND COLUMN_NAME = 'fecha_vencimiento_pago'
)
BEGIN
    ALTER TABLE tbl_ordenes_compra ADD fecha_vencimiento_pago DATE NULL;
    PRINT 'Columna fecha_vencimiento_pago agregada a tbl_ordenes_compra.';
END
ELSE
    PRINT 'tbl_ordenes_compra.fecha_vencimiento_pago ya existia -- no se hizo nada.';
GO

-- 2. Tabla de aplicaciones de pago (cash application)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'tbl_aplicaciones_pago')
BEGIN
    CREATE TABLE tbl_aplicaciones_pago (
        id_aplicacion INT IDENTITY(1,1) PRIMARY KEY,
        id_movimiento INT NOT NULL,
        tipo_documento VARCHAR(10) NOT NULL,
        id_venta_devengada INT NULL,
        id_orden_compra INT NULL,
        monto_aplicado DECIMAL(18,2) NOT NULL,
        fecha_aplicacion DATETIME NOT NULL DEFAULT GETDATE(),
        estado_activo BIT NOT NULL DEFAULT 1,
        observacion VARCHAR(255) NULL,
        created_at DATETIME NOT NULL DEFAULT GETDATE(),
        CONSTRAINT fk_aplic_movimiento FOREIGN KEY (id_movimiento) REFERENCES tbl_movimientos_caja(id_movimiento),
        CONSTRAINT fk_aplic_venta FOREIGN KEY (id_venta_devengada) REFERENCES tbl_ventas_devengadas(id_venta_devengada),
        CONSTRAINT fk_aplic_compra FOREIGN KEY (id_orden_compra) REFERENCES tbl_ordenes_compra(id_orden_compra),
        CONSTRAINT ck_aplic_tipo CHECK (tipo_documento IN ('VENTA', 'COMPRA')),
        CONSTRAINT ck_aplic_doc_exclusivo CHECK (
            (tipo_documento = 'VENTA' AND id_venta_devengada IS NOT NULL AND id_orden_compra IS NULL) OR
            (tipo_documento = 'COMPRA' AND id_orden_compra IS NOT NULL AND id_venta_devengada IS NULL)
        ),
        CONSTRAINT ck_aplic_monto_positivo CHECK (monto_aplicado > 0)
    );
    PRINT 'Tabla tbl_aplicaciones_pago creada.';
END
ELSE
    PRINT 'tbl_aplicaciones_pago ya existia -- no se hizo nada.';
GO

-- 3. Vista: Cuentas por Cobrar (Ventas) con saldo pendiente y estado de pago
CREATE OR ALTER VIEW vw_cuentas_por_cobrar AS
SELECT
    v.id_venta_devengada,
    v.folio_factura,
    v.id_tercero,
    v.fecha_emision,
    v.fecha_vencimiento,
    v.monto_total,
    ISNULL(ap.monto_aplicado_total, 0) AS monto_aplicado,
    v.monto_total - ISNULL(ap.monto_aplicado_total, 0) AS saldo_pendiente,
    CASE
        WHEN v.monto_total - ISNULL(ap.monto_aplicado_total, 0) <= 0 THEN 'PAGADO'
        WHEN ISNULL(ap.monto_aplicado_total, 0) > 0 THEN 'PARCIAL'
        ELSE 'PENDIENTE'
    END AS estado_pago,
    v.id_centro_costo
FROM tbl_ventas_devengadas v
LEFT JOIN (
    SELECT id_venta_devengada, SUM(monto_aplicado) AS monto_aplicado_total
    FROM tbl_aplicaciones_pago
    WHERE estado_activo = 1 AND tipo_documento = 'VENTA'
    GROUP BY id_venta_devengada
) ap ON ap.id_venta_devengada = v.id_venta_devengada;
GO

-- 4. Vista: Cuentas por Pagar (Compras) con saldo pendiente y estado de pago
CREATE OR ALTER VIEW vw_cuentas_por_pagar AS
SELECT
    c.id_orden_compra,
    c.folio_oc,
    c.id_tercero,
    c.fecha_emision,
    c.fecha_vencimiento_pago,
    c.monto_total,
    ISNULL(ap.monto_aplicado_total, 0) AS monto_aplicado,
    c.monto_total - ISNULL(ap.monto_aplicado_total, 0) AS saldo_pendiente,
    CASE
        WHEN c.monto_total - ISNULL(ap.monto_aplicado_total, 0) <= 0 THEN 'PAGADO'
        WHEN ISNULL(ap.monto_aplicado_total, 0) > 0 THEN 'PARCIAL'
        ELSE 'PENDIENTE'
    END AS estado_pago,
    c.id_centro_costo
FROM tbl_ordenes_compra c
LEFT JOIN (
    SELECT id_orden_compra, SUM(monto_aplicado) AS monto_aplicado_total
    FROM tbl_aplicaciones_pago
    WHERE estado_activo = 1 AND tipo_documento = 'COMPRA'
    GROUP BY id_orden_compra
) ap ON ap.id_orden_compra = c.id_orden_compra;
GO

-- 5. Vista: saldo disponible para aplicar de cada movimiento de Caja
--    (cuanto de ese ingreso/egreso ya se aplico contra algun documento, y
--    cuanto queda libre -- necesaria para la pantalla de "aplicar pago" y
--    para no permitir sobre-aplicar un mismo movimiento).
CREATE OR ALTER VIEW vw_movimientos_caja_saldo_aplicacion AS
SELECT
    m.id_movimiento,
    m.fecha_movimiento,
    m.tipo_flujo,
    m.id_tercero,
    m.monto_absoluto,
    ISNULL(ap.monto_aplicado_total, 0) AS monto_aplicado,
    m.monto_absoluto - ISNULL(ap.monto_aplicado_total, 0) AS monto_disponible
FROM tbl_movimientos_caja m
LEFT JOIN (
    SELECT id_movimiento, SUM(monto_aplicado) AS monto_aplicado_total
    FROM tbl_aplicaciones_pago
    WHERE estado_activo = 1
    GROUP BY id_movimiento
) ap ON ap.id_movimiento = m.id_movimiento;
GO
