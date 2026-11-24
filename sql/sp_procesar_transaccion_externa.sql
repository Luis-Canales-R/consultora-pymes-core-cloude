-- PRERREQUISITO (v3): sql/crear_modulo_contabilidad_transacciones.sql debe
-- estar ejecutado (define dbo.tipo_asiento_detalle y sp_registrar_asiento_
-- contable, usados por este SP para generar el asiento automático).

USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_procesar_venta_externa
-- PROPÓSITO: Recibe datos de la plantilla de Excel (fila a fila, uso
--            interactivo / puntual), homologa nombres informales mediante
--            las tablas de mapeo de Fase 2 y realiza el insert seguro en
--            el Core RDBMS transaccional (cabecera + detalle de venta).
--
-- NOTA: Para cargas masivas por lote use dbo.sp_procesar_etl_fase3, que
--       trabaja sobre dbo.tbl_staging_carga y audita cada fila en
--       dbo.tbl_log_errores_etl. Este procedimiento es para procesar
--       o corregir una venta puntual sin pasar por staging.
--
-- CAMBIO v3 (Control de Gestión): recibe @id_centro_costo / @id_empleado
-- (opcionales) y, tras insertar la venta, llama a
-- sp_registrar_asiento_contable para generar automáticamente su asiento
-- de partida doble (Debe Clientes; Haber Ingreso + IVA Débito Fiscal),
-- dentro de la misma transacción atómica.
--
-- CAMBIO v4 (Costeo Directo por Flujo de Venta): además del asiento de
-- ingreso, genera el leg de COSTO DIRECTO según el modo_obtencion del
-- ítem vendido:
--   COMPRADO_REVENTA -> sale del kardex (CPP) vía sp_registrar_movimiento_
--     inventario; Debe Costo/Gasto del ítem (fallback 5111) / Haber
--     Inventario (1141).
--   FABRICADO -> MOD (tbl_item_composicion_recursos, costo estándar) + MPD
--     (v7: consumida componente por componente desde el kardex REAL de
--     insumos, igual mecánica que COMPRADO_REVENTA); Debe Costo/Gasto del
--     ítem (fallback 5111) / Haber Remuneraciones por Pagar (2131, MOD
--     interna) + Haber Honorarios Profesionales por Pagar (2125, MOD
--     subcontratada -- v8) y Haber Materia Prima Aplicada a Producción por
--     Regularizar (2123, MPD a costo REAL).
--   SERVICIO (v6) -> Honorarios (tbl_item_composicion_recursos, costo
--     estándar) + Insumos (v7: a costo REAL de kardex, misma mecánica que
--     FABRICADO); Debe Costo/Gasto del ítem (fallback 5113 Honorarios/
--     Servicios Subcontratados) / Haber Honorarios Profesionales por
--     Pagar (2125, componentes subcontratados -- v8) + Haber Remuneraciones
--     por Pagar (2131, componentes de personal interno dentro del mismo
--     ítem -- v8) y Haber Insumos Aplicados a Servicios por Regularizar
--     (2124, a costo REAL). No aplica CIF.
--   NULL (ítem sin clasificar) -> sin leg de costo.
--
-- CAMBIO v7 (Kardex Real de Insumos): la MPD/Insumos de FABRICADO/SERVICIO
-- ya no se calcula a costo estándar de referencia; se consume desde el
-- kardex real de insumos (tbl_movimientos_inventario, rama @id_insumo),
-- por lo que esta venta puntual fallará con "stock insuficiente" si los
-- insumos del BOM no fueron comprados (ingresados a kardex) previamente.
--
-- CAMBIO v8 (BOM generalizado a Bill of Resources, Tarea #50): el BOM de
-- horas-hombre (cat_perfiles_hh / tbl_item_composicion_hh) se generalizó a
-- cat_recursos_costeo_estandar / tbl_item_composicion_recursos (sql/
-- generalizar_bom_recursos_costeo.sql), agregando unidad de medida libre
-- (ya no solo horas) y un ORIGEN por recurso ('INTERNO' / 'SUBCONTRATADO').
-- El costo estándar de FABRICADO y SERVICIO ahora se reparte por origen
-- DENTRO de la misma línea de venta, en vez de asumir que el ítem completo
-- es 100% de un solo origen -- resuelve la limitación documentada en
-- Hallazgo #23 (mezcla de personal interno + subcontratistas en el mismo
-- ítem/SKU, y servicios subcontratados no medidos en horas, ej. m², ml,
-- unidad). El checkbox "Subcontrato" a nivel de ítem queda obsoleto como
-- mecanismo de verdad: la granularidad correcta vive ahora en cada línea
-- del BOM, vía el origen de cada recurso.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_procesar_venta_externa
    @folio_factura VARCHAR(50),
    @fecha_emision DATE,
    @nombre_informal_cliente VARCHAR(150),
    @descripcion_libre_item VARCHAR(150),
    @cantidad DECIMAL(18,4),
    @precio_unitario DECIMAL(18,2),
    @estado_venta VARCHAR(30),
    @id_centro_costo INT = NULL,
    @id_empleado INT = NULL,
    -- CAMBIO (Un Asiento por Documento): si @id_asiento_existente viene
    -- informado, esta línea se agrega al asiento ya creado por una línea
    -- anterior del mismo folio (en vez de crear un asiento nuevo). El
    -- llamador debe guardar el valor devuelto en @id_asiento_out y
    -- reenviarlo como @id_asiento_existente en la siguiente línea del
    -- mismo documento -- así un folio con N ítems queda con UN solo
    -- asiento de N*2 (o más) líneas, en vez de N asientos separados.
    @id_asiento_existente INT = NULL,
    @id_asiento_out INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_tercero_oficial INT;
    DECLARE @id_item_oficial INT;
    DECLARE @aplica_iva BIT;
    DECLARE @id_cuenta_ingreso INT;
    DECLARE @id_venta_devengada INT;
    DECLARE @subtotal_neto DECIMAL(18,2);
    DECLARE @monto_iva DECIMAL(18,2);
    DECLARE @monto_total DECIMAL(18,2);
    DECLARE @id_asiento_generado INT;
    -- v4/v6 (Costeo Directo por Flujo de Venta)
    DECLARE @modo_obtencion VARCHAR(20);
    DECLARE @id_cuenta_costo_gasto INT;
    DECLARE @id_cuenta_costo_gasto_raw INT;  -- sin fallback aplicado (v6: SERVICIO usa fallback propio, 5113)
    DECLARE @costo_unitario_cpp DECIMAL(18,4);
    DECLARE @glosa_tmp VARCHAR(250);  -- buffer para armar glosas concatenadas antes de pasarlas a EXEC
    DECLARE @periodo_tmp VARCHAR(7);  -- buffer para CONVERT(...) antes de pasarlo a EXEC
    -- v8 (BOM generalizado a Bill of Resources, Tarea #50): mod_linea/
    -- honorarios_linea se reemplazan por un par interno/subcontratado cada
    -- uno, para poder repartir el costo del BOM dentro de la MISMA línea
    -- de venta según el origen de cada recurso (cat_recursos_costeo_
    -- estandar.origen), en vez de asumir que todo el ítem es 100% de un
    -- solo origen.
    DECLARE @mod_interno DECIMAL(18,2);
    DECLARE @mod_subcontratado DECIMAL(18,2);
    DECLARE @mpd_linea DECIMAL(18,2);
    DECLARE @honorarios_interno DECIMAL(18,2);
    DECLARE @honorarios_subcontratado DECIMAL(18,2);
    DECLARE @insumos_linea DECIMAL(18,2);
    -- v7 (Kardex Real de Insumos)
    DECLARE @ins_id_insumo INT, @ins_cantidad_total DECIMAL(18,4), @ins_cpp_salida DECIMAL(18,4);

    BEGIN TRY
        -- 1. Validación y Homologación de Cliente
        SELECT @id_tercero_oficial = id_tercero_oficial
        FROM map_clientes
        WHERE nombre_informal_excel = @nombre_informal_cliente;

        IF @id_tercero_oficial IS NULL
        BEGIN
            RAISERROR('El cliente informal "%s" no se encuentra homologado en map_clientes.', 16, 1, @nombre_informal_cliente);
            RETURN;
        END

        -- 2. Validación y Homologación de Producto / Servicio
        SELECT @id_item_oficial = p.id_item, @aplica_iva = p.aplica_iva,
               @id_cuenta_ingreso = ISNULL(p.id_cuenta_ingreso, 4113),
               @id_cuenta_costo_gasto = ISNULL(p.id_cuenta_costo_gasto, 5111),
               @id_cuenta_costo_gasto_raw = p.id_cuenta_costo_gasto,
               @modo_obtencion = p.modo_obtencion
        FROM map_productos mp
        INNER JOIN tbl_productos_servicios p ON mp.id_item_oficial = p.id_item
        WHERE mp.descripcion_libre_excel = @descripcion_libre_item;

        IF @id_item_oficial IS NULL
        BEGIN
            RAISERROR('La descripción de ítem "%s" no se encuentra homologada en map_productos.', 16, 1, @descripcion_libre_item);
            RETURN;
        END

        -- 3. Validaciones de negocio básicas
        IF @cantidad IS NULL OR @cantidad <= 0
        BEGIN
            RAISERROR('La cantidad debe ser numérica y mayor a cero.', 16, 1);
            RETURN;
        END

        IF @precio_unitario IS NULL OR @precio_unitario < 0
        BEGIN
            RAISERROR('El precio unitario debe ser numérico y no puede ser negativo.', 16, 1);
            RETURN;
        END

        -- 3b. (v3) Centro de costo / empleado, si se informan, deben existir
        IF @id_centro_costo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tbl_centros_costo WHERE id_centro_costo = @id_centro_costo)
        BEGIN
            RAISERROR('El id_centro_costo %d no existe en tbl_centros_costo.', 16, 1, @id_centro_costo);
            RETURN;
        END

        IF @id_empleado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM tbl_empleados_usuarios WHERE id_empleado = @id_empleado)
        BEGIN
            RAISERROR('El id_empleado %d no existe en tbl_empleados_usuarios.', 16, 1, @id_empleado);
            RETURN;
        END

        -- 4. Cálculo de montos (neto / IVA / total) según el ítem homologado
        SET @subtotal_neto = @cantidad * @precio_unitario;
        SET @monto_iva = CASE WHEN @aplica_iva = 1 THEN ROUND(@subtotal_neto * 0.19, 2) ELSE 0 END;
        SET @monto_total = @subtotal_neto + @monto_iva;

        -- 5. Inserción Transaccional Segura hacia el Core
        BEGIN TRANSACTION;

            -- v8 (Documentos Multi-Ítem): un folio puede traer varios ítems
            -- distintos (una misma factura con varias líneas). Si el folio
            -- YA existe, se AGREGA una línea de detalle más a esa misma
            -- cabecera (acumulando sus montos) en vez de rechazarlo; si es
            -- la primera línea de ese folio, se crea la cabecera. El asiento
            -- contable de esta línea se registra igual que siempre (una
            -- venta con 3 ítems queda con 3 asientos encadenados al mismo
            -- folio, cada uno auditable por separado).
            IF EXISTS (SELECT 1 FROM tbl_ventas_devengadas WHERE folio_factura = @folio_factura)
            BEGIN
                SELECT @id_venta_devengada = id_venta_devengada
                FROM tbl_ventas_devengadas
                WHERE folio_factura = @folio_factura;

                IF (SELECT id_tercero FROM tbl_ventas_devengadas WHERE id_venta_devengada = @id_venta_devengada) <> @id_tercero_oficial
                BEGIN
                    RAISERROR('El folio "%s" ya existe para otro cliente. No se puede agregar un ítem con un cliente distinto al mismo folio.', 16, 1, @folio_factura);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END

                UPDATE tbl_ventas_devengadas
                SET monto_neto = monto_neto + @subtotal_neto,
                    monto_iva = monto_iva + @monto_iva,
                    monto_total = monto_total + @monto_total
                WHERE id_venta_devengada = @id_venta_devengada;
            END
            ELSE
            BEGIN
                SELECT @id_venta_devengada = ISNULL(MAX(id_venta_devengada), 0) + 1 FROM tbl_ventas_devengadas;

                INSERT INTO tbl_ventas_devengadas
                    (id_venta_devengada, folio_factura, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_venta, id_centro_costo, id_empleado)
                VALUES
                    (@id_venta_devengada, @folio_factura, @id_tercero_oficial, @fecha_emision, @subtotal_neto, @monto_iva, @monto_total, @estado_venta, @id_centro_costo, @id_empleado);
            END

            INSERT INTO tbl_ventas_detalle
                (id_venta_detalle, id_venta_devengada, id_item, cantidad, precio_unitario, subtotal_neto)
            VALUES
                ((SELECT ISNULL(MAX(id_venta_detalle), 0) + 1 FROM tbl_ventas_detalle),
                 @id_venta_devengada, @id_item_oficial, @cantidad, @precio_unitario, @subtotal_neto);

            -- v3 (Control de Gestión): asiento automático de partida doble
            DECLARE @lineas_venta_externa dbo.tipo_asiento_detalle;

            INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
            VALUES (1121, @monto_total, 0.00, NULL, 'Cuenta por cobrar Venta ' + @folio_factura);

            INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
            VALUES (@id_cuenta_ingreso, 0.00, @subtotal_neto, @id_centro_costo, 'Ingreso devengado Venta ' + @folio_factura);

            IF @monto_iva > 0
                INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (2141, 0.00, @monto_iva, NULL, 'IVA Débito Fiscal Venta ' + @folio_factura);

            -- v4 (Costeo Directo por Flujo de Venta): leg de costo directo
            IF @modo_obtencion = 'COMPRADO_REVENTA'
            BEGIN
                SET @glosa_tmp = 'Salida por Venta ' + @folio_factura;
                EXEC dbo.sp_registrar_movimiento_inventario
                    @id_item = @id_item_oficial,
                    @tipo_movimiento = 'SALIDA',
                    @cantidad = @cantidad,
                    @origen_documento = 'VENTA',
                    @id_referencia = @id_venta_devengada,
                    @glosa = @glosa_tmp,
                    @costo_unitario_resultante = @costo_unitario_cpp OUTPUT;

                IF @costo_unitario_cpp > 0
                BEGIN
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (@id_cuenta_costo_gasto, ROUND(@costo_unitario_cpp * @cantidad, 2), 0.00, @id_centro_costo, 'Costo de Venta (CPP) ' + @folio_factura);

                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (1141, 0.00, ROUND(@costo_unitario_cpp * @cantidad, 2), @id_centro_costo, 'Salida Inventario Venta ' + @folio_factura);
                END
            END
            ELSE IF @modo_obtencion = 'FABRICADO'
            BEGIN
                -- v8: MOD a costo estándar de referencia (la mano de obra no
                -- se inventaría), repartido por origen del recurso -- interno
                -- (personal propio, credita 2131 como siempre) vs.
                -- subcontratado (un paso de fabricación tercerizado, credita
                -- 2125, igual mecánica de clearing que Honorarios en SERVICIO).
                SELECT @mod_interno = @cantidad * ISNULL((SELECT SUM(cr.cantidad * rc.costo_unitario_referencia)
                                                           FROM tbl_item_composicion_recursos cr
                                                           INNER JOIN cat_recursos_costeo_estandar rc ON rc.id_recurso = cr.id_recurso
                                                           WHERE cr.id_item = @id_item_oficial AND rc.origen = 'INTERNO'), 0);
                SELECT @mod_subcontratado = @cantidad * ISNULL((SELECT SUM(cr.cantidad * rc.costo_unitario_referencia)
                                                                 FROM tbl_item_composicion_recursos cr
                                                                 INNER JOIN cat_recursos_costeo_estandar rc ON rc.id_recurso = cr.id_recurso
                                                                 WHERE cr.id_item = @id_item_oficial AND rc.origen = 'SUBCONTRATADO'), 0);

                -- v7 (Kardex Real de Insumos): MPD ya NO es costo estándar;
                -- se consume componente por componente del BOM desde el
                -- kardex real (CPP), igual mecánica que COMPRADO_REVENTA.
                SET @mpd_linea = 0;
                DECLARE cur_mpd_fabricado CURSOR LOCAL FAST_FORWARD FOR
                    SELECT ci.id_insumo, @cantidad * ci.cantidad
                    FROM tbl_item_composicion_insumos ci
                    WHERE ci.id_item = @id_item_oficial;
                OPEN cur_mpd_fabricado;
                FETCH NEXT FROM cur_mpd_fabricado INTO @ins_id_insumo, @ins_cantidad_total;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @glosa_tmp = 'Consumo de insumo (BOM) por Venta ' + @folio_factura;
                    EXEC dbo.sp_registrar_movimiento_inventario
                        @id_insumo = @ins_id_insumo,
                        @tipo_movimiento = 'SALIDA',
                        @cantidad = @ins_cantidad_total,
                        @origen_documento = 'VENTA',
                        @id_referencia = @id_venta_devengada,
                        @glosa = @glosa_tmp,
                        @costo_unitario_resultante = @ins_cpp_salida OUTPUT;

                    IF @ins_cpp_salida > 0
                        SET @mpd_linea = @mpd_linea + ROUND(@ins_cpp_salida * @ins_cantidad_total, 2);

                    FETCH NEXT FROM cur_mpd_fabricado INTO @ins_id_insumo, @ins_cantidad_total;
                END
                CLOSE cur_mpd_fabricado;
                DEALLOCATE cur_mpd_fabricado;

                IF (@mod_interno + @mod_subcontratado + @mpd_linea) > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (@id_cuenta_costo_gasto, ROUND(@mod_interno + @mod_subcontratado + @mpd_linea, 2), 0.00, @id_centro_costo, 'Costo Directo Producción (MOD+MPD real) Venta ' + @folio_factura);

                IF @mod_interno > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2131, 0.00, ROUND(@mod_interno, 2), @id_centro_costo, 'Remuneraciones por Pagar (MOD Interna) Venta ' + @folio_factura);

                IF @mod_subcontratado > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2125, 0.00, ROUND(@mod_subcontratado, 2), @id_centro_costo, 'Honorarios Profesionales por Pagar (MOD Subcontratada) Venta ' + @folio_factura);

                IF @mpd_linea > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2123, 0.00, ROUND(@mpd_linea, 2), @id_centro_costo, 'Materia Prima Consumida (Kardex Real) Venta ' + @folio_factura);
            END
            ELSE IF @modo_obtencion = 'SERVICIO'
            BEGIN
                -- v6 (Costeo Directo de Servicios): Honorarios a costo
                -- estándar (BOM), misma mecánica que el MOD de FABRICADO.
                -- v8 (BOM generalizado, Tarea #50): repartido por origen del
                -- recurso -- ya no se asume que el ítem completo es 100%
                -- subcontratado. Esto reemplaza al checkbox "Subcontrato" a
                -- nivel de ítem (Hallazgo #23) como mecanismo de verdad: la
                -- granularidad correcta vive en cada línea del BOM.
                SELECT @honorarios_interno = @cantidad * ISNULL((SELECT SUM(cr.cantidad * rc.costo_unitario_referencia)
                                                                  FROM tbl_item_composicion_recursos cr
                                                                  INNER JOIN cat_recursos_costeo_estandar rc ON rc.id_recurso = cr.id_recurso
                                                                  WHERE cr.id_item = @id_item_oficial AND rc.origen = 'INTERNO'), 0);
                SELECT @honorarios_subcontratado = @cantidad * ISNULL((SELECT SUM(cr.cantidad * rc.costo_unitario_referencia)
                                                                        FROM tbl_item_composicion_recursos cr
                                                                        INNER JOIN cat_recursos_costeo_estandar rc ON rc.id_recurso = cr.id_recurso
                                                                        WHERE cr.id_item = @id_item_oficial AND rc.origen = 'SUBCONTRATADO'), 0);

                -- v7 (Kardex Real de Insumos): Insumos ya NO es costo
                -- estándar; se consume componente por componente del BOM
                -- desde el kardex real (CPP), misma mecánica que FABRICADO.
                SET @insumos_linea = 0;
                DECLARE cur_insumos_servicio CURSOR LOCAL FAST_FORWARD FOR
                    SELECT ci.id_insumo, @cantidad * ci.cantidad
                    FROM tbl_item_composicion_insumos ci
                    WHERE ci.id_item = @id_item_oficial;
                OPEN cur_insumos_servicio;
                FETCH NEXT FROM cur_insumos_servicio INTO @ins_id_insumo, @ins_cantidad_total;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    SET @glosa_tmp = 'Consumo de insumo (BOM) por Venta ' + @folio_factura;
                    EXEC dbo.sp_registrar_movimiento_inventario
                        @id_insumo = @ins_id_insumo,
                        @tipo_movimiento = 'SALIDA',
                        @cantidad = @ins_cantidad_total,
                        @origen_documento = 'VENTA',
                        @id_referencia = @id_venta_devengada,
                        @glosa = @glosa_tmp,
                        @costo_unitario_resultante = @ins_cpp_salida OUTPUT;

                    IF @ins_cpp_salida > 0
                        SET @insumos_linea = @insumos_linea + ROUND(@ins_cpp_salida * @ins_cantidad_total, 2);

                    FETCH NEXT FROM cur_insumos_servicio INTO @ins_id_insumo, @ins_cantidad_total;
                END
                CLOSE cur_insumos_servicio;
                DEALLOCATE cur_insumos_servicio;

                IF (@honorarios_interno + @honorarios_subcontratado + @insumos_linea) > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (ISNULL(@id_cuenta_costo_gasto_raw, 5113), ROUND(@honorarios_interno + @honorarios_subcontratado + @insumos_linea, 2), 0.00, @id_centro_costo, 'Costo Directo Servicio (Honorarios+Insumos real) Venta ' + @folio_factura);

                IF @honorarios_subcontratado > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2125, 0.00, ROUND(@honorarios_subcontratado, 2), @id_centro_costo, 'Honorarios Profesionales por Pagar Venta ' + @folio_factura);

                IF @honorarios_interno > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2131, 0.00, ROUND(@honorarios_interno, 2), @id_centro_costo, 'Remuneraciones por Pagar (Personal Interno en Servicio) Venta ' + @folio_factura);

                IF @insumos_linea > 0
                    INSERT INTO @lineas_venta_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (2124, 0.00, ROUND(@insumos_linea, 2), @id_centro_costo, 'Insumos Consumidos (Kardex Real) Venta ' + @folio_factura);
            END
            -- ELSE: ítem sin clasificar (modo_obtencion NULL) -> sin leg de costo

            SET @glosa_tmp = 'Devengamiento automático Venta ' + @folio_factura + ' (venta puntual)';
            SET @periodo_tmp = CONVERT(VARCHAR(7), @fecha_emision, 23);
            EXEC dbo.sp_registrar_asiento_contable
                @id_transaccion = NULL,
                @fecha_asiento = @fecha_emision,
                @glosa_general = @glosa_tmp,
                @periodo_contable = @periodo_tmp,
                @lineas = @lineas_venta_externa,
                @id_asiento_existente = @id_asiento_existente,
                @id_asiento_out = @id_asiento_generado OUTPUT;

            SET @id_asiento_out = @id_asiento_generado;

        COMMIT TRANSACTION;
        PRINT 'Transacción procesada e integrada al Core exitosamente. id_venta_devengada = ' + CAST(@id_venta_devengada AS VARCHAR(20))
            + ', id_asiento = ' + CAST(@id_asiento_generado AS VARCHAR(20));

        -- CAMBIO (Un Asiento por Documento): además del parámetro OUTPUT
        -- @id_asiento_out, se expone el id_asiento como resultset propio.
        -- Esto es necesario porque pyodbc (driver usado por la plataforma
        -- web) no maneja de forma simple los parámetros OUTPUT de un EXEC
        -- dentro de una sola llamada: el caller simplemente hace
        -- "EXEC sp_procesar_venta_externa ..." y lee este SELECT con
        -- fetchone(), sin necesitar DECLARE/OUTPUT en el lado de Python.
        SELECT @id_asiento_generado AS id_asiento;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrorMessage, 16, 1);
    END CATCH
END;
GO
