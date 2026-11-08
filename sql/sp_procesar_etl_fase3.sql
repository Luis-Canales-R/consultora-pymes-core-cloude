-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs (Fase 3)
-- Objeto: Stored Procedure de Validación, Auditoría y Carga Masiva ETL
-- ====================================================================
-- PRERREQUISITOS: Ejecutar previamente, en este orden:
--   1) sql/crear_modulo_terceros.sql
--   2) sql/crear_modulo_centros_costo_empleados.sql
--   3) sql/crear_modulo_contabilidad_transacciones.sql
--   4) sql/crear_modulo_productos_servicios.sql
--   5) sql/crear_tablas_transaccionales_granular.sql
--   6) sql/crear_tablas_mapeo.sql
--   7) sql/crear_tabla_staging.sql
--   8) sql/crear_tabla_log_errores.sql
--
-- CAMBIOS RESPECTO A LA VERSIÓN ANTERIOR (v1 -> v2):
--   1. Las validaciones quedan acotadas a @nombre_archivo (y opcionalmente
--      @pestana_origen); v1 validaba la totalidad de tbl_staging_carga en
--      cada corrida, re-auditando filas de cargas anteriores.
--   2. Se agregan las validaciones de formato de fecha y de homologación
--      de producto/insumo que exige docs/fase3_motor_etl.md y que v1 no
--      implementaba.
--   3. Se agrega la validación propia de Movimientos_Caja (cuenta
--      bancaria existente en cat_plan_cuentas y tipo_flujo en dominio).
--   4. Se agrega el paso que v1 no tenía: la carga real de las filas que
--      superan todas las validaciones hacia las tablas del Core
--      (tbl_ventas_devengadas/detalle, tbl_ordenes_compra/detalle,
--      tbl_movimientos_caja), dentro de una transacción atómica.
--
-- CAMBIOS v2 -> v3 (Control de Gestión):
--   5. Se valida centro_costo_raw/empleado_raw (opcionales, por código/RUT
--      directo contra tbl_centros_costo/tbl_empleados_usuarios, sin
--      homologación) para las 3 pestañas.
--   6. Tras cargar cada documento al Core (venta, compra, movimiento de
--      caja), el SP llama a sp_registrar_asiento_contable y genera su
--      asiento de partida doble automáticamente, usando el mapeo de
--      cuentas por ítem (tbl_productos_servicios.id_cuenta_ingreso /
--      id_cuenta_costo_gasto) con cuentas "default" de respaldo.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.sp_procesar_etl_fase3', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_procesar_etl_fase3;
GO

CREATE PROCEDURE dbo.sp_procesar_etl_fase3
    @nombre_archivo VARCHAR(150),
    @pestana_origen VARCHAR(50) = NULL   -- NULL = procesar las 3 pestañas presentes para este archivo
AS
BEGIN
    SET NOCOUNT ON;

    PRINT '------------------------------------------------';
    PRINT 'Iniciando validación ETL para el archivo: ' + @nombre_archivo;
    PRINT '------------------------------------------------';

    BEGIN TRY

        ------------------------------------------------------------------
        -- 0. Reiniciar el estado de esta corrida (solo para este archivo)
        ------------------------------------------------------------------
        DELETE FROM dbo.tbl_log_errores_etl
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen);

        UPDATE dbo.tbl_staging_carga
        SET estado_carga = 'PENDIENTE', fecha_proceso = NULL
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga <> 'CARGADO';

        ------------------------------------------------------------------
        -- 1. VALIDACIONES COMUNES A Ventas_Devengadas Y Compras_y_Gastos
        ------------------------------------------------------------------

        -- 1.1 Formato de fecha inválido (se exige AAAA-MM-DD estricto)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'FORMATO_FECHA_INVALIDO',
               'El valor de fecha [' + ISNULL(fecha_raw, 'VACIO') + '] no cumple el formato AAAA-MM-DD.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND (fecha_raw IS NULL
               OR fecha_raw NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
               OR TRY_CONVERT(DATE, fecha_raw, 23) IS NULL);

        -- 1.2 Cliente / Proveedor no homologado (map_clientes homologa cualquier
        --     tercero -- cliente o proveedor -- hacia tbl_terceros)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'CLIENTE_NO_HOMOLOGADO',
               'El tercero informal [' + ISNULL(t.tercero_informal_raw, 'VACIO') + '] no se encuentra homologado en map_clientes.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.map_clientes c ON t.tercero_informal_raw = c.nombre_informal_excel
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND c.id_map_cliente IS NULL;

        -- 1.3 Ítem / Insumo no homologado
        -- v7 (Kardex Real de Insumos): Compras_y_Gastos puede homologar contra
        -- map_productos (compra de un ítem para reventa/producción) O contra
        -- map_insumos (compra de una materia prima/insumo); Ventas_Devengadas
        -- solo puede homologar contra map_productos (no se vende un insumo).
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'ITEM_NO_HOMOLOGADO',
               'La descripción de ítem/insumo [' + ISNULL(t.item_informal_raw, 'VACIO') + '] no se encuentra homologada en map_productos' +
               CASE WHEN t.pestana_origen = 'Compras_y_Gastos' THEN ' ni en map_insumos.' ELSE '.' END
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.map_productos p ON t.item_informal_raw = p.descripcion_libre_excel
        LEFT JOIN dbo.map_insumos mi ON t.pestana_origen = 'Compras_y_Gastos' AND t.item_informal_raw = mi.descripcion_libre_excel
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND p.id_map_producto IS NULL
          AND mi.id_map_insumo IS NULL;

        -- 1.4 Cantidad inválida (debe ser numérica y > 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'CANTIDAD_INVALIDA',
               'La cantidad [' + ISNULL(cantidad_raw, 'VACIO') + '] no es numérica o no es mayor a cero.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (TRY_CAST(cantidad_raw AS DECIMAL(18,4)) IS NULL OR TRY_CAST(cantidad_raw AS DECIMAL(18,4)) <= 0);

        -- 1.5 Precio unitario inválido (debe ser numérico y >= 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'PRECIO_INVALIDO',
               'El precio unitario [' + ISNULL(precio_unitario_raw, 'VACIO') + '] no es numérico o es negativo.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (TRY_CAST(precio_unitario_raw AS DECIMAL(18,2)) IS NULL OR TRY_CAST(precio_unitario_raw AS DECIMAL(18,2)) < 0);

        -- 1.6 Folio vacío
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'FOLIO_VACIO',
               'El folio del documento no fue informado.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos')
          AND (folio_documento_raw IS NULL OR LTRIM(RTRIM(folio_documento_raw)) = '');

        -- 1.7 Estado de documento fuera de dominio
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'ESTADO_INVALIDO',
               'El estado [' + ISNULL(estado_documento_raw, 'VACIO') + '] no es válido para la pestaña ' + pestana_origen + '.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND (
                (pestana_origen = 'Ventas_Devengadas' AND estado_documento_raw NOT IN ('DEVENGADO','FACTURADO','PAGADO','ANULADO'))
             OR (pestana_origen = 'Compras_y_Gastos'  AND estado_documento_raw NOT IN ('BORRADOR','APROBADA','RECIBIDA','ANULADA'))
              );

        ------------------------------------------------------------------
        -- 2. VALIDACIONES PROPIAS DE Movimientos_Caja
        ------------------------------------------------------------------

        -- 2.1 Cuenta bancaria no existe en el plan de cuentas
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'CUENTA_BANCARIA_NO_EXISTE',
               'El código de cuenta [' + ISNULL(t.cuenta_bancaria_raw, 'VACIO') + '] no existe en cat_plan_cuentas.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.cat_plan_cuentas cp ON t.cuenta_bancaria_raw = cp.codigo_cuenta
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.pestana_origen = 'Movimientos_Caja'
          AND cp.id_cuenta IS NULL;

        -- 2.2 Tipo de flujo fuera de dominio
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'TIPO_FLUJO_INVALIDO',
               'El tipo de flujo [' + ISNULL(tipo_flujo_raw, 'VACIO') + '] no es válido.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (tipo_flujo_raw IS NULL OR tipo_flujo_raw NOT IN ('INGRESO','EGRESO','TRASPASO_HASTA','TRASPASO_DESDE'));

        -- 2.3 Monto absoluto inválido (numérico y > 0)
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'MONTO_INVALIDO',
               'El monto absoluto [' + ISNULL(monto_absoluto_raw, 'VACIO') + '] no es numérico o no es mayor a cero.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (TRY_CAST(monto_absoluto_raw AS DECIMAL(18,2)) IS NULL OR TRY_CAST(monto_absoluto_raw AS DECIMAL(18,2)) <= 0);

        -- 2.4 Glosa obligatoria vacía
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT nombre_archivo, pestana_origen, numero_fila, 'GLOSA_VACIA',
               'La glosa del movimiento de caja no fue informada.'
        FROM dbo.tbl_staging_carga
        WHERE nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
          AND estado_carga = 'PENDIENTE'
          AND pestana_origen = 'Movimientos_Caja'
          AND (glosa IS NULL OR LTRIM(RTRIM(glosa)) = '');

        ------------------------------------------------------------------
        -- 2b. (v3) VALIDACIONES DE CONTROL DE GESTIÓN, COMUNES A LAS 3 PESTAÑAS
        --     Ambas dimensiones son opcionales: solo se valida si vienen
        --     informadas (no se exige diligenciar centro de costo/empleado
        --     para poder cargar un documento).
        ------------------------------------------------------------------

        -- 2b.1 Centro de costo informado pero inexistente
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'CENTRO_COSTO_NO_EXISTE',
               'El código de centro de costo [' + t.centro_costo_raw + '] no existe en tbl_centros_costo.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.tbl_centros_costo cc ON t.centro_costo_raw = cc.codigo_cc
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.centro_costo_raw IS NOT NULL
          AND LTRIM(RTRIM(t.centro_costo_raw)) <> ''
          AND cc.id_centro_costo IS NULL;

        -- 2b.2 Empleado informado pero inexistente
        INSERT INTO dbo.tbl_log_errores_etl (nombre_archivo, pestana_origen, numero_fila, tipo_error, detalle_mensaje)
        SELECT t.nombre_archivo, t.pestana_origen, t.numero_fila, 'EMPLEADO_NO_EXISTE',
               'El RUT de empleado [' + t.empleado_raw + '] no existe en tbl_empleados_usuarios.'
        FROM dbo.tbl_staging_carga t
        LEFT JOIN dbo.tbl_empleados_usuarios e ON t.empleado_raw = e.rut_dni
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND t.empleado_raw IS NOT NULL
          AND LTRIM(RTRIM(t.empleado_raw)) <> ''
          AND e.id_empleado IS NULL;

        ------------------------------------------------------------------
        -- 3. MARCAR COMO RECHAZADAS LAS FILAS CON AL MENOS UN ERROR
        ------------------------------------------------------------------
        UPDATE t
        SET t.estado_carga = 'RECHAZADO', t.fecha_proceso = GETDATE()
        FROM dbo.tbl_staging_carga t
        WHERE t.nombre_archivo = @nombre_archivo
          AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
          AND t.estado_carga = 'PENDIENTE'
          AND EXISTS (
                SELECT 1 FROM dbo.tbl_log_errores_etl e
                WHERE e.nombre_archivo = t.nombre_archivo
                  AND e.pestana_origen = t.pestana_origen
                  AND e.numero_fila = t.numero_fila
              );

        ------------------------------------------------------------------
        -- 4. CARGA ATÓMICA AL CORE DE LAS FILAS QUE SIGUEN "PENDIENTE"
        --    (superaron todas las validaciones anteriores)
        ------------------------------------------------------------------
        BEGIN TRANSACTION;

            -- Resolución de homologaciones e IDs de negocio en una tabla temporal
            SELECT
                t.id_staging, t.pestana_origen, t.folio_documento_raw,
                mc.id_tercero_oficial, mp.id_item_oficial,
                mi.id_insumo_oficial, -- v7 (Kardex Real de Insumos): solo se resuelve para Compras_y_Gastos
                TRY_CONVERT(DATE, t.fecha_raw, 23)                AS fecha_doc,
                TRY_CAST(t.cantidad_raw AS DECIMAL(18,4))         AS cantidad,
                TRY_CAST(t.precio_unitario_raw AS DECIMAL(18,2))  AS precio_unitario,
                CAST(t.cantidad_raw AS DECIMAL(18,4)) * CAST(t.precio_unitario_raw AS DECIMAL(18,2)) AS subtotal_neto,
                -- v7: cat_insumos_recursos no tiene columna aplica_iva (no es un
                -- ítem de catálogo comercial); se asume que toda compra de
                -- insumo llega con factura de proveedor y por lo tanto con IVA.
                CASE WHEN mi.id_insumo_oficial IS NOT NULL THEN 1 ELSE p.aplica_iva END AS aplica_iva,
                t.estado_documento_raw,
                -- v3 (Control de Gestión): dimensiones e imputación contable
                cc.id_centro_costo,
                emp.id_empleado,
                ISNULL(p.id_cuenta_ingreso, 4113)      AS id_cuenta_ingreso,   -- default: Otros Ingresos Operacionales
                ISNULL(p.id_cuenta_costo_gasto, 6215)  AS id_cuenta_costo_gasto, -- default: Gastos Operacionales Generales
                p.modo_obtencion -- v4/v6: COMPRADO_REVENTA | FABRICADO | SERVICIO | NULL (sin clasificar)
            INTO #resuelto_comercial
            FROM dbo.tbl_staging_carga t
            LEFT JOIN dbo.map_clientes mc ON t.tercero_informal_raw = mc.nombre_informal_excel
            LEFT JOIN dbo.map_productos mp ON t.item_informal_raw = mp.descripcion_libre_excel
            LEFT JOIN dbo.tbl_productos_servicios p ON mp.id_item_oficial = p.id_item
            LEFT JOIN dbo.map_insumos mi ON t.pestana_origen = 'Compras_y_Gastos' AND t.item_informal_raw = mi.descripcion_libre_excel -- v7
            LEFT JOIN dbo.tbl_centros_costo cc ON t.centro_costo_raw = cc.codigo_cc
            LEFT JOIN dbo.tbl_empleados_usuarios emp ON t.empleado_raw = emp.rut_dni
            WHERE t.nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
              AND t.estado_carga = 'PENDIENTE'
              AND t.pestana_origen IN ('Ventas_Devengadas', 'Compras_y_Gastos');

            ---------------------------------------------------
            -- 4.1 VENTAS_DEVENGADAS: cabecera (por folio) + detalle
            ---------------------------------------------------
            DECLARE @nuevas_ventas TABLE (id_venta_devengada INT, folio_factura VARCHAR(50));

            INSERT INTO dbo.tbl_ventas_devengadas
                (id_venta_devengada, folio_factura, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_venta, id_centro_costo, id_empleado)
            OUTPUT inserted.id_venta_devengada, inserted.folio_factura INTO @nuevas_ventas
            SELECT
                (SELECT ISNULL(MAX(id_venta_devengada), 0) FROM dbo.tbl_ventas_devengadas)
                    + ROW_NUMBER() OVER (ORDER BY r.folio_documento_raw),
                r.folio_documento_raw,
                MIN(r.id_tercero_oficial),
                MIN(r.fecha_doc),
                SUM(r.subtotal_neto),
                SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                SUM(r.subtotal_neto) + SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                MIN(r.estado_documento_raw),
                MIN(r.id_centro_costo),
                MIN(r.id_empleado)
            FROM #resuelto_comercial r
            WHERE r.pestana_origen = 'Ventas_Devengadas'
              AND NOT EXISTS (SELECT 1 FROM dbo.tbl_ventas_devengadas v WHERE v.folio_factura = r.folio_documento_raw)
            GROUP BY r.folio_documento_raw;

            INSERT INTO dbo.tbl_ventas_detalle
                (id_venta_detalle, id_venta_devengada, id_item, cantidad, precio_unitario, subtotal_neto)
            SELECT
                (SELECT ISNULL(MAX(id_venta_detalle), 0) FROM dbo.tbl_ventas_detalle)
                    + ROW_NUMBER() OVER (ORDER BY r.id_staging),
                v.id_venta_devengada,
                r.id_item_oficial,
                r.cantidad,
                r.precio_unitario,
                r.subtotal_neto
            FROM #resuelto_comercial r
            INNER JOIN dbo.tbl_ventas_devengadas v ON v.folio_factura = r.folio_documento_raw
            WHERE r.pestana_origen = 'Ventas_Devengadas';

            ---------------------------------------------------
            -- 4.1b (v3) ASIENTO AUTOMÁTICO POR CADA VENTA NUEVA
            --   Debe: Clientes (1121) por monto_total
            --   Haber: Ingreso (por cada cuenta de ingreso distinta entre
            --          los ítems del detalle) + IVA Débito Fiscal (2141)
            ---------------------------------------------------
            DECLARE @id_venta_actual INT, @folio_actual VARCHAR(50), @id_asiento_generado INT;
            DECLARE cur_ventas CURSOR LOCAL FAST_FORWARD FOR
                SELECT id_venta_devengada, folio_factura FROM @nuevas_ventas;
            OPEN cur_ventas;
            FETCH NEXT FROM cur_ventas INTO @id_venta_actual, @folio_actual;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @lineas_venta dbo.tipo_asiento_detalle;
                DECLARE @v_monto_total DECIMAL(18,2), @v_monto_iva DECIMAL(18,2), @v_fecha DATE, @v_cc INT;

                SELECT @v_monto_total = monto_total, @v_monto_iva = monto_iva,
                       @v_fecha = fecha_emision, @v_cc = id_centro_costo
                FROM dbo.tbl_ventas_devengadas WHERE id_venta_devengada = @id_venta_actual;

                INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (1121, @v_monto_total, 0.00, NULL, 'Cuenta por cobrar Venta ' + @folio_actual);

                INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                SELECT d.id_cuenta_ingreso_resuelta, 0.00, SUM(d.subtotal_neto), @v_cc, 'Ingreso devengado Venta ' + @folio_actual
                FROM (
                    SELECT vd.subtotal_neto,
                           ISNULL((SELECT ps.id_cuenta_ingreso FROM dbo.tbl_productos_servicios ps WHERE ps.id_item = vd.id_item), 4113) AS id_cuenta_ingreso_resuelta
                    FROM dbo.tbl_ventas_detalle vd
                    WHERE vd.id_venta_devengada = @id_venta_actual
                ) d
                GROUP BY d.id_cuenta_ingreso_resuelta;

                ---------------------------------------------------
                -- 4.1c (v4/v6/v7 - Costeo Directo por Flujo de Venta) COSTO
                -- DIRECTO de la venta, según modo_obtencion de cada ítem:
                --   COMPRADO_REVENTA -> sale del kardex (CPP) vía
                --     sp_registrar_movimiento_inventario; Debe Costo/Gasto
                --     del ítem (fallback 5111) / Haber Inventario (1141).
                --   FABRICADO -> MOD (tbl_item_composicion_hh, a costo
                --     estándar/referencia, pues la mano de obra no se
                --     inventaría) + MPD (v7: ya NO a costo estándar; se
                --     consume ítem por ítem desde el kardex REAL de insumos
                --     vía sp_registrar_movimiento_inventario, igual mecánica
                --     que COMPRADO_REVENTA); Debe Costo/Gasto del ítem
                --     (fallback 5111) / Haber Remuneraciones por Pagar
                --     (2131, porción MOD estándar) y Haber Materia Prima
                --     Aplicada a Producción por Regularizar (2123, porción
                --     MPD a costo REAL de kardex).
                --   SERVICIO (v6) -> Honorarios (tbl_item_composicion_hh, a
                --     costo estándar) + Insumos (v7: a costo REAL de kardex,
                --     misma mecánica que FABRICADO); Debe Costo/Gasto del
                --     ítem (fallback 5113 Honorarios/Servicios Subcontratados)
                --     / Haber Honorarios Profesionales por Pagar (2125,
                --     porción honorarios estándar) y Haber Insumos Aplicados
                --     a Servicios por Regularizar (2124, porción insumos a
                --     costo REAL). No aplica CIF (es exclusivo de producción).
                --   NULL (ítem sin clasificar) -> sin leg de costo.
                --
                -- v7 NOTA OPERACIONAL: al consumirse desde el kardex real, una
                -- venta FABRICADO/SERVICIO fallará con "stock insuficiente" si
                -- los insumos de su BOM no fueron comprados (ingresados a
                -- kardex) en cantidad suficiente antes de la venta.
                ---------------------------------------------------

                -- COMPRADO_REVENTA: salida de kardex ítem por ítem (el CPP
                -- depende de la secuencia de salida, por lo que no se puede
                -- resolver con una agregación set-based).
                DECLARE @ci_id_item INT, @ci_cantidad DECIMAL(18,4), @ci_id_cuenta_costo INT, @ci_cpp_salida DECIMAL(18,4);
                DECLARE cur_costo_reventa CURSOR LOCAL FAST_FORWARD FOR
                    SELECT vd.id_item, vd.cantidad, ISNULL(ps.id_cuenta_costo_gasto, 5111)
                    FROM dbo.tbl_ventas_detalle vd
                    INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                    WHERE vd.id_venta_devengada = @id_venta_actual
                      AND ps.modo_obtencion = 'COMPRADO_REVENTA';
                OPEN cur_costo_reventa;
                FETCH NEXT FROM cur_costo_reventa INTO @ci_id_item, @ci_cantidad, @ci_id_cuenta_costo;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    EXEC dbo.sp_registrar_movimiento_inventario
                        @id_item = @ci_id_item,
                        @tipo_movimiento = 'SALIDA',
                        @cantidad = @ci_cantidad,
                        @origen_documento = 'VENTA',
                        @id_referencia = @id_venta_actual,
                        @glosa = 'Salida por Venta ' + @folio_actual,
                        @costo_unitario_resultante = @ci_cpp_salida OUTPUT;

                    IF @ci_cpp_salida > 0
                    BEGIN
                        INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                        VALUES (@ci_id_cuenta_costo, ROUND(@ci_cpp_salida * @ci_cantidad, 2), 0.00, @v_cc, 'Costo de Venta (CPP) ' + @folio_actual);

                        INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                        VALUES (1141, 0.00, ROUND(@ci_cpp_salida * @ci_cantidad, 2), @v_cc, 'Salida Inventario Venta ' + @folio_actual);
                    END

                    FETCH NEXT FROM cur_costo_reventa INTO @ci_id_item, @ci_cantidad, @ci_id_cuenta_costo;
                END
                CLOSE cur_costo_reventa;
                DEALLOCATE cur_costo_reventa;

                -- FABRICADO: MOD a costo estándar (BOM), agregado por cuenta
                -- de costo resuelta (no requiere kardex, es aritmética pura
                -- sobre tbl_item_composicion_hh). La MPD (insumos) se resuelve
                -- más abajo desde el kardex real (v7).
                DECLARE @fab_costos TABLE (mod_linea DECIMAL(18,2), id_cuenta_costo_resuelta INT);

                INSERT INTO @fab_costos (mod_linea, id_cuenta_costo_resuelta)
                SELECT
                    vd.cantidad * ISNULL((SELECT SUM(hh.cantidad_horas * ph.costo_hora_referencia)
                                           FROM dbo.tbl_item_composicion_hh hh
                                           INNER JOIN dbo.cat_perfiles_hh ph ON ph.id_perfil_hh = hh.id_perfil_hh
                                           WHERE hh.id_item = vd.id_item), 0),
                    ISNULL(ps.id_cuenta_costo_gasto, 5111)
                FROM dbo.tbl_ventas_detalle vd
                INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                WHERE vd.id_venta_devengada = @id_venta_actual
                  AND ps.modo_obtencion = 'FABRICADO';

                -- SERVICIO (v6): Honorarios a costo estándar (BOM), misma
                -- mecánica que el MOD de FABRICADO. Los Insumos se resuelven
                -- más abajo desde el kardex real (v7).
                DECLARE @serv_costos TABLE (honorarios_linea DECIMAL(18,2), id_cuenta_costo_resuelta INT);

                INSERT INTO @serv_costos (honorarios_linea, id_cuenta_costo_resuelta)
                SELECT
                    vd.cantidad * ISNULL((SELECT SUM(hh.cantidad_horas * ph.costo_hora_referencia)
                                           FROM dbo.tbl_item_composicion_hh hh
                                           INNER JOIN dbo.cat_perfiles_hh ph ON ph.id_perfil_hh = hh.id_perfil_hh
                                           WHERE hh.id_item = vd.id_item), 0),
                    ISNULL(ps.id_cuenta_costo_gasto, 5113)
                FROM dbo.tbl_ventas_detalle vd
                INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                WHERE vd.id_venta_devengada = @id_venta_actual
                  AND ps.modo_obtencion = 'SERVICIO';

                -- v7 (Kardex Real de Insumos): MPD (FABRICADO) e Insumos
                -- (SERVICIO) se consumen componente por componente del BOM
                -- desde el kardex real (CPP), igual mecánica que la salida
                -- COMPRADO_REVENTA de más arriba -- el CPP depende de la
                -- secuencia de salidas y no se puede resolver set-based.
                DECLARE @mpd_insumos_real TABLE (modo_obtencion VARCHAR(20), monto_real DECIMAL(18,2), id_cuenta_costo_resuelta INT);
                DECLARE @mi_id_insumo INT, @mi_cantidad_total DECIMAL(18,4), @mi_modo VARCHAR(20), @mi_id_cuenta_costo INT, @mi_cpp_salida DECIMAL(18,4);
                DECLARE cur_insumos_produccion_servicio CURSOR LOCAL FAST_FORWARD FOR
                    SELECT ci.id_insumo, vd.cantidad * ci.cantidad, ps.modo_obtencion,
                           ISNULL(ps.id_cuenta_costo_gasto, CASE WHEN ps.modo_obtencion = 'FABRICADO' THEN 5111 ELSE 5113 END)
                    FROM dbo.tbl_ventas_detalle vd
                    INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                    INNER JOIN dbo.tbl_item_composicion_insumos ci ON ci.id_item = vd.id_item
                    WHERE vd.id_venta_devengada = @id_venta_actual
                      AND ps.modo_obtencion IN ('FABRICADO', 'SERVICIO');
                OPEN cur_insumos_produccion_servicio;
                FETCH NEXT FROM cur_insumos_produccion_servicio INTO @mi_id_insumo, @mi_cantidad_total, @mi_modo, @mi_id_cuenta_costo;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    EXEC dbo.sp_registrar_movimiento_inventario
                        @id_insumo = @mi_id_insumo,
                        @tipo_movimiento = 'SALIDA',
                        @cantidad = @mi_cantidad_total,
                        @origen_documento = 'VENTA',
                        @id_referencia = @id_venta_actual,
                        @glosa = 'Consumo de insumo (BOM) por Venta ' + @folio_actual,
                        @costo_unitario_resultante = @mi_cpp_salida OUTPUT;

                    IF @mi_cpp_salida > 0
                        INSERT INTO @mpd_insumos_real (modo_obtencion, monto_real, id_cuenta_costo_resuelta)
                        VALUES (@mi_modo, ROUND(@mi_cpp_salida * @mi_cantidad_total, 2), @mi_id_cuenta_costo);

                    FETCH NEXT FROM cur_insumos_produccion_servicio INTO @mi_id_insumo, @mi_cantidad_total, @mi_modo, @mi_id_cuenta_costo;
                END
                CLOSE cur_insumos_produccion_servicio;
                DEALLOCATE cur_insumos_produccion_servicio;

                -- FABRICADO: Debe Costo (MOD estándar + MPD real) / Haber
                -- Remuneraciones por Pagar (2131, MOD) + Haber Materia Prima
                -- Aplicada por Regularizar (2123, MPD a costo real kardex).
                INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                SELECT d.id_cuenta_costo_resuelta, SUM(d.monto), 0.00, @v_cc, 'Costo Directo Producción (MOD+MPD real) Venta ' + @folio_actual
                FROM (
                    SELECT id_cuenta_costo_resuelta, mod_linea AS monto FROM @fab_costos
                    UNION ALL
                    SELECT id_cuenta_costo_resuelta, monto_real FROM @mpd_insumos_real WHERE modo_obtencion = 'FABRICADO'
                ) d
                GROUP BY d.id_cuenta_costo_resuelta
                HAVING SUM(d.monto) > 0;

                IF EXISTS (SELECT 1 FROM @fab_costos HAVING SUM(mod_linea) > 0)
                    INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    SELECT 2131, 0.00, SUM(mod_linea), @v_cc, 'Remuneraciones por Pagar (MOD) Venta ' + @folio_actual
                    FROM @fab_costos;

                IF EXISTS (SELECT 1 FROM @mpd_insumos_real WHERE modo_obtencion = 'FABRICADO')
                    INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    SELECT 2123, 0.00, SUM(monto_real), @v_cc, 'Materia Prima Consumida (Kardex Real) Venta ' + @folio_actual
                    FROM @mpd_insumos_real WHERE modo_obtencion = 'FABRICADO';

                -- SERVICIO (v6/v7): Debe Costo (Honorarios estándar + Insumos
                -- real) / Haber Honorarios Profesionales por Pagar (2125) +
                -- Haber Insumos Aplicados a Servicios por Regularizar (2124,
                -- a costo real kardex). No aplica CIF (exclusivo de producción).
                INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                SELECT d.id_cuenta_costo_resuelta, SUM(d.monto), 0.00, @v_cc, 'Costo Directo Servicio (Honorarios+Insumos real) Venta ' + @folio_actual
                FROM (
                    SELECT id_cuenta_costo_resuelta, honorarios_linea AS monto FROM @serv_costos
                    UNION ALL
                    SELECT id_cuenta_costo_resuelta, monto_real FROM @mpd_insumos_real WHERE modo_obtencion = 'SERVICIO'
                ) d
                GROUP BY d.id_cuenta_costo_resuelta
                HAVING SUM(d.monto) > 0;

                IF EXISTS (SELECT 1 FROM @serv_costos HAVING SUM(honorarios_linea) > 0)
                    INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    SELECT 2125, 0.00, SUM(honorarios_linea), @v_cc, 'Honorarios Profesionales por Pagar Venta ' + @folio_actual
                    FROM @serv_costos;

                IF EXISTS (SELECT 1 FROM @mpd_insumos_real WHERE modo_obtencion = 'SERVICIO')
                    INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    SELECT 2124, 0.00, SUM(monto_real), @v_cc, 'Insumos Consumidos (Kardex Real) Venta ' + @folio_actual
                    FROM @mpd_insumos_real WHERE modo_obtencion = 'SERVICIO';

                IF @v_monto_iva > 0
                    INSERT INTO @lineas_venta (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2141, 0.00, @v_monto_iva, NULL, 'IVA Débito Fiscal Venta ' + @folio_actual);

                EXEC dbo.sp_registrar_asiento_contable
                    @id_transaccion = NULL,
                    @fecha_asiento = @v_fecha,
                    @glosa_general = 'Devengamiento automático Venta ' + @folio_actual + ' (ETL Fase 3)',
                    @periodo_contable = CONVERT(VARCHAR(7), @v_fecha, 23),
                    @lineas = @lineas_venta,
                    @id_asiento_out = @id_asiento_generado OUTPUT;

                FETCH NEXT FROM cur_ventas INTO @id_venta_actual, @folio_actual;
            END
            CLOSE cur_ventas;
            DEALLOCATE cur_ventas;

            ---------------------------------------------------
            -- 4.2 COMPRAS_Y_GASTOS: cabecera (por folio) + detalle
            ---------------------------------------------------
            DECLARE @nuevas_compras TABLE (id_orden_compra INT, folio_oc VARCHAR(50));

            INSERT INTO dbo.tbl_ordenes_compra
                (id_orden_compra, folio_oc, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_oc, id_centro_costo, id_empleado)
            OUTPUT inserted.id_orden_compra, inserted.folio_oc INTO @nuevas_compras
            SELECT
                (SELECT ISNULL(MAX(id_orden_compra), 0) FROM dbo.tbl_ordenes_compra)
                    + ROW_NUMBER() OVER (ORDER BY r.folio_documento_raw),
                r.folio_documento_raw,
                MIN(r.id_tercero_oficial),
                MIN(r.fecha_doc),
                SUM(r.subtotal_neto),
                SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                SUM(r.subtotal_neto) + SUM(CASE WHEN r.aplica_iva = 1 THEN r.subtotal_neto * 0.19 ELSE 0 END),
                MIN(r.estado_documento_raw),
                MIN(r.id_centro_costo),
                MIN(r.id_empleado)
            FROM #resuelto_comercial r
            WHERE r.pestana_origen = 'Compras_y_Gastos'
              AND NOT EXISTS (SELECT 1 FROM dbo.tbl_ordenes_compra o WHERE o.folio_oc = r.folio_documento_raw)
            GROUP BY r.folio_documento_raw;

            -- v4/v7 (Costeo Directo por Flujo de Venta / Kardex Real de
            -- Insumos): se captura el detalle recién insertado para alimentar
            -- el kardex (ENTRADA) de los ítems COMPRADO_REVENTA y de los
            -- insumos comprados, sin necesidad de volver a resolverlos.
            DECLARE @nuevo_detalle_compra TABLE (
                id_compra_detalle INT, id_orden_compra INT, id_item INT, id_insumo INT,
                cantidad DECIMAL(18,4), precio_unitario DECIMAL(18,2)
            );

            INSERT INTO dbo.tbl_compras_detalle
                (id_compra_detalle, id_orden_compra, id_item, id_insumo, cantidad, precio_unitario, subtotal_neto)
            OUTPUT inserted.id_compra_detalle, inserted.id_orden_compra, inserted.id_item, inserted.id_insumo,
                   inserted.cantidad, inserted.precio_unitario INTO @nuevo_detalle_compra
            SELECT
                (SELECT ISNULL(MAX(id_compra_detalle), 0) FROM dbo.tbl_compras_detalle)
                    + ROW_NUMBER() OVER (ORDER BY r.id_staging),
                o.id_orden_compra,
                r.id_item_oficial,    -- v7: NULL si la fila homologó contra map_insumos
                r.id_insumo_oficial,  -- v7: NULL si la fila homologó contra map_productos
                r.cantidad,
                r.precio_unitario,
                r.subtotal_neto
            FROM #resuelto_comercial r
            INNER JOIN dbo.tbl_ordenes_compra o ON o.folio_oc = r.folio_documento_raw
            WHERE r.pestana_origen = 'Compras_y_Gastos';

            DROP TABLE #resuelto_comercial;

            ---------------------------------------------------
            -- 4.2a (v4/v7) ENTRADA A KARDEX de los ítems COMPRADO_REVENTA y
            -- de TODOS los insumos del detalle recién insertado (v7: una
            -- compra de insumo siempre entra a kardex, pues es el único
            -- flujo de obtención de insumos). Las compras de ítems FABRICADO
            -- o de servicios NO generan movimiento de kardex de ítem (su
            -- costo de insumos se resuelve al venderse, vía el kardex real).
            ---------------------------------------------------
            DECLARE @cd_id_item INT, @cd_id_insumo INT, @cd_cantidad DECIMAL(18,4), @cd_precio_unitario DECIMAL(18,2), @cd_id_orden INT, @cd_costo_resultante DECIMAL(18,4);
            DECLARE cur_entrada_kardex CURSOR LOCAL FAST_FORWARD FOR
                SELECT ndc.id_item, NULL, ndc.cantidad, ndc.precio_unitario, ndc.id_orden_compra
                FROM @nuevo_detalle_compra ndc
                INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = ndc.id_item
                WHERE ps.modo_obtencion = 'COMPRADO_REVENTA'
                UNION ALL
                SELECT NULL, ndc.id_insumo, ndc.cantidad, ndc.precio_unitario, ndc.id_orden_compra
                FROM @nuevo_detalle_compra ndc
                WHERE ndc.id_insumo IS NOT NULL;
            OPEN cur_entrada_kardex;
            FETCH NEXT FROM cur_entrada_kardex INTO @cd_id_item, @cd_id_insumo, @cd_cantidad, @cd_precio_unitario, @cd_id_orden;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC dbo.sp_registrar_movimiento_inventario
                    @id_item = @cd_id_item,
                    @id_insumo = @cd_id_insumo,
                    @tipo_movimiento = 'ENTRADA',
                    @cantidad = @cd_cantidad,
                    @costo_unitario_entrada = @cd_precio_unitario,
                    @origen_documento = 'COMPRA',
                    @id_referencia = @cd_id_orden,
                    @costo_unitario_resultante = @cd_costo_resultante OUTPUT;

                FETCH NEXT FROM cur_entrada_kardex INTO @cd_id_item, @cd_id_insumo, @cd_cantidad, @cd_precio_unitario, @cd_id_orden;
            END
            CLOSE cur_entrada_kardex;
            DEALLOCATE cur_entrada_kardex;

            ---------------------------------------------------
            -- 4.2b (v3) ASIENTO AUTOMÁTICO POR CADA COMPRA NUEVA
            --   Debe: Costo/Gasto (por cada cuenta distinta entre los
            --         ítems del detalle) + IVA Crédito Fiscal (1151)
            --   Haber: Proveedores (2111) por monto_total
            ---------------------------------------------------
            DECLARE @id_compra_actual INT, @folio_oc_actual VARCHAR(50);
            DECLARE cur_compras CURSOR LOCAL FAST_FORWARD FOR
                SELECT id_orden_compra, folio_oc FROM @nuevas_compras;
            OPEN cur_compras;
            FETCH NEXT FROM cur_compras INTO @id_compra_actual, @folio_oc_actual;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @lineas_compra dbo.tipo_asiento_detalle;
                DECLARE @c_monto_total DECIMAL(18,2), @c_monto_iva DECIMAL(18,2), @c_fecha DATE, @c_cc INT;

                SELECT @c_monto_total = monto_total, @c_monto_iva = monto_iva,
                       @c_fecha = fecha_emision, @c_cc = id_centro_costo
                FROM dbo.tbl_ordenes_compra WHERE id_orden_compra = @id_compra_actual;

                -- v4/v7 (Costeo Directo por Flujo de Venta / Kardex Real de
                -- Insumos): los ítems COMPRADO_REVENTA se activan a
                -- Inventario de Mercaderías (1141) y los insumos se activan a
                -- Inventario de Insumos y Materias Primas (1143), en vez de
                -- cargarse directo a Costo/Gasto -- su costo se reconoce
                -- recién al venderse/consumirse, vía el kardex (sección 4.1c).
                INSERT INTO @lineas_compra (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                SELECT d.id_cuenta_costo_resuelta, SUM(d.subtotal), 0.00, @c_cc, 'Costo/Gasto/Inventario Compra ' + @folio_oc_actual
                FROM (
                    SELECT CASE WHEN cd.id_insumo IS NOT NULL THEN 1143 -- v7: Inventario de Insumos y Materias Primas
                                WHEN ps.modo_obtencion = 'COMPRADO_REVENTA' THEN 1141
                                ELSE ISNULL(ps.id_cuenta_costo_gasto, 6215) END AS id_cuenta_costo_resuelta,
                           cd.subtotal_neto AS subtotal
                    FROM dbo.tbl_compras_detalle cd
                    LEFT JOIN dbo.tbl_productos_servicios ps ON ps.id_item = cd.id_item
                    WHERE cd.id_orden_compra = @id_compra_actual
                ) d
                GROUP BY d.id_cuenta_costo_resuelta;

                IF @c_monto_iva > 0
                    INSERT INTO @lineas_compra (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (1151, @c_monto_iva, 0.00, NULL, 'IVA Crédito Fiscal Compra ' + @folio_oc_actual);

                INSERT INTO @lineas_compra (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (2111, 0.00, @c_monto_total, NULL, 'Cuenta por pagar Compra ' + @folio_oc_actual);

                EXEC dbo.sp_registrar_asiento_contable
                    @id_transaccion = NULL,
                    @fecha_asiento = @c_fecha,
                    @glosa_general = 'Devengamiento automático Compra ' + @folio_oc_actual + ' (ETL Fase 3)',
                    @periodo_contable = CONVERT(VARCHAR(7), @c_fecha, 23),
                    @lineas = @lineas_compra,
                    @id_asiento_out = @id_asiento_generado OUTPUT;

                FETCH NEXT FROM cur_compras INTO @id_compra_actual, @folio_oc_actual;
            END
            CLOSE cur_compras;
            DEALLOCATE cur_compras;

            ---------------------------------------------------
            -- 4.3 MOVIMIENTOS_CAJA: inserción directa (sin cabecera)
            ---------------------------------------------------
            DECLARE @nuevos_movimientos TABLE (id_movimiento INT);

            INSERT INTO dbo.tbl_movimientos_caja
                (id_movimiento, fecha_movimiento, id_cuenta_bancaria, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero, id_centro_costo, id_empleado)
            OUTPUT inserted.id_movimiento INTO @nuevos_movimientos
            SELECT
                (SELECT ISNULL(MAX(id_movimiento), 0) FROM dbo.tbl_movimientos_caja)
                    + ROW_NUMBER() OVER (ORDER BY t.id_staging),
                TRY_CONVERT(DATE, t.fecha_raw, 23),
                cp.id_cuenta,
                t.tipo_flujo_raw,
                TRY_CAST(t.monto_absoluto_raw AS DECIMAL(18,2)),
                t.glosa,
                mc.id_tercero_oficial,
                cc.id_centro_costo,
                emp.id_empleado
            FROM dbo.tbl_staging_carga t
            INNER JOIN dbo.cat_plan_cuentas cp ON t.cuenta_bancaria_raw = cp.codigo_cuenta
            LEFT JOIN dbo.map_clientes mc ON t.tercero_informal_raw = mc.nombre_informal_excel
            LEFT JOIN dbo.tbl_centros_costo cc ON t.centro_costo_raw = cc.codigo_cc
            LEFT JOIN dbo.tbl_empleados_usuarios emp ON t.empleado_raw = emp.rut_dni
            WHERE t.nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR t.pestana_origen = @pestana_origen)
              AND t.estado_carga = 'PENDIENTE'
              AND t.pestana_origen = 'Movimientos_Caja';

            ---------------------------------------------------
            -- 4.3b (v3) ASIENTO AUTOMÁTICO POR CADA MOVIMIENTO DE CAJA NUEVO
            --   INGRESO: Debe Caja/Banco; Haber Clientes (si hay tercero) u
            --            Otros Ingresos Operacionales (si no)
            --   EGRESO:  Debe Proveedores (si hay tercero) o Gastos
            --            Operacionales Generales (si no); Haber Caja/Banco
            --   TRASPASO_HASTA / TRASPASO_DESDE: NO se automatiza en v3 -- un
            --   traspaso real involucra dos cuentas de tesorería en dos filas
            --   distintas del Excel y requiere conciliarlas antes de armar un
            --   asiento de 2 líneas correcto. Se deja como asiento manual
            --   (ver docs/fase3_manual_operacion_fase3.md, limitación conocida).
            ---------------------------------------------------
            DECLARE @id_mov_actual INT;
            DECLARE cur_movs CURSOR LOCAL FAST_FORWARD FOR
                SELECT id_movimiento FROM @nuevos_movimientos;
            OPEN cur_movs;
            FETCH NEXT FROM cur_movs INTO @id_mov_actual;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @lineas_mov dbo.tipo_asiento_detalle;
                DECLARE @m_monto DECIMAL(18,2), @m_fecha DATE, @m_cc INT, @m_cuenta INT, @m_tipo_flujo VARCHAR(30), @m_tercero INT, @m_glosa VARCHAR(250);

                SELECT @m_monto = monto_absoluto, @m_fecha = fecha_movimiento, @m_cc = id_centro_costo,
                       @m_cuenta = id_cuenta_bancaria, @m_tipo_flujo = tipo_flujo, @m_tercero = id_tercero, @m_glosa = glosa_movimiento
                FROM dbo.tbl_movimientos_caja WHERE id_movimiento = @id_mov_actual;

                IF @m_tipo_flujo = 'INGRESO'
                BEGIN
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle) VALUES (@m_cuenta, @m_monto, 0.00, @m_cc, @m_glosa);
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (CASE WHEN @m_tercero IS NOT NULL THEN 1121 ELSE 4113 END, 0.00, @m_monto, @m_cc, @m_glosa);

                    EXEC dbo.sp_registrar_asiento_contable
                        @id_transaccion = NULL, @fecha_asiento = @m_fecha,
                        @glosa_general = 'Ingreso de caja automático (ETL Fase 3): ' + @m_glosa,
                        @periodo_contable = CONVERT(VARCHAR(7), @m_fecha, 23),
                        @lineas = @lineas_mov, @id_asiento_out = @id_asiento_generado OUTPUT;
                END
                ELSE IF @m_tipo_flujo = 'EGRESO'
                BEGIN
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (CASE WHEN @m_tercero IS NOT NULL THEN 2111 ELSE 6215 END, @m_monto, 0.00, @m_cc, @m_glosa);
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle) VALUES (@m_cuenta, 0.00, @m_monto, @m_cc, @m_glosa);

                    EXEC dbo.sp_registrar_asiento_contable
                        @id_transaccion = NULL, @fecha_asiento = @m_fecha,
                        @glosa_general = 'Egreso de caja automático (ETL Fase 3): ' + @m_glosa,
                        @periodo_contable = CONVERT(VARCHAR(7), @m_fecha, 23),
                        @lineas = @lineas_mov, @id_asiento_out = @id_asiento_generado OUTPUT;
                END
                -- TRASPASO_HASTA / TRASPASO_DESDE: se emparejan aparte, ver 4.3c (v11).

                FETCH NEXT FROM cur_movs INTO @id_mov_actual;
            END
            CLOSE cur_movs;
            DEALLOCATE cur_movs;

            ---------------------------------------------------
            -- 4.3c (v11) ASIENTO AUTOMÁTICO PARA TRASPASOS DE CAJA
            --   Empareja cada fila TRASPASO_DESDE (origen, dentro de este
            --   mismo lote recién cargado) con su fila TRASPASO_HASTA
            --   (destino) por (fecha_movimiento, monto_absoluto,
            --   glosa_movimiento) -- REGLA DE NEGOCIO EXPLÍCITA: ambas
            --   filas de un mismo traspaso en el Excel deben compartir la
            --   MISMA glosa (convención operativa, documentada en
            --   docs/fase3_manual_operacion_fase3.md). Solo se empareja
            --   cuando la combinación (fecha, monto, glosa) tiene
            --   EXACTAMENTE una fila TRASPASO_DESDE y EXACTAMENTE una fila
            --   TRASPASO_HASTA en el lote (ambigüedad = 0 o 2+ candidatos
            --   de cualquiera de los dos lados) -- en ese caso el par
            --   queda SIN asiento automático, igual que antes de v11.
            ---------------------------------------------------
            DECLARE @traspasos_pareados TABLE (id_desde INT, id_hasta INT);

            ;WITH desde AS (
                SELECT mc.id_movimiento, mc.fecha_movimiento, mc.monto_absoluto, mc.glosa_movimiento,
                       COUNT(*) OVER (PARTITION BY mc.fecha_movimiento, mc.monto_absoluto, mc.glosa_movimiento) AS n
                FROM dbo.tbl_movimientos_caja mc
                INNER JOIN @nuevos_movimientos nm ON nm.id_movimiento = mc.id_movimiento
                WHERE mc.tipo_flujo = 'TRASPASO_DESDE'
            ),
            hasta AS (
                SELECT mc.id_movimiento, mc.fecha_movimiento, mc.monto_absoluto, mc.glosa_movimiento,
                       COUNT(*) OVER (PARTITION BY mc.fecha_movimiento, mc.monto_absoluto, mc.glosa_movimiento) AS n
                FROM dbo.tbl_movimientos_caja mc
                INNER JOIN @nuevos_movimientos nm ON nm.id_movimiento = mc.id_movimiento
                WHERE mc.tipo_flujo = 'TRASPASO_HASTA'
            )
            INSERT INTO @traspasos_pareados (id_desde, id_hasta)
            SELECT d.id_movimiento, h.id_movimiento
            FROM desde d
            INNER JOIN hasta h
                ON h.fecha_movimiento = d.fecha_movimiento
               AND h.monto_absoluto = d.monto_absoluto
               AND h.glosa_movimiento = d.glosa_movimiento
            WHERE d.n = 1 AND h.n = 1;

            DECLARE @td_id INT, @th_id INT;
            DECLARE cur_traspasos CURSOR LOCAL FAST_FORWARD FOR
                SELECT id_desde, id_hasta FROM @traspasos_pareados;
            OPEN cur_traspasos;
            FETCH NEXT FROM cur_traspasos INTO @td_id, @th_id;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @t_monto DECIMAL(18,2), @t_fecha DATE, @t_glosa VARCHAR(250);
                DECLARE @t_cuenta_desde INT, @t_cc_desde INT, @t_cuenta_hasta INT, @t_cc_hasta INT;

                SELECT @t_monto = monto_absoluto, @t_fecha = fecha_movimiento, @t_glosa = glosa_movimiento,
                       @t_cuenta_desde = id_cuenta_bancaria, @t_cc_desde = id_centro_costo
                FROM dbo.tbl_movimientos_caja WHERE id_movimiento = @td_id;

                SELECT @t_cuenta_hasta = id_cuenta_bancaria, @t_cc_hasta = id_centro_costo
                FROM dbo.tbl_movimientos_caja WHERE id_movimiento = @th_id;

                DECLARE @lineas_traspaso dbo.tipo_asiento_detalle;

                INSERT INTO @lineas_traspaso (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (@t_cuenta_hasta, @t_monto, 0.00, @t_cc_hasta, @t_glosa);

                INSERT INTO @lineas_traspaso (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (@t_cuenta_desde, 0.00, @t_monto, @t_cc_desde, @t_glosa);

                EXEC dbo.sp_registrar_asiento_contable
                    @id_transaccion = NULL, @fecha_asiento = @t_fecha,
                    @glosa_general = 'Traspaso de caja automático (ETL Fase 3): ' + @t_glosa,
                    @periodo_contable = CONVERT(VARCHAR(7), @t_fecha, 23),
                    @lineas = @lineas_traspaso, @id_asiento_out = @id_asiento_generado OUTPUT;

                FETCH NEXT FROM cur_traspasos INTO @td_id, @th_id;
            END
            CLOSE cur_traspasos;
            DEALLOCATE cur_traspasos;

            IF EXISTS (
                SELECT 1 FROM dbo.tbl_movimientos_caja mc
                INNER JOIN @nuevos_movimientos nm ON nm.id_movimiento = mc.id_movimiento
                WHERE mc.tipo_flujo IN ('TRASPASO_DESDE', 'TRASPASO_HASTA')
                  AND mc.id_movimiento NOT IN (
                      SELECT id_desde FROM @traspasos_pareados
                      UNION
                      SELECT id_hasta FROM @traspasos_pareados
                  )
            )
                PRINT 'sp_procesar_etl_fase3: uno o más TRASPASO_DESDE/TRASPASO_HASTA de este lote no pudieron emparejarse automáticamente (0 o 2+ candidatos con la misma fecha/monto/glosa) -- requieren asiento manual vía sp_registrar_asiento_contable.';

            ---------------------------------------------------
            -- 4.4 Marcar como CARGADAS todas las filas que acaban de integrarse
            ---------------------------------------------------
            UPDATE dbo.tbl_staging_carga
            SET estado_carga = 'CARGADO', fecha_proceso = GETDATE()
            WHERE nombre_archivo = @nombre_archivo
              AND (@pestana_origen IS NULL OR pestana_origen = @pestana_origen)
              AND estado_carga = 'PENDIENTE';

        COMMIT TRANSACTION;

        PRINT 'Proceso de validación, auditoría y carga al Core completado con éxito.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en sp_procesar_etl_fase3: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO
