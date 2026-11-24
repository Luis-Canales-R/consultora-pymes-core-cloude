-- ============================================================================
-- Migración: generaliza el BOM de horas-hombre a un catálogo de recursos
-- de costeo estándar con unidad de medida y origen (Tarea #50 del Backlog).
-- ============================================================================
-- CONTEXTO: cat_perfiles_hh / tbl_item_composicion_hh asumían que todo
-- componente de mano de obra se mide en horas, y sp_procesar_venta_externa
-- trataba el 100% del BOM de un ítem SERVICIO como subcontratado (créditaba
-- todo a la cuenta 2125), sin poder distinguir si parte del BOM correspondía
-- a personal interno. Ver Hallazgo #23 (limitación detectada) y la discusión
-- de Tarea #45/#50 en el documento del proyecto para el detalle completo.
--
-- DISEÑO (confirmado con el usuario 2026-11-23, siguiendo el patrón estándar
-- de los ERP líderes -- SAP/Oracle/Dynamics -- de generalizar el BOM a un
-- "Bill of Resources" con unidad de medida y origen por recurso):
--   - cat_recursos_costeo_estandar reemplaza a cat_perfiles_hh: agrega
--     id_unidad_medida (reutiliza cat_unidades_medida, ya existente para
--     Productos) y origen ('INTERNO' / 'SUBCONTRATADO').
--   - tbl_item_composicion_recursos reemplaza a tbl_item_composicion_hh:
--     cada línea del BOM referencia un recurso + cantidad en su unidad.
--   - Se usa para AMBOS modos que hoy usan horas-hombre: FABRICADO (MOD) y
--     SERVICIO (Honorarios), unificando el mecanismo. Esto deja disponible
--     a futuro el mismo patrón para operaciones de fabricación
--     subcontratadas (outsourcing de un paso productivo).
--
-- Las tablas viejas (cat_perfiles_hh, tbl_item_composicion_hh) NO se
-- eliminan en este script -- se migran los datos a las nuevas y se dejan
-- las viejas intactas para revisión y como respaldo, hasta confirmar que
-- todo quedó correcto. Un script de limpieza aparte las eliminará después.
-- ============================================================================

USE consultora_pymes_core;
GO

-- 1. Catálogo generalizado de recursos de costeo estándar
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'cat_recursos_costeo_estandar')
BEGIN
    CREATE TABLE cat_recursos_costeo_estandar (
        id_recurso INT PRIMARY KEY,
        codigo VARCHAR(30) UNIQUE NOT NULL,
        nombre VARCHAR(100) NOT NULL,
        id_unidad_medida INT NOT NULL,
        costo_unitario_referencia DECIMAL(18,2) NOT NULL,
        origen VARCHAR(20) NOT NULL
            CONSTRAINT df_recurso_origen DEFAULT ('INTERNO')
            CONSTRAINT ck_recurso_origen CHECK (origen IN ('INTERNO', 'SUBCONTRATADO')),
        CONSTRAINT fk_recurso_unidad_medida FOREIGN KEY (id_unidad_medida) REFERENCES cat_unidades_medida(id_unidad_medida)
    );
    PRINT 'Tabla cat_recursos_costeo_estandar creada.';
END
ELSE
    PRINT 'cat_recursos_costeo_estandar ya existía -- no se hizo nada (migración idempotente).';
GO

-- 2. BOM generalizado (reemplaza tbl_item_composicion_hh)
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'tbl_item_composicion_recursos')
BEGIN
    CREATE TABLE tbl_item_composicion_recursos (
        id_composicion_recurso INT PRIMARY KEY,
        id_item INT NOT NULL,
        id_recurso INT NOT NULL,
        cantidad DECIMAL(18,2) NOT NULL,
        CONSTRAINT fk_comp_rec_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE,
        CONSTRAINT fk_comp_rec_recurso FOREIGN KEY (id_recurso) REFERENCES cat_recursos_costeo_estandar(id_recurso)
    );
    PRINT 'Tabla tbl_item_composicion_recursos creada.';
END
ELSE
    PRINT 'tbl_item_composicion_recursos ya existía -- no se hizo nada (migración idempotente).';
GO

-- 3. Migración de datos: cat_perfiles_hh -> cat_recursos_costeo_estandar
--    Unidad de medida: se usa 'HORA' (debe existir en cat_unidades_medida;
--    si tu catálogo usa otro código para horas, ajusta el WHERE de abajo
--    antes de ejecutar).
--
--    Origen: por defecto 'SUBCONTRATADO' si el perfil se usa en AL MENOS UN
--    ítem con id_cuenta_clearing_compra = 2125 (checkbox "Subcontrato"
--    marcado); 'INTERNO' en caso contrario. IMPORTANTE: si un mismo perfil
--    se usa tanto en ítems marcados como Subcontrato como en ítems sin
--    marcar, este script no puede decidir por ti -- revisa manualmente esos
--    casos después de correr la consulta de verificación al final.
IF EXISTS (SELECT 1 FROM sys.tables WHERE name = 'cat_perfiles_hh')
   AND NOT EXISTS (SELECT 1 FROM cat_recursos_costeo_estandar)
BEGIN
    DECLARE @id_unidad_hora INT = (SELECT TOP 1 id_unidad_medida FROM cat_unidades_medida WHERE codigo = 'HORA' OR nombre LIKE 'Hora%');

    IF @id_unidad_hora IS NULL
    BEGIN
        PRINT 'ADVERTENCIA: no se encontró una unidad de medida de horas en cat_unidades_medida. Agrega una (ej. codigo ''HORA'') antes de continuar, y vuelve a correr este bloque a mano.';
    END
    ELSE
    BEGIN
        INSERT INTO cat_recursos_costeo_estandar (id_recurso, codigo, nombre, id_unidad_medida, costo_unitario_referencia, origen)
        SELECT
            pf.id_perfil_hh,
            pf.codigo,
            pf.nombre,
            @id_unidad_hora,
            pf.costo_hora_referencia,
            CASE WHEN EXISTS (
                SELECT 1
                FROM tbl_item_composicion_hh hh2
                INNER JOIN tbl_productos_servicios p2 ON p2.id_item = hh2.id_item
                WHERE hh2.id_perfil_hh = pf.id_perfil_hh
                  AND p2.id_cuenta_clearing_compra = 2125
            ) THEN 'SUBCONTRATADO' ELSE 'INTERNO' END
        FROM cat_perfiles_hh pf;

        PRINT 'Datos migrados de cat_perfiles_hh a cat_recursos_costeo_estandar.';

        INSERT INTO tbl_item_composicion_recursos (id_composicion_recurso, id_item, id_recurso, cantidad)
        SELECT id_composicion_hh, id_item, id_perfil_hh, cantidad_horas
        FROM tbl_item_composicion_hh;

        PRINT 'Datos migrados de tbl_item_composicion_hh a tbl_item_composicion_recursos.';
    END
END
ELSE
    PRINT 'Migración de datos omitida (cat_perfiles_hh no existe, o cat_recursos_costeo_estandar ya tenía datos).';
GO

-- 4. Consulta de verificación -- revisa esto ANTES de dar por buena la
--    migración. Busca perfiles usados en items mixtos (algunos con
--    Subcontrato marcado, otros no) para los que el origen asignado
--    automáticamente puede no ser el correcto para todos los casos.
SELECT
    rc.id_recurso,
    rc.codigo,
    rc.nombre,
    rc.origen AS origen_asignado,
    COUNT(DISTINCT p.id_item) AS items_que_lo_usan,
    SUM(CASE WHEN p.id_cuenta_clearing_compra = 2125 THEN 1 ELSE 0 END) AS items_subcontrato_marcado,
    SUM(CASE WHEN p.id_cuenta_clearing_compra IS NULL OR p.id_cuenta_clearing_compra <> 2125 THEN 1 ELSE 0 END) AS items_subcontrato_no_marcado
FROM cat_recursos_costeo_estandar rc
INNER JOIN tbl_item_composicion_recursos cr ON cr.id_recurso = rc.id_recurso
INNER JOIN tbl_productos_servicios p ON p.id_item = cr.id_item
GROUP BY rc.id_recurso, rc.codigo, rc.nombre, rc.origen
HAVING SUM(CASE WHEN p.id_cuenta_clearing_compra = 2125 THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN p.id_cuenta_clearing_compra IS NULL OR p.id_cuenta_clearing_compra <> 2125 THEN 1 ELSE 0 END) > 0;
-- Si esta consulta devuelve filas, significa que ese recurso se usa en
-- items con distinto estado de Subcontrato -- revisa caso por caso si el
-- origen asignado (columna origen_asignado) es el correcto, o si conviene
-- separar ese recurso en dos (ej. "Pintor Interno" / "Pintor Subcontratado")
-- con costos de referencia distintos, que es además la práctica más
-- correcta a futuro.
GO

-- 5. vw_productos_servicios_costeo: se actualiza para leer de la tabla
--    generalizada (antes leía de cat_perfiles_hh/tbl_item_composicion_hh).
--    Los nombres de columna (costo_total_hh) se mantienen para no romper
--    nada que ya consuma esta vista -- el contenido ahora incluye
--    cualquier recurso (horas u otra unidad), no solo horas-hombre.
CREATE OR ALTER VIEW vw_productos_servicios_costeo AS
WITH costo_hh AS (
    SELECT cr.id_item, SUM(cr.cantidad * rc.costo_unitario_referencia) AS costo_total_hh
    FROM tbl_item_composicion_recursos cr
    INNER JOIN cat_recursos_costeo_estandar rc ON cr.id_recurso = rc.id_recurso
    GROUP BY cr.id_item
),
costo_insumos AS (
    SELECT ci.id_item, SUM(ci.cantidad * ir.costo_unitario_referencia) AS costo_total_insumos
    FROM tbl_item_composicion_insumos ci
    INNER JOIN cat_insumos_recursos ir ON ci.id_insumo = ir.id_insumo
    GROUP BY ci.id_item
)
SELECT
    p.id_item,
    p.sku_codigo,
    p.nombre AS item_nombre,
    t.nombre AS tipo_item,
    p.precio_venta_base,
    ISNULL(hh.costo_total_hh, 0) AS costo_total_hh,
    ISNULL(ins.costo_total_insumos, 0) AS costo_total_insumos,
    ISNULL(hh.costo_total_hh, 0) + ISNULL(ins.costo_total_insumos, 0) AS costo_total_base,
    p.precio_venta_base - (ISNULL(hh.costo_total_hh, 0) + ISNULL(ins.costo_total_insumos, 0)) AS margen_contribucion_base
FROM tbl_productos_servicios p
INNER JOIN cat_tipos_item t ON p.id_tipo_item = t.id_tipo_item
LEFT JOIN costo_hh hh ON p.id_item = hh.id_item
LEFT JOIN costo_insumos ins ON p.id_item = ins.id_item;
GO
