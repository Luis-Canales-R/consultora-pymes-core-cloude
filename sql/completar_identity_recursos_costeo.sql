-- ============================================================================
-- Completa la corrección de corregir_identity_recursos_costeo.sql, que quedó
-- a medio camino (2026-11-23): ese script intentó recrear
-- cat_recursos_costeo_estandar y tbl_item_composicion_recursos con PK
-- IDENTITY, pero falló porque los nombres de restricciones
-- (df_recurso_origen, ck_recurso_origen, fk_comp_rec_item) seguían "vivos"
-- en las tablas ya renombradas a _old -- los nombres de restricciones son
-- únicos a nivel de base de datos en SQL Server, no por tabla, así que no
-- se podían reutilizar sin soltarlos primero.
--
-- Estado confirmado antes de este script (verificado con el usuario,
-- 2026-11-23): solo existen cat_recursos_costeo_estandar_old y
-- tbl_item_composicion_recursos_old (con los datos originales intactos);
-- las tablas nuevas (sin _old) no existen todavía.
--
-- Este script es idempotente: cada bloque solo actúa si la tabla nueva no
-- existe y la _old sí.
-- ============================================================================

USE consultora_pymes_core;
GO

-- 1. cat_recursos_costeo_estandar
IF OBJECT_ID('cat_recursos_costeo_estandar') IS NULL
   AND OBJECT_ID('cat_recursos_costeo_estandar_old') IS NOT NULL
BEGIN
    ALTER TABLE cat_recursos_costeo_estandar_old DROP CONSTRAINT ck_recurso_origen;
    ALTER TABLE cat_recursos_costeo_estandar_old DROP CONSTRAINT df_recurso_origen;
    ALTER TABLE cat_recursos_costeo_estandar_old DROP CONSTRAINT fk_recurso_unidad_medida;

    CREATE TABLE cat_recursos_costeo_estandar (
        id_recurso INT IDENTITY(1,1) PRIMARY KEY,
        codigo VARCHAR(30) UNIQUE NOT NULL,
        nombre VARCHAR(100) NOT NULL,
        id_unidad_medida INT NOT NULL,
        costo_unitario_referencia DECIMAL(18,2) NOT NULL,
        origen VARCHAR(20) NOT NULL
            CONSTRAINT df_recurso_origen DEFAULT ('INTERNO')
            CONSTRAINT ck_recurso_origen CHECK (origen IN ('INTERNO', 'SUBCONTRATADO')),
        CONSTRAINT fk_recurso_unidad_medida FOREIGN KEY (id_unidad_medida) REFERENCES cat_unidades_medida(id_unidad_medida)
    );

    SET IDENTITY_INSERT cat_recursos_costeo_estandar ON;
    INSERT INTO cat_recursos_costeo_estandar (id_recurso, codigo, nombre, id_unidad_medida, costo_unitario_referencia, origen)
    SELECT id_recurso, codigo, nombre, id_unidad_medida, costo_unitario_referencia, origen
    FROM cat_recursos_costeo_estandar_old;
    SET IDENTITY_INSERT cat_recursos_costeo_estandar OFF;

    DECLARE @max_id_recurso INT = (SELECT ISNULL(MAX(id_recurso), 0) FROM cat_recursos_costeo_estandar);
    DBCC CHECKIDENT ('cat_recursos_costeo_estandar', RESEED, @max_id_recurso);

    DROP TABLE cat_recursos_costeo_estandar_old;

    PRINT 'cat_recursos_costeo_estandar recreada con IDENTITY, datos preservados.';
END
ELSE
    PRINT 'cat_recursos_costeo_estandar: nada que hacer (ya existe o no hay _old que migrar).';
GO

-- 2. tbl_item_composicion_recursos
IF OBJECT_ID('tbl_item_composicion_recursos') IS NULL
   AND OBJECT_ID('tbl_item_composicion_recursos_old') IS NOT NULL
BEGIN
    ALTER TABLE tbl_item_composicion_recursos_old DROP CONSTRAINT fk_comp_rec_item;

    CREATE TABLE tbl_item_composicion_recursos (
        id_composicion_recurso INT IDENTITY(1,1) PRIMARY KEY,
        id_item INT NOT NULL,
        id_recurso INT NOT NULL,
        cantidad DECIMAL(18,2) NOT NULL,
        CONSTRAINT fk_comp_rec_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE,
        CONSTRAINT fk_comp_rec_recurso FOREIGN KEY (id_recurso) REFERENCES cat_recursos_costeo_estandar(id_recurso)
    );

    SET IDENTITY_INSERT tbl_item_composicion_recursos ON;
    INSERT INTO tbl_item_composicion_recursos (id_composicion_recurso, id_item, id_recurso, cantidad)
    SELECT id_composicion_recurso, id_item, id_recurso, cantidad
    FROM tbl_item_composicion_recursos_old;
    SET IDENTITY_INSERT tbl_item_composicion_recursos OFF;

    DECLARE @max_id_comp INT = (SELECT ISNULL(MAX(id_composicion_recurso), 0) FROM tbl_item_composicion_recursos);
    DBCC CHECKIDENT ('tbl_item_composicion_recursos', RESEED, @max_id_comp);

    DROP TABLE tbl_item_composicion_recursos_old;

    PRINT 'tbl_item_composicion_recursos recreada con IDENTITY, datos preservados.';
END
ELSE
    PRINT 'tbl_item_composicion_recursos: nada que hacer (ya existe o no hay _old que migrar).';
GO

-- 3. Verificación final
SELECT
    COLUMNPROPERTY(OBJECT_ID('cat_recursos_costeo_estandar'), 'id_recurso', 'IsIdentity') AS recurso_es_identity,
    COLUMNPROPERTY(OBJECT_ID('tbl_item_composicion_recursos'), 'id_composicion_recurso', 'IsIdentity') AS composicion_es_identity;

SELECT * FROM cat_recursos_costeo_estandar ORDER BY id_recurso;
SELECT * FROM tbl_item_composicion_recursos ORDER BY id_composicion_recurso;
GO
