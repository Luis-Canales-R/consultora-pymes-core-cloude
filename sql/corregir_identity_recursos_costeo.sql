-- ============================================================================
-- Corrección: agregar IDENTITY a las PK de cat_recursos_costeo_estandar y
-- tbl_item_composicion_recursos (Tarea #50).
--
-- Bug detectado 2026-11-23: generalizar_bom_recursos_costeo.sql creó ambas
-- tablas con su PK como INT normal (sin IDENTITY), a diferencia del resto de
-- los catálogos del proyecto. Esto obligaba a indicar manualmente el id al
-- insertar un recurso o una línea de BOM nueva -- detectado al intentar
-- insertar un recurso INTERNO de prueba ("Mens. 515 ... column does not
-- allow nulls").
--
-- Este script agrega IDENTITY(1,1) a ambas PK preservando los datos ya
-- migrados (incluyendo sus ids originales, para no romper las referencias
-- ya creadas en tbl_item_composicion_recursos). Es idempotente: si la PK ya
-- es IDENTITY, no hace nada.
--
-- No se modifica generalizar_bom_recursos_costeo.sql (ya fue ejecutado) --
-- por disciplina del proyecto, las correcciones posteriores a un script ya
-- corrido van en un script nuevo.
-- ============================================================================

USE consultora_pymes_core;
GO

-- 1. cat_recursos_costeo_estandar.id_recurso -> IDENTITY
IF COLUMNPROPERTY(OBJECT_ID('cat_recursos_costeo_estandar'), 'id_recurso', 'IsIdentity') = 0
   OR COLUMNPROPERTY(OBJECT_ID('cat_recursos_costeo_estandar'), 'id_recurso', 'IsIdentity') IS NULL
BEGIN
    -- Hay que soltar primero el FK de tbl_item_composicion_recursos hacia esta
    -- tabla, porque la vamos a renombrar/reemplazar.
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_comp_rec_recurso')
        ALTER TABLE tbl_item_composicion_recursos DROP CONSTRAINT fk_comp_rec_recurso;

    EXEC sp_rename 'cat_recursos_costeo_estandar', 'cat_recursos_costeo_estandar_old';

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

    PRINT 'cat_recursos_costeo_estandar: PK convertida a IDENTITY, datos preservados.';
END
ELSE
    PRINT 'cat_recursos_costeo_estandar.id_recurso ya es IDENTITY -- no se hizo nada.';
GO

-- 2. tbl_item_composicion_recursos.id_composicion_recurso -> IDENTITY
IF COLUMNPROPERTY(OBJECT_ID('tbl_item_composicion_recursos'), 'id_composicion_recurso', 'IsIdentity') = 0
   OR COLUMNPROPERTY(OBJECT_ID('tbl_item_composicion_recursos'), 'id_composicion_recurso', 'IsIdentity') IS NULL
BEGIN
    EXEC sp_rename 'tbl_item_composicion_recursos', 'tbl_item_composicion_recursos_old';

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

    PRINT 'tbl_item_composicion_recursos: PK convertida a IDENTITY, datos preservados.';
END
ELSE
    PRINT 'tbl_item_composicion_recursos.id_composicion_recurso ya es IDENTITY -- no se hizo nada.';
GO

-- 3. Verificación final: confirmar fila migrada y ambas IDENTITY activas.
SELECT
    COLUMNPROPERTY(OBJECT_ID('cat_recursos_costeo_estandar'), 'id_recurso', 'IsIdentity') AS recurso_es_identity,
    COLUMNPROPERTY(OBJECT_ID('tbl_item_composicion_recursos'), 'id_composicion_recurso', 'IsIdentity') AS composicion_es_identity;

SELECT * FROM cat_recursos_costeo_estandar ORDER BY id_recurso;
SELECT * FROM tbl_item_composicion_recursos ORDER BY id_composicion_recurso;
GO
