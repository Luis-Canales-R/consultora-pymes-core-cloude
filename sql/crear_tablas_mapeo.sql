-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs (Fase 2)
-- Objeto: Creación de las Tablas de Homologación (`map_clientes`, `map_productos`)
-- ====================================================================
-- PRERREQUISITOS: Ejecutar previamente, en este orden:
--   1) sql/crear_modulo_terceros.sql            (tbl_terceros)
--   2) sql/crear_modulo_productos_servicios.sql (tbl_productos_servicios)
-- ====================================================================

USE consultora_pymes_core;
GO

-- 1. Eliminación previa si existen (orden inverso de dependencia)
IF OBJECT_ID('dbo.map_insumos', 'U') IS NOT NULL
    DROP TABLE dbo.map_insumos;
GO

IF OBJECT_ID('dbo.map_productos', 'U') IS NOT NULL
    DROP TABLE dbo.map_productos;
GO

IF OBJECT_ID('dbo.map_clientes', 'U') IS NOT NULL
    DROP TABLE dbo.map_clientes;
GO

-- ==========================================
-- 2. MAPEO DE CLIENTES / TERCEROS (Alias informal -> ID Oficial)
-- ==========================================
CREATE TABLE dbo.map_clientes (
    id_map_cliente INT IDENTITY(1,1) PRIMARY KEY,
    nombre_informal_excel VARCHAR(150) NOT NULL,
    id_tercero_oficial INT NOT NULL,
    observaciones VARCHAR(255) NULL,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT uq_map_clientes_informal UNIQUE (nombre_informal_excel),
    CONSTRAINT fk_map_clientes_tercero FOREIGN KEY (id_tercero_oficial) REFERENCES dbo.tbl_terceros(id_tercero)
);
GO

-- ==========================================
-- 3. MAPEO DE PRODUCTOS Y SERVICIOS (Descripción libre -> SKU Oficial)
-- ==========================================
CREATE TABLE dbo.map_productos (
    id_map_producto INT IDENTITY(1,1) PRIMARY KEY,
    descripcion_libre_excel VARCHAR(150) NOT NULL,
    id_item_oficial INT NOT NULL,
    observaciones VARCHAR(255) NULL,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT uq_map_productos_libre UNIQUE (descripcion_libre_excel),
    CONSTRAINT fk_map_productos_item FOREIGN KEY (id_item_oficial) REFERENCES dbo.tbl_productos_servicios(id_item)
);
GO

-- ==========================================
-- 4. MAPEO DE INSUMOS (Descripción libre -> Insumo Oficial) -- v7
-- Mismo patrón que map_productos. Solo se usa en la pestaña
-- Compras_y_Gastos: un insumo nunca se "vende" directamente, solo se
-- compra y se consume internamente (vía kardex) al vender un producto
-- FABRICADO o prestar un SERVICIO.
-- ==========================================
CREATE TABLE dbo.map_insumos (
    id_map_insumo INT IDENTITY(1,1) PRIMARY KEY,
    descripcion_libre_excel VARCHAR(150) NOT NULL,
    id_insumo_oficial INT NOT NULL,
    observaciones VARCHAR(255) NULL,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT uq_map_insumos_libre UNIQUE (descripcion_libre_excel),
    CONSTRAINT fk_map_insumos_insumo FOREIGN KEY (id_insumo_oficial) REFERENCES dbo.cat_insumos_recursos(id_insumo)
);
GO

PRINT 'Tablas map_clientes, map_productos y map_insumos creadas exitosamente con IDENTITY, UNIQUE y FK en consultora_pymes_core.';
GO
