-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Carga del Data Warehouse en estrella (esquema dw) -- Fase B
-- ====================================================================
-- PRERREQUISITO: sql/crear_esquema_dw.sql debe estar ejecutado.
--
-- ESTRATEGIA DE CARGA: los HECHOS son FULL REFRESH -- cada ejecución de
-- dw.sp_cargar_dw_completo los vacía y los reconstruye desde cero a
-- partir del esquema transaccional (dbo). Es la estrategia más simple y
-- confiable para el volumen esperado de una PyME. Una carga incremental
-- de los hechos (solo deltas desde la última corrida, vía un control de
-- "alta marca" por id o fecha) queda documentada como mejora futura si el
-- volumen de datos llega a requerirla.
--
-- Las DIMENSIONES, desde v8, son SCD Tipo 2 (historizadas): ya NO se
-- vacían -- se versionan (ver dw.sp_cargar_dw_dimensiones). Esto permite
-- que la reconstrucción full-refresh de los hechos siga siendo point-in-
-- time correcta: cada hecho resuelve la versión de la dimensión que
-- estaba vigente en su fecha, no la vigente hoy.
--
-- ORDEN DE EJECUCIÓN DENTRO DE sp_cargar_dw_completo (importa por las FK
-- entre hechos y dimensiones):
--   1. Vaciar los HECHOS primero (referencian a las dimensiones).
--   2. Versionar las DIMENSIONES (Tipo 2 -- nunca se vacían).
--   3. Recargar dim_tiempo cubriendo el rango de fechas presente en el OLTP.
--   4. Reconstruir los HECHOS, resolviendo sk_* por fecha (point-in-time).
-- ====================================================================

USE consultora_pymes_core;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_dim_tiempo: genera el calendario día a día en el rango
-- [@fecha_desde, @fecha_hasta]. Es aditiva (no borra fechas existentes),
-- así que es segura de ejecutar repetidamente con rangos superpuestos.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_dim_tiempo', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_dim_tiempo;
GO

CREATE PROCEDURE dw.sp_cargar_dw_dim_tiempo
    @fecha_desde DATE,
    @fecha_hasta DATE
AS
BEGIN
    SET NOCOUNT ON;

    IF @fecha_desde IS NULL OR @fecha_hasta IS NULL OR @fecha_desde > @fecha_hasta
        RETURN;

    DECLARE @f DATE = @fecha_desde;
    WHILE @f <= @fecha_hasta
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dw.dim_tiempo WHERE fecha = @f)
            INSERT INTO dw.dim_tiempo
                (id_fecha, fecha, anio, mes, nombre_mes, dia, nombre_dia, trimestre, periodo_contable, es_fin_de_semana)
            VALUES (
                YEAR(@f) * 10000 + MONTH(@f) * 100 + DAY(@f),
                @f, YEAR(@f), MONTH(@f), DATENAME(MONTH, @f), DAY(@f), DATENAME(WEEKDAY, @f),
                DATEPART(QUARTER, @f), CONVERT(VARCHAR(7), @f, 23),
                -- Truco independiente de idioma/@@DATEFIRST: 1900-01-01 (día 0) fue lunes,
                -- por lo que DATEDIFF(DAY, 0, fecha) % 7 da 0=lunes .. 5=sábado, 6=domingo.
                CASE WHEN DATEDIFF(DAY, 0, @f) % 7 IN (5, 6) THEN 1 ELSE 0 END
            );

        SET @f = DATEADD(DAY, 1, @f);
    END
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_dimensiones (v8 -- SCD Tipo 2): versiona cada dimensión
-- (excepto dim_tiempo, que es aditiva y se recarga aparte) en vez de
-- sobrescribirla. Patrón aplicado igual a las 5 dimensiones:
--   1) Cerrar (fecha_fin_vigencia = @hoy, es_vigente = 0) la versión
--      vigente de toda fila cuya clave natural sigue existiendo en el
--      origen (dbo) pero cuyos atributos rastreados ya no coinciden
--      (comparación NULL-safe vía EXCEPT).
--   2) Insertar una versión nueva (es_vigente = 1, fecha_fin_vigencia =
--      NULL) para: (a) toda clave natural nueva en el origen que nunca
--      tuvo fila en el DW -- su fecha_inicio_vigencia se fija en una
--      fecha "época" (@epoca) muy anterior, NO en @hoy, para que los
--      hechos históricos que la referencian (ya cargados con fechas
--      pasadas) puedan resolverla en la búsqueda point-in-time; y (b)
--      toda clave natural cuya versión vigente se cerró en el paso 1 --
--      esta sí nace con fecha_inicio_vigencia = @hoy, porque es la
--      primera vez que detectamos el cambio (no hay CDC en este esquema,
--      solo comparación por lote en cada carga).
-- No se borra ninguna fila histórica: por eso esta dimensión YA NO se
-- puede "recargar desde cero" sin perder historial -- a diferencia de
-- los HECHOS, que sí son full refresh.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_dimensiones', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_dimensiones;
GO

CREATE PROCEDURE dw.sp_cargar_dw_dimensiones
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @hoy DATE = CAST(GETDATE() AS DATE);
    DECLARE @epoca DATE = '1900-01-01'; -- v8: fecha de inicio para la PRIMERA versión de cada clave natural

    ------------------------------------------------------------------
    -- dim_cuenta_contable
    ------------------------------------------------------------------
    UPDATE d
    SET d.fecha_fin_vigencia = @hoy, d.es_vigente = 0
    FROM dw.dim_cuenta_contable d
    INNER JOIN dbo.cat_plan_cuentas src ON src.id_cuenta = d.id_cuenta
    WHERE d.es_vigente = 1
      AND EXISTS (
            SELECT src.codigo_cuenta, src.nombre_cuenta, src.nivel, src.id_cuenta_padre, src.naturaleza, src.tipo_cuenta, src.es_imputable, src.estado_activo
            EXCEPT
            SELECT d.codigo_cuenta, d.nombre_cuenta, d.nivel, d.id_cuenta_padre, d.naturaleza, d.tipo_cuenta, d.es_imputable, d.estado_activo
          );

    INSERT INTO dw.dim_cuenta_contable
        (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, tipo_cuenta, es_imputable, estado_activo,
         fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente)
    SELECT
        src.id_cuenta, src.codigo_cuenta, src.nombre_cuenta, src.nivel, src.id_cuenta_padre, src.naturaleza, src.tipo_cuenta, src.es_imputable, src.estado_activo,
        CASE WHEN EXISTS (SELECT 1 FROM dw.dim_cuenta_contable d2 WHERE d2.id_cuenta = src.id_cuenta) THEN @hoy ELSE @epoca END,
        NULL, 1
    FROM dbo.cat_plan_cuentas src
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_cuenta_contable d WHERE d.id_cuenta = src.id_cuenta AND d.es_vigente = 1);

    ------------------------------------------------------------------
    -- dim_centro_costo
    ------------------------------------------------------------------
    UPDATE d
    SET d.fecha_fin_vigencia = @hoy, d.es_vigente = 0
    FROM dw.dim_centro_costo d
    INNER JOIN dbo.tbl_centros_costo src ON src.id_centro_costo = d.id_centro_costo
    WHERE d.es_vigente = 1
      AND EXISTS (
            SELECT src.codigo_cc, src.nombre_cc, src.nivel, src.id_centro_padre, src.es_activo
            EXCEPT
            SELECT d.codigo_cc, d.nombre_cc, d.nivel, d.id_centro_padre, d.es_activo
          );

    INSERT INTO dw.dim_centro_costo
        (id_centro_costo, codigo_cc, nombre_cc, nivel, id_centro_padre, es_activo,
         fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente)
    SELECT
        src.id_centro_costo, src.codigo_cc, src.nombre_cc, src.nivel, src.id_centro_padre, src.es_activo,
        CASE WHEN EXISTS (SELECT 1 FROM dw.dim_centro_costo d2 WHERE d2.id_centro_costo = src.id_centro_costo) THEN @hoy ELSE @epoca END,
        NULL, 1
    FROM dbo.tbl_centros_costo src
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_centro_costo d WHERE d.id_centro_costo = src.id_centro_costo AND d.es_vigente = 1);

    ------------------------------------------------------------------
    -- dim_tercero (es_cliente/es_proveedor son derivados, se resuelven
    -- en una CTE para poder compararlos y re-insertarlos igual que un
    -- atributo normal)
    ------------------------------------------------------------------
    ;WITH src_tercero AS (
        SELECT
            t.id_tercero, t.codigo_tercero, t.razon_social, t.nombre_fantasia, t.rut_dni, t.comuna_ciudad,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.tbl_terceros_extension_cliente c WHERE c.id_tercero = t.id_tercero) THEN 1 ELSE 0 END AS BIT) AS es_cliente,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.tbl_terceros_extension_proveedor p WHERE p.id_tercero = t.id_tercero) THEN 1 ELSE 0 END AS BIT) AS es_proveedor,
            t.estado_activo
        FROM dbo.tbl_terceros t
    )
    UPDATE d
    SET d.fecha_fin_vigencia = @hoy, d.es_vigente = 0
    FROM dw.dim_tercero d
    INNER JOIN src_tercero src ON src.id_tercero = d.id_tercero
    WHERE d.es_vigente = 1
      AND EXISTS (
            SELECT src.codigo_tercero, src.razon_social, src.nombre_fantasia, src.rut_dni, src.comuna_ciudad, src.es_cliente, src.es_proveedor, src.estado_activo
            EXCEPT
            SELECT d.codigo_tercero, d.razon_social, d.nombre_fantasia, d.rut_dni, d.comuna_ciudad, d.es_cliente, d.es_proveedor, d.estado_activo
          );

    ;WITH src_tercero AS (
        SELECT
            t.id_tercero, t.codigo_tercero, t.razon_social, t.nombre_fantasia, t.rut_dni, t.comuna_ciudad,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.tbl_terceros_extension_cliente c WHERE c.id_tercero = t.id_tercero) THEN 1 ELSE 0 END AS BIT) AS es_cliente,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.tbl_terceros_extension_proveedor p WHERE p.id_tercero = t.id_tercero) THEN 1 ELSE 0 END AS BIT) AS es_proveedor,
            t.estado_activo
        FROM dbo.tbl_terceros t
    )
    INSERT INTO dw.dim_tercero
        (id_tercero, codigo_tercero, razon_social, nombre_fantasia, rut_dni, comuna_ciudad, es_cliente, es_proveedor, estado_activo,
         fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente)
    SELECT
        src.id_tercero, src.codigo_tercero, src.razon_social, src.nombre_fantasia, src.rut_dni, src.comuna_ciudad, src.es_cliente, src.es_proveedor, src.estado_activo,
        CASE WHEN EXISTS (SELECT 1 FROM dw.dim_tercero d2 WHERE d2.id_tercero = src.id_tercero) THEN @hoy ELSE @epoca END,
        NULL, 1
    FROM src_tercero src
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_tercero d WHERE d.id_tercero = src.id_tercero AND d.es_vigente = 1);

    ------------------------------------------------------------------
    -- dim_empleado
    ------------------------------------------------------------------
    UPDATE d
    SET d.fecha_fin_vigencia = @hoy, d.es_vigente = 0
    FROM dw.dim_empleado d
    INNER JOIN dbo.tbl_empleados_usuarios src ON src.id_empleado = d.id_empleado
    WHERE d.es_vigente = 1
      AND EXISTS (
            SELECT src.rut_dni, src.nombre_completo, src.cargo, src.id_centro_costo, src.es_activo
            EXCEPT
            SELECT d.rut_dni, d.nombre_completo, d.cargo, d.id_centro_costo, d.es_activo
          );

    INSERT INTO dw.dim_empleado
        (id_empleado, rut_dni, nombre_completo, cargo, id_centro_costo, es_activo,
         fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente)
    SELECT
        src.id_empleado, src.rut_dni, src.nombre_completo, src.cargo, src.id_centro_costo, src.es_activo,
        CASE WHEN EXISTS (SELECT 1 FROM dw.dim_empleado d2 WHERE d2.id_empleado = src.id_empleado) THEN @hoy ELSE @epoca END,
        NULL, 1
    FROM dbo.tbl_empleados_usuarios src
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_empleado d WHERE d.id_empleado = src.id_empleado AND d.es_vigente = 1);

    ------------------------------------------------------------------
    -- dim_item (caso motivador de v8: modo_obtencion puede cambiar)
    ------------------------------------------------------------------
    ;WITH src_item AS (
        SELECT p.id_item, p.sku_codigo, p.nombre, ti.codigo AS tipo_item, ci.nombre AS categoria_item,
               p.modo_obtencion, p.precio_venta_base, p.estado_activo
        FROM dbo.tbl_productos_servicios p
        INNER JOIN dbo.cat_tipos_item ti ON ti.id_tipo_item = p.id_tipo_item
        LEFT JOIN dbo.cat_categorias_item ci ON ci.id_categoria_item = p.id_categoria_item
    )
    UPDATE d
    SET d.fecha_fin_vigencia = @hoy, d.es_vigente = 0
    FROM dw.dim_item d
    INNER JOIN src_item src ON src.id_item = d.id_item
    WHERE d.es_vigente = 1
      AND EXISTS (
            SELECT src.sku_codigo, src.nombre, src.tipo_item, src.categoria_item, src.modo_obtencion, src.precio_venta_base, src.estado_activo
            EXCEPT
            SELECT d.sku_codigo, d.nombre, d.tipo_item, d.categoria_item, d.modo_obtencion, d.precio_venta_base, d.estado_activo
          );

    ;WITH src_item AS (
        SELECT p.id_item, p.sku_codigo, p.nombre, ti.codigo AS tipo_item, ci.nombre AS categoria_item,
               p.modo_obtencion, p.precio_venta_base, p.estado_activo
        FROM dbo.tbl_productos_servicios p
        INNER JOIN dbo.cat_tipos_item ti ON ti.id_tipo_item = p.id_tipo_item
        LEFT JOIN dbo.cat_categorias_item ci ON ci.id_categoria_item = p.id_categoria_item
    )
    INSERT INTO dw.dim_item
        (id_item, sku_codigo, nombre, tipo_item, categoria_item, modo_obtencion, precio_venta_base, estado_activo,
         fecha_inicio_vigencia, fecha_fin_vigencia, es_vigente)
    SELECT
        src.id_item, src.sku_codigo, src.nombre, src.tipo_item, src.categoria_item, src.modo_obtencion, src.precio_venta_base, src.estado_activo,
        CASE WHEN EXISTS (SELECT 1 FROM dw.dim_item d2 WHERE d2.id_item = src.id_item) THEN @hoy ELSE @epoca END,
        NULL, 1
    FROM src_item src
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_item d WHERE d.id_item = src.id_item AND d.es_vigente = 1);
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_fact_asientos_contables: tabla de hechos CENTRAL.
-- Grano = 1 fila por línea de dbo.tbl_asientos_detalle. v8 (SCD Tipo 2):
-- resuelve sk_cuenta_contable / sk_centro_costo por FECHA -- la versión
-- de la dimensión cuya vigencia ([fecha_inicio_vigencia, fecha_fin_
-- vigencia)) cubre la fecha del asiento, NO necesariamente la versión
-- vigente hoy. Esto es lo que hace point-in-time correcto el reporte:
-- si una cuenta cambió de tipo_cuenta después de este asiento, el
-- asiento sigue resolviendo a la versión que estaba vigente cuando se
-- contabilizó.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_fact_asientos_contables', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_fact_asientos_contables;
GO

CREATE PROCEDURE dw.sp_cargar_dw_fact_asientos_contables
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dw.fact_asientos_contables;

    INSERT INTO dw.fact_asientos_contables
        (id_asiento_detalle, id_asiento, numero_asiento, id_transaccion, id_fecha,
         id_cuenta, sk_cuenta_contable, id_centro_costo, sk_centro_costo,
         periodo_contable, glosa_general, glosa_detalle, debe, haber, monto_neto)
    SELECT
        d.id_asiento_detalle,
        c.id_asiento,
        c.numero_asiento,
        c.id_transaccion,
        YEAR(c.fecha_asiento) * 10000 + MONTH(c.fecha_asiento) * 100 + DAY(c.fecha_asiento),
        d.id_cuenta,
        dc.sk_cuenta_contable,
        d.id_centro_costo,
        cc.sk_centro_costo,
        c.periodo_contable,
        c.glosa_general,
        d.glosa_detalle,
        d.debe,
        d.haber,
        d.debe - d.haber
    FROM dbo.tbl_asientos_detalle d
    INNER JOIN dbo.tbl_asientos_cabecera c ON c.id_asiento = d.id_asiento
    INNER JOIN dw.dim_cuenta_contable dc
        ON dc.id_cuenta = d.id_cuenta
       AND dc.fecha_inicio_vigencia <= c.fecha_asiento
       AND (dc.fecha_fin_vigencia IS NULL OR c.fecha_asiento < dc.fecha_fin_vigencia)
    LEFT JOIN dw.dim_centro_costo cc
        ON cc.id_centro_costo = d.id_centro_costo
       AND cc.fecha_inicio_vigencia <= c.fecha_asiento
       AND (cc.fecha_fin_vigencia IS NULL OR c.fecha_asiento < cc.fecha_fin_vigencia);

    -- v9: sincroniza la marca de control para que, si luego se cambia a
    -- carga incremental (dw.sp_cargar_dw_incremental), arranque justo
    -- después de lo que esta carga completa ya dejó en el DW.
    DECLARE @ultima_clave_asientos INT = ISNULL((SELECT MAX(id_asiento_detalle) FROM dbo.tbl_asientos_detalle), 0);

    IF EXISTS (SELECT 1 FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_asientos_contables')
        UPDATE dw.tbl_control_carga_incremental
        SET ultima_clave_cargada = @ultima_clave_asientos, fecha_ultima_carga = GETDATE()
        WHERE nombre_hecho = 'fact_asientos_contables';
    ELSE
        INSERT INTO dw.tbl_control_carga_incremental (nombre_hecho, ultima_clave_cargada)
        VALUES ('fact_asientos_contables', @ultima_clave_asientos);
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_fact_margen_venta: hechos secundarios de margen.
-- Grano = 1 fila por línea de dbo.tbl_ventas_detalle. El costo_directo
-- se resuelve con la MISMA lógica de Costeo Directo por Flujo de Venta
-- (v4/v6/v7) usada en sp_procesar_etl_fase3 / sp_procesar_venta_externa:
--   COMPRADO_REVENTA -> se LEE el costo real ya registrado en el kardex
--     (dbo.tbl_movimientos_inventario, salida por esa venta), en vez de
--     recalcularlo -- es la fuente de verdad más precisa disponible.
--   FABRICADO / SERVICIO -> MOD/Honorarios se recalcula a costo estándar
--     (BOM, igual que en el asiento automático de la venta); MPD/Insumos
--     (v7) se LEE el costo REAL ya registrado en el kardex de insumos
--     (salidas de dbo.tbl_movimientos_inventario con id_referencia = la
--     venta y id_insumo entre los componentes del BOM del ítem), en vez
--     de recalcularlo a costo estándar -- misma filosofía que
--     COMPRADO_REVENTA.
--   NULL (ítem sin clasificar) -> costo_directo = 0.
--
-- LIMITACIÓN CONOCIDA (v7): el kardex solo referencia id_venta_devengada
-- (no id_venta_detalle); si una misma venta tiene 2+ líneas FABRICADO/
-- SERVICIO que comparten un mismo insumo en su BOM, el costo real de ese
-- insumo se atribuye a ambas líneas sin poder discriminar cuál consumió
-- cuánto -- caso de borde poco frecuente, documentado en el CHANGELOG.
--
-- v8 (SCD Tipo 2): resuelve sk_item / sk_tercero / sk_centro_costo /
-- sk_empleado por FECHA (la versión vigente de cada dimensión AL MOMENTO
-- de la venta, no la vigente hoy) -- igual filosofía que fact_asientos_
-- contables.
--
-- v12 (Costeo de Margen Point-in-Time): tanto la columna modo_obtencion
-- almacenada en el hecho como la fórmula de costo_directo ahora usan
-- di.modo_obtencion -- el valor de la dimensión YA resuelto point-in-time
-- vía el join de sk_item (arriba) -- en vez de ps.modo_obtencion (el
-- valor ACTUAL en dbo, usado hasta v11). Esto cierra la limitación
-- documentada desde v8: si un ítem cambia de modo_obtencion después de
-- ventas ya costeadas, un refresh del DW ya NO recostea esas ventas
-- antiguas con la fórmula del modo actual -- sigue usando la fórmula del
-- modo que estaba vigente al momento de cada venta. ps (dbo.tbl_
-- productos_servicios) se mantiene en el JOIN solo como verificación de
-- existencia del ítem en el OLTP; ya no se lee su modo_obtencion.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_fact_margen_venta', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_fact_margen_venta;
GO

CREATE PROCEDURE dw.sp_cargar_dw_fact_margen_venta
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dw.fact_margen_venta;

    INSERT INTO dw.fact_margen_venta
        (id_venta_detalle, id_venta_devengada, folio_factura, id_fecha,
         id_item, sk_item, id_tercero, sk_tercero, id_centro_costo, sk_centro_costo,
         id_empleado, sk_empleado, modo_obtencion, cantidad, precio_unitario, ingreso_neto, costo_directo, margen_contribucion)
    SELECT
        vd.id_venta_detalle,
        vv.id_venta_devengada,
        vv.folio_factura,
        YEAR(vv.fecha_emision) * 10000 + MONTH(vv.fecha_emision) * 100 + DAY(vv.fecha_emision),
        vd.id_item,
        di.sk_item,
        vv.id_tercero,
        dt.sk_tercero,
        vv.id_centro_costo,
        dc.sk_centro_costo,
        vv.id_empleado,
        de.sk_empleado,
        di.modo_obtencion,
        vd.cantidad,
        vd.precio_unitario,
        vd.subtotal_neto,
        costo.costo_directo,
        vd.subtotal_neto - costo.costo_directo
    FROM dbo.tbl_ventas_detalle vd
    INNER JOIN dbo.tbl_ventas_devengadas vv ON vv.id_venta_devengada = vd.id_venta_devengada
    INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
    INNER JOIN dw.dim_item di
        ON di.id_item = vd.id_item
       AND di.fecha_inicio_vigencia <= vv.fecha_emision
       AND (di.fecha_fin_vigencia IS NULL OR vv.fecha_emision < di.fecha_fin_vigencia)
    INNER JOIN dw.dim_tercero dt
        ON dt.id_tercero = vv.id_tercero
       AND dt.fecha_inicio_vigencia <= vv.fecha_emision
       AND (dt.fecha_fin_vigencia IS NULL OR vv.fecha_emision < dt.fecha_fin_vigencia)
    LEFT JOIN dw.dim_centro_costo dc
        ON dc.id_centro_costo = vv.id_centro_costo
       AND dc.fecha_inicio_vigencia <= vv.fecha_emision
       AND (dc.fecha_fin_vigencia IS NULL OR vv.fecha_emision < dc.fecha_fin_vigencia)
    LEFT JOIN dw.dim_empleado de
        ON de.id_empleado = vv.id_empleado
       AND de.fecha_inicio_vigencia <= vv.fecha_emision
       AND (de.fecha_fin_vigencia IS NULL OR vv.fecha_emision < de.fecha_fin_vigencia)
    CROSS APPLY (
        SELECT
            CASE
                WHEN di.modo_obtencion = 'COMPRADO_REVENTA' THEN
                    ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad)
                            FROM dbo.tbl_movimientos_inventario mi
                            WHERE mi.origen_documento = 'VENTA'
                              AND mi.tipo_movimiento = 'SALIDA'
                              AND mi.id_referencia = vv.id_venta_devengada
                              AND mi.id_item = vd.id_item), 0)
                WHEN di.modo_obtencion IN ('FABRICADO', 'SERVICIO') THEN
                    -- MOD/Honorarios: costo estándar (BOM)
                    vd.cantidad * ISNULL((SELECT SUM(hh.cantidad_horas * ph.costo_hora_referencia)
                                           FROM dbo.tbl_item_composicion_hh hh
                                           INNER JOIN dbo.cat_perfiles_hh ph ON ph.id_perfil_hh = hh.id_perfil_hh
                                           WHERE hh.id_item = vd.id_item), 0)
                    -- MPD/Insumos (v7): costo REAL ya consumido del kardex
                    + ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad)
                              FROM dbo.tbl_movimientos_inventario mi
                              WHERE mi.origen_documento = 'VENTA'
                                AND mi.tipo_movimiento = 'SALIDA'
                                AND mi.id_referencia = vv.id_venta_devengada
                                AND mi.id_insumo IN (
                                    SELECT ci.id_insumo FROM dbo.tbl_item_composicion_insumos ci WHERE ci.id_item = vd.id_item
                                )), 0)
                ELSE 0
            END AS costo_directo
    ) costo;

    -- v9: sincroniza la marca de control (ver nota en sp_cargar_dw_fact_asientos_contables)
    DECLARE @ultima_clave_margen INT = ISNULL((SELECT MAX(id_venta_detalle) FROM dbo.tbl_ventas_detalle), 0);

    IF EXISTS (SELECT 1 FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_margen_venta')
        UPDATE dw.tbl_control_carga_incremental
        SET ultima_clave_cargada = @ultima_clave_margen, fecha_ultima_carga = GETDATE()
        WHERE nombre_hecho = 'fact_margen_venta';
    ELSE
        INSERT INTO dw.tbl_control_carga_incremental (nombre_hecho, ultima_clave_cargada)
        VALUES ('fact_margen_venta', @ultima_clave_margen);
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_fact_asientos_contables_incremental (v9): versión
-- incremental de dw.sp_cargar_dw_fact_asientos_contables. En vez de
-- vaciar y reconstruir todo dw.fact_asientos_contables, INSERTA solo las
-- filas de dbo.tbl_asientos_detalle cuya clave natural (id_asiento_
-- detalle) es MAYOR a la última ya cargada (alta marca / high-water
-- mark en dw.tbl_control_carga_incremental). Válido porque
-- tbl_asientos_detalle es de solo-inserción (nunca se le hace UPDATE ni
-- DELETE en todo este esquema) -- ver limitación en CHANGELOG.md (v9).
-- La resolución point-in-time de sk_cuenta_contable / sk_centro_costo es
-- idéntica a la versión completa (v8).
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_fact_asientos_contables_incremental', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_fact_asientos_contables_incremental;
GO

CREATE PROCEDURE dw.sp_cargar_dw_fact_asientos_contables_incremental
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ultima_clave INT = ISNULL(
        (SELECT ultima_clave_cargada FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_asientos_contables'),
        0); -- sin fila de control todavía -> arranca desde cero (equivale a la carga completa)

    INSERT INTO dw.fact_asientos_contables
        (id_asiento_detalle, id_asiento, numero_asiento, id_transaccion, id_fecha,
         id_cuenta, sk_cuenta_contable, id_centro_costo, sk_centro_costo,
         periodo_contable, glosa_general, glosa_detalle, debe, haber, monto_neto)
    SELECT
        d.id_asiento_detalle,
        c.id_asiento,
        c.numero_asiento,
        c.id_transaccion,
        YEAR(c.fecha_asiento) * 10000 + MONTH(c.fecha_asiento) * 100 + DAY(c.fecha_asiento),
        d.id_cuenta,
        dc.sk_cuenta_contable,
        d.id_centro_costo,
        cc.sk_centro_costo,
        c.periodo_contable,
        c.glosa_general,
        d.glosa_detalle,
        d.debe,
        d.haber,
        d.debe - d.haber
    FROM dbo.tbl_asientos_detalle d
    INNER JOIN dbo.tbl_asientos_cabecera c ON c.id_asiento = d.id_asiento
    INNER JOIN dw.dim_cuenta_contable dc
        ON dc.id_cuenta = d.id_cuenta
       AND dc.fecha_inicio_vigencia <= c.fecha_asiento
       AND (dc.fecha_fin_vigencia IS NULL OR c.fecha_asiento < dc.fecha_fin_vigencia)
    LEFT JOIN dw.dim_centro_costo cc
        ON cc.id_centro_costo = d.id_centro_costo
       AND cc.fecha_inicio_vigencia <= c.fecha_asiento
       AND (cc.fecha_fin_vigencia IS NULL OR c.fecha_asiento < cc.fecha_fin_vigencia)
    WHERE d.id_asiento_detalle > @ultima_clave;

    DECLARE @ultima_clave_nueva INT = ISNULL((SELECT MAX(id_asiento_detalle) FROM dbo.tbl_asientos_detalle), @ultima_clave);

    IF EXISTS (SELECT 1 FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_asientos_contables')
        UPDATE dw.tbl_control_carga_incremental
        SET ultima_clave_cargada = @ultima_clave_nueva, fecha_ultima_carga = GETDATE()
        WHERE nombre_hecho = 'fact_asientos_contables';
    ELSE
        INSERT INTO dw.tbl_control_carga_incremental (nombre_hecho, ultima_clave_cargada)
        VALUES ('fact_asientos_contables', @ultima_clave_nueva);
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_fact_margen_venta_incremental (v9): misma lógica de
-- alta marca que la anterior, pero sobre dbo.tbl_ventas_detalle /
-- dw.fact_margen_venta, clave natural = id_venta_detalle. El cálculo de
-- costo_directo es idéntico (línea por línea) al de la versión completa,
-- incluyendo el costeo point-in-time vía di.modo_obtencion desde v12.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_fact_margen_venta_incremental', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_fact_margen_venta_incremental;
GO

CREATE PROCEDURE dw.sp_cargar_dw_fact_margen_venta_incremental
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ultima_clave INT = ISNULL(
        (SELECT ultima_clave_cargada FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_margen_venta'),
        0);

    INSERT INTO dw.fact_margen_venta
        (id_venta_detalle, id_venta_devengada, folio_factura, id_fecha,
         id_item, sk_item, id_tercero, sk_tercero, id_centro_costo, sk_centro_costo,
         id_empleado, sk_empleado, modo_obtencion, cantidad, precio_unitario, ingreso_neto, costo_directo, margen_contribucion)
    SELECT
        vd.id_venta_detalle,
        vv.id_venta_devengada,
        vv.folio_factura,
        YEAR(vv.fecha_emision) * 10000 + MONTH(vv.fecha_emision) * 100 + DAY(vv.fecha_emision),
        vd.id_item,
        di.sk_item,
        vv.id_tercero,
        dt.sk_tercero,
        vv.id_centro_costo,
        dc.sk_centro_costo,
        vv.id_empleado,
        de.sk_empleado,
        di.modo_obtencion,
        vd.cantidad,
        vd.precio_unitario,
        vd.subtotal_neto,
        costo.costo_directo,
        vd.subtotal_neto - costo.costo_directo
    FROM dbo.tbl_ventas_detalle vd
    INNER JOIN dbo.tbl_ventas_devengadas vv ON vv.id_venta_devengada = vd.id_venta_devengada
    INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
    INNER JOIN dw.dim_item di
        ON di.id_item = vd.id_item
       AND di.fecha_inicio_vigencia <= vv.fecha_emision
       AND (di.fecha_fin_vigencia IS NULL OR vv.fecha_emision < di.fecha_fin_vigencia)
    INNER JOIN dw.dim_tercero dt
        ON dt.id_tercero = vv.id_tercero
       AND dt.fecha_inicio_vigencia <= vv.fecha_emision
       AND (dt.fecha_fin_vigencia IS NULL OR vv.fecha_emision < dt.fecha_fin_vigencia)
    LEFT JOIN dw.dim_centro_costo dc
        ON dc.id_centro_costo = vv.id_centro_costo
       AND dc.fecha_inicio_vigencia <= vv.fecha_emision
       AND (dc.fecha_fin_vigencia IS NULL OR vv.fecha_emision < dc.fecha_fin_vigencia)
    LEFT JOIN dw.dim_empleado de
        ON de.id_empleado = vv.id_empleado
       AND de.fecha_inicio_vigencia <= vv.fecha_emision
       AND (de.fecha_fin_vigencia IS NULL OR vv.fecha_emision < de.fecha_fin_vigencia)
    CROSS APPLY (
        SELECT
            CASE
                WHEN di.modo_obtencion = 'COMPRADO_REVENTA' THEN
                    ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad)
                            FROM dbo.tbl_movimientos_inventario mi
                            WHERE mi.origen_documento = 'VENTA'
                              AND mi.tipo_movimiento = 'SALIDA'
                              AND mi.id_referencia = vv.id_venta_devengada
                              AND mi.id_item = vd.id_item), 0)
                WHEN di.modo_obtencion IN ('FABRICADO', 'SERVICIO') THEN
                    vd.cantidad * ISNULL((SELECT SUM(hh.cantidad_horas * ph.costo_hora_referencia)
                                           FROM dbo.tbl_item_composicion_hh hh
                                           INNER JOIN dbo.cat_perfiles_hh ph ON ph.id_perfil_hh = hh.id_perfil_hh
                                           WHERE hh.id_item = vd.id_item), 0)
                    + ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad)
                              FROM dbo.tbl_movimientos_inventario mi
                              WHERE mi.origen_documento = 'VENTA'
                                AND mi.tipo_movimiento = 'SALIDA'
                                AND mi.id_referencia = vv.id_venta_devengada
                                AND mi.id_insumo IN (
                                    SELECT ci.id_insumo FROM dbo.tbl_item_composicion_insumos ci WHERE ci.id_item = vd.id_item
                                )), 0)
                ELSE 0
            END AS costo_directo
    ) costo
    WHERE vd.id_venta_detalle > @ultima_clave;

    DECLARE @ultima_clave_nueva INT = ISNULL((SELECT MAX(id_venta_detalle) FROM dbo.tbl_ventas_detalle), @ultima_clave);

    IF EXISTS (SELECT 1 FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_margen_venta')
        UPDATE dw.tbl_control_carga_incremental
        SET ultima_clave_cargada = @ultima_clave_nueva, fecha_ultima_carga = GETDATE()
        WHERE nombre_hecho = 'fact_margen_venta';
    ELSE
        INSERT INTO dw.tbl_control_carga_incremental (nombre_hecho, ultima_clave_cargada)
        VALUES ('fact_margen_venta', @ultima_clave_nueva);
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_completo: orquestador. Ejecutar al cierre de cada
-- periodo (o con la frecuencia que se requiera para refrescar el BI).
-- Recomendado: ejecutar DESPUÉS de dbo.sp_prorratear_cif_periodo, para
-- que la absorción de CIF del periodo ya esté reflejada en los asientos
-- antes de cargar el DW.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_completo', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_completo;
GO

CREATE PROCEDURE dw.sp_cargar_dw_completo
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

            -- 1. Vaciar los HECHOS primero (tienen FK hacia las dimensiones)
            DELETE FROM dw.fact_margen_venta;
            DELETE FROM dw.fact_asientos_contables;

            -- 2. Versionar las DIMENSIONES (Tipo 2 -- v8, nunca se vacían)
            EXEC dw.sp_cargar_dw_dimensiones;

            -- 3. Recargar dim_tiempo cubriendo el rango de fechas del OLTP
            DECLARE @fecha_min DATE, @fecha_max DATE;

            SELECT @fecha_min = MIN(f), @fecha_max = MAX(f)
            FROM (
                SELECT fecha_asiento AS f FROM dbo.tbl_asientos_cabecera
                UNION ALL
                SELECT fecha_emision FROM dbo.tbl_ventas_devengadas
            ) fechas;

            IF @fecha_min IS NOT NULL
                EXEC dw.sp_cargar_dw_dim_tiempo @fecha_desde = @fecha_min, @fecha_hasta = @fecha_max;

            -- 4. Reconstruir los HECHOS
            EXEC dw.sp_cargar_dw_fact_asientos_contables;
            EXEC dw.sp_cargar_dw_fact_margen_venta;

        COMMIT TRANSACTION;

        PRINT 'Carga completa del Data Warehouse (dw) finalizada exitosamente.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en dw.sp_cargar_dw_completo: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO

------------------------------------------------------------------------
-- dw.sp_cargar_dw_incremental (v9): orquestador INCREMENTAL. Reemplaza
-- a dw.sp_cargar_dw_completo para las ejecuciones RUTINARIAS -- deja a
-- este último solo para el despliegue inicial (bootstrap, cuando aún no
-- hay nada en dw.tbl_control_carga_incremental, caso en que las SP
-- incrementales igual cargan todo desde cero) o para forzar una
-- reconstrucción total del DW.
--
-- Pasos:
--   1. Dimensiones: SIN CAMBIOS respecto a v8 -- dw.sp_cargar_dw_
--      dimensiones YA es incremental por naturaleza (SCD Tipo 2: solo
--      versiona lo que cambió, nunca vacía ni reconstruye dimensiones
--      completas).
--   2. dim_tiempo: se extiende SOLO para el rango de fechas de las filas
--      NUEVAS (las que están por encima de la alta marca de cada hecho),
--      no para todo el histórico -- evita releer todo el OLTP solo para
--      calcular MIN/MAX.
--   3. Hechos: se insertan SOLO las filas nuevas vía las dos SP
--      incrementales (altas marcas en dw.tbl_control_carga_incremental).
--
-- LIMITACIÓN (v9): este enfoque asume que dbo.tbl_asientos_detalle y
-- dbo.tbl_ventas_detalle son de SOLO-INSERCIÓN (verificado: ningún
-- UPDATE ni DELETE las toca en todo este esquema -- las correcciones se
-- registran como asientos/ventas nuevos). Si alguna vez se corrige una
-- fila histórica directamente en dbo (UPDATE o DELETE manual fuera de
-- este flujo), la carga incremental NO lo detectará -- en ese caso hay
-- que ejecutar dw.sp_cargar_dw_completo para forzar una reconstrucción
-- total y dejar el DW consistente con dbo otra vez.
------------------------------------------------------------------------
IF OBJECT_ID('dw.sp_cargar_dw_incremental', 'P') IS NOT NULL
    DROP PROCEDURE dw.sp_cargar_dw_incremental;
GO

CREATE PROCEDURE dw.sp_cargar_dw_incremental
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

            -- 1. Versionar las DIMENSIONES (Tipo 2 -- ya es incremental, sin cambios)
            EXEC dw.sp_cargar_dw_dimensiones;

            -- 2. Extender dim_tiempo SOLO para el rango de las filas nuevas
            DECLARE @ultima_asiento INT = ISNULL(
                (SELECT ultima_clave_cargada FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_asientos_contables'), 0);
            DECLARE @ultima_venta INT = ISNULL(
                (SELECT ultima_clave_cargada FROM dw.tbl_control_carga_incremental WHERE nombre_hecho = 'fact_margen_venta'), 0);

            DECLARE @fecha_min DATE, @fecha_max DATE;

            SELECT @fecha_min = MIN(f), @fecha_max = MAX(f)
            FROM (
                SELECT c.fecha_asiento AS f
                FROM dbo.tbl_asientos_detalle d
                INNER JOIN dbo.tbl_asientos_cabecera c ON c.id_asiento = d.id_asiento
                WHERE d.id_asiento_detalle > @ultima_asiento
                UNION ALL
                SELECT vv.fecha_emision
                FROM dbo.tbl_ventas_detalle vd
                INNER JOIN dbo.tbl_ventas_devengadas vv ON vv.id_venta_devengada = vd.id_venta_devengada
                WHERE vd.id_venta_detalle > @ultima_venta
            ) fechas;

            IF @fecha_min IS NOT NULL
                EXEC dw.sp_cargar_dw_dim_tiempo @fecha_desde = @fecha_min, @fecha_hasta = @fecha_max;

            -- 3. Insertar SOLO las filas nuevas de los HECHOS
            EXEC dw.sp_cargar_dw_fact_asientos_contables_incremental;
            EXEC dw.sp_cargar_dw_fact_margen_venta_incremental;

        COMMIT TRANSACTION;

        PRINT 'Carga incremental del Data Warehouse (dw) finalizada exitosamente.';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en dw.sp_cargar_dw_incremental: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO

PRINT 'Stored procedures de carga del Data Warehouse (dw) creados exitosamente.';
GO
