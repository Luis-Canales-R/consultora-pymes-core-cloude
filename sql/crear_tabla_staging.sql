-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs (Fase 3)
-- Objeto: Creación de la Tabla de Staging para Carga Masiva
-- ====================================================================
-- NOTA DE DISEÑO (v2):
-- La tabla recibe las filas CRUDAS de las 3 pestañas operativas del Excel
-- (Ventas_Devengadas, Compras_y_Gastos, Movimientos_Caja). Por eso:
--   a) Incluye nombre_archivo y pestana_origen para poder aislar cada
--      corrida de carga y evitar cruces entre ejecuciones distintas.
--   b) Los campos variables (fecha, cantidad, montos) se guardan como
--      VARCHAR "crudos", NO tipados. Si se tipan en el staging
--      (ej. DATE o DECIMAL), SQL Server rechaza la fila completa en el
--      INSERT cuando el formato viene mal desde el Excel, y el motor ETL
--      nunca llega a auditar ese error en tbl_log_errores_etl.
--      La conversión y validación de formato ocurre en el stored
--      procedure sp_procesar_etl_fase3.
-- ====================================================================

USE consultora_pymes_core;
GO

-- 1. Eliminación previa si existe
IF OBJECT_ID('dbo.tbl_staging_carga', 'U') IS NOT NULL
    DROP TABLE dbo.tbl_staging_carga;
GO

-- 2. Creación de la tabla de staging que recibe los datos crudos del Excel
CREATE TABLE dbo.tbl_staging_carga (
    id_staging INT IDENTITY(1,1) PRIMARY KEY,

    -- Identificación de la corrida de carga (aísla una ejecución de otra)
    nombre_archivo VARCHAR(150) NOT NULL,
    pestana_origen VARCHAR(50) NOT NULL
        CHECK (pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos', 'Movimientos_Caja')),
    numero_fila INT NOT NULL,

    -- Campos comunes a Ventas_Devengadas / Compras_y_Gastos
    folio_documento_raw VARCHAR(50) NULL,       -- Folio Factura / Folio OC
    tercero_informal_raw VARCHAR(150) NULL,     -- Cliente o Proveedor (texto libre a homologar)
    item_informal_raw VARCHAR(150) NULL,        -- Ítem/Servicio o Insumo (texto libre a homologar)
    cantidad_raw VARCHAR(50) NULL,
    precio_unitario_raw VARCHAR(50) NULL,
    estado_documento_raw VARCHAR(30) NULL,      -- Estado Venta / Estado OC

    -- Campos específicos de Movimientos_Caja
    cuenta_bancaria_raw VARCHAR(50) NULL,       -- Código de cuenta bancaria (cat_plan_cuentas)
    tipo_flujo_raw VARCHAR(30) NULL,            -- INGRESO, EGRESO, TRASPASO_HASTA, TRASPASO_DESDE
    monto_absoluto_raw VARCHAR(50) NULL,

    -- Campos comunes de fecha / monto total / glosa
    fecha_raw VARCHAR(20) NULL,                 -- Se exige AAAA-MM-DD, pero se guarda como texto
    monto_total_raw VARCHAR(50) NULL,
    glosa VARCHAR(250) NULL,

    -- v3 (Control de Gestión): dimensiones de imputación, comunes a las 3
    -- pestañas. Se validan contra codigo_cc / rut_dni directamente (no son
    -- texto libre a homologar como tercero/ítem): el Excel debe traer el
    -- código real. Ambas son opcionales para no bloquear cargas sin esta
    -- información (quedan NULL en Core y en el asiento contable).
    centro_costo_raw VARCHAR(30) NULL,          -- codigo_cc (tbl_centros_costo)
    empleado_raw VARCHAR(20) NULL,              -- rut_dni (tbl_empleados_usuarios)

    -- Control de procesamiento
    estado_carga VARCHAR(30) NOT NULL DEFAULT 'PENDIENTE'
        CHECK (estado_carga IN ('PENDIENTE', 'CARGADO', 'RECHAZADO')),
    fecha_proceso DATETIME NULL,
    created_at DATETIME DEFAULT GETDATE()
);
GO

-- 3. Índice de apoyo para que el motor ETL filtre por corrida de carga
CREATE INDEX IX_staging_archivo_pestana
ON dbo.tbl_staging_carga (nombre_archivo, pestana_origen, estado_carga);
GO

PRINT 'Tabla tbl_staging_carga (v2, multi-pestaña) creada exitosamente en consultora_pymes_core.';
GO
