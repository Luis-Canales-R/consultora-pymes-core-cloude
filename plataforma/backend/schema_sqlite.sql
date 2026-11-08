-- ============================================================================
-- schema_sqlite.sql
-- Esquema LOCAL de desarrollo para la Plataforma de Control de Gestión.
--
-- Este NO reemplaza el esquema SQL Server (carpeta /sql del proyecto, que
-- sigue siendo la fuente de verdad del modelo completo con SCD2, costeo
-- point-in-time, CIF, etc.). Es una versión reducida en SQLite, pensada para
-- correr la plataforma localmente sin depender de una instancia de SQL
-- Server. Usa los MISMOS nombres de tabla y columna que el esquema real
-- donde el alcance coincide, para que migrar a SQL Server más adelante sea
-- un cambio de driver, no de modelo.
--
-- Simplificaciones respecto al esquema SQL Server real:
--   - tbl_terceros: roles (cliente/proveedor) como columnas booleanas en vez
--     de la tabla puente rel_terceros_roles (N:M).
--   - Compras: una tabla plana tbl_compras_gastos (como la pestaña Excel
--     "Compras_y_Gastos"), sin el detalle tbl_ordenes_compra/
--     tbl_compras_detalle línea por línea.
--   - Sin costeo por kardex, SCD2, ni Data Warehouse: el dashboard calcula
--     agregados directos sobre las tablas operativas, no sobre dw.fact_*.
--   - Sin motor de asientos contables automático (eso vive en el ETL/SP de
--     SQL Server); esta plataforma es la capa de CAPTURA que alimentaría ese
--     ETL en producción.
-- ============================================================================

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tbl_centros_costo (
    id_centro_costo INTEGER PRIMARY KEY AUTOINCREMENT,
    nombre          TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS tbl_terceros (
    id_tercero      INTEGER PRIMARY KEY AUTOINCREMENT,
    codigo_tercero  TEXT NOT NULL UNIQUE,
    razon_social    TEXT NOT NULL,
    rut_dni         TEXT NOT NULL UNIQUE,
    es_cliente      INTEGER NOT NULL DEFAULT 0,
    es_proveedor    INTEGER NOT NULL DEFAULT 0,
    contacto_email  TEXT,
    estado_activo   INTEGER NOT NULL DEFAULT 1,
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tbl_productos_servicios (
    id_item             INTEGER PRIMARY KEY AUTOINCREMENT,
    sku_codigo          TEXT NOT NULL UNIQUE,
    nombre              TEXT NOT NULL,
    precio_venta_base   REAL NOT NULL,
    modo_obtencion      TEXT CHECK (modo_obtencion IN ('COMPRADO_REVENTA','FABRICADO','SERVICIO')),
    estado_activo       INTEGER NOT NULL DEFAULT 1,
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tbl_ventas_devengadas (
    id_venta_devengada  INTEGER PRIMARY KEY AUTOINCREMENT,
    folio_factura       TEXT NOT NULL UNIQUE,
    id_tercero          INTEGER NOT NULL REFERENCES tbl_terceros(id_tercero),
    id_centro_costo     INTEGER REFERENCES tbl_centros_costo(id_centro_costo),
    fecha_emision       TEXT NOT NULL,
    monto_neto          REAL NOT NULL,
    monto_iva           REAL NOT NULL,
    monto_total         REAL NOT NULL,
    estado_venta        TEXT NOT NULL DEFAULT 'DEVENGADO'
                         CHECK (estado_venta IN ('DEVENGADO','FACTURADO','PAGADO','ANULADO')),
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tbl_compras_gastos (
    id_compra           INTEGER PRIMARY KEY AUTOINCREMENT,
    folio_documento      TEXT NOT NULL UNIQUE,
    id_tercero          INTEGER NOT NULL REFERENCES tbl_terceros(id_tercero),
    id_centro_costo     INTEGER REFERENCES tbl_centros_costo(id_centro_costo),
    fecha_emision       TEXT NOT NULL,
    descripcion         TEXT NOT NULL,
    monto_neto          REAL NOT NULL,
    monto_iva           REAL NOT NULL,
    monto_total         REAL NOT NULL,
    estado_compra       TEXT NOT NULL DEFAULT 'RECIBIDA'
                         CHECK (estado_compra IN ('BORRADOR','APROBADA','RECIBIDA','ANULADA')),
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS tbl_movimientos_caja (
    id_movimiento       INTEGER PRIMARY KEY AUTOINCREMENT,
    fecha_movimiento    TEXT NOT NULL,
    tipo_flujo          TEXT NOT NULL
                         CHECK (tipo_flujo IN ('INGRESO','EGRESO','TRASPASO_HASTA','TRASPASO_DESDE')),
    monto_absoluto      REAL NOT NULL CHECK (monto_absoluto > 0),
    glosa_movimiento    TEXT NOT NULL,
    id_tercero          INTEGER REFERENCES tbl_terceros(id_tercero),
    id_centro_costo     INTEGER REFERENCES tbl_centros_costo(id_centro_costo),
    created_at          TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS ix_ventas_fecha  ON tbl_ventas_devengadas(fecha_emision);
CREATE INDEX IF NOT EXISTS ix_compras_fecha ON tbl_compras_gastos(fecha_emision);
CREATE INDEX IF NOT EXISTS ix_caja_fecha    ON tbl_movimientos_caja(fecha_movimiento);
