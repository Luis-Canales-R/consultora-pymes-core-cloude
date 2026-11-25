-- ============================================================================
-- Limpieza: elimina las tablas viejas de BOM de horas-hombre
-- (cat_perfiles_hh / tbl_item_composicion_hh), ya reemplazadas por el BOM
-- generalizado de la Tarea #50 (cat_recursos_costeo_estandar /
-- tbl_item_composicion_recursos).
--
-- generalizar_bom_recursos_costeo.sql dejó estas tablas intactas a propósito
-- (como respaldo/rollback hasta confirmar la migración). La Tarea #50 ya
-- quedó validada end-to-end contra SQL Server real (2026-11-23, ver
-- Hallazgo #25 del plan del proyecto): el BOM generalizado funciona, incluye
-- un caso de prueba de origen mixto, y ningún código vivo de la plataforma
-- lee ya las tablas viejas (confirmado por grep -- solo quedan menciones en
-- comentarios y en el propio script de migración, ambos históricos).
--
-- Idempotente: no falla si las tablas ya fueron eliminadas.
-- ============================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('tbl_item_composicion_hh') IS NOT NULL
BEGIN
    DROP TABLE tbl_item_composicion_hh;
    PRINT 'tbl_item_composicion_hh eliminada.';
END
ELSE
    PRINT 'tbl_item_composicion_hh ya no existía -- no se hizo nada.';
GO

IF OBJECT_ID('cat_perfiles_hh') IS NOT NULL
BEGIN
    DROP TABLE cat_perfiles_hh;
    PRINT 'cat_perfiles_hh eliminada.';
END
ELSE
    PRINT 'cat_perfiles_hh ya no existía -- no se hizo nada.';
GO
