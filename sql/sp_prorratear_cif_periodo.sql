-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Absorción de Costos Indirectos de Fabricación (CIF) al cierre
--         de cada periodo contable -- v4 (Costeo Directo por Flujo);
--         v10 (base de prorrateo sobre costo REAL de kardex de MPD)
-- ====================================================================
-- PRERREQUISITOS: Ejecutar previamente, en este orden:
--   1) sql/crear_modulo_contabilidad_transacciones.sql (cuentas CIF 5.2.*,
--      TYPE tipo_asiento_detalle, sp_registrar_asiento_contable)
--   2) sql/crear_modulo_productos_servicios.sql (modo_obtencion, BOM)
--   3) sql/crear_tablas_transaccionales_granular.sql
--   4) sql/crear_modulo_inventario_costeo.sql (kardex de insumos, v7)
--
-- QUÉ HACE:
-- Los costos indirectos de fabricación (arriendo de planta, depreciación,
-- supervisión, servicios básicos) se acumulan DURANTE el periodo en las
-- cuentas 5.2.01.* mediante compras/gastos normales (cada ítem de gasto
-- indirecto apunta su id_cuenta_costo_gasto a una de esas cuentas). Este
-- SP, ejecutado al CIERRE del periodo, reparte ese monto acumulado hacia
-- el costo de cada producto FABRICADO vendido en ese periodo y centro de
-- costo, en proporción a su costo directo (MOD + MPD), y lo contabiliza
-- con la contra-cuenta 5.2.02.001 "CIF Absorbido".
--
-- BASE DE PRORRATEO (v10): Costo Directo Total = MOD a costo ESTÁNDAR
-- (tbl_item_composicion_hh × cat_perfiles_hh -- la mano de obra no pasa
-- por kardex, no hay una fuente "real" distinta) + MPD a costo REAL ya
-- consumido del kardex (desde v7: SUM de las salidas de
-- dbo.tbl_movimientos_inventario para esa venta, en vez del costo
-- estándar de referencia del BOM) -- misma fuente de verdad que usa
-- dw.sp_cargar_dw_fact_margen_venta para costo_directo. Antes de v10, la
-- base usaba MPD a costo estándar también, lo cual introducía una
-- divergencia menor entre la base de absorción de CIF y el costo real ya
-- registrado para la MPD (documentada como limitación en v6).
--
-- SI NO HAY VENTAS DE FABRICADOS EN EL PERIODO/CENTRO DE COSTO: el CIF
-- incurrido queda sin absorber (visible como costo del periodo en
-- vw_estado_resultados, subgrupo 5.2) y el SP lo informa por PRINT; no
-- se inventa una base de prorrateo donde no la hay.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.sp_prorratear_cif_periodo', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_prorratear_cif_periodo;
GO

CREATE PROCEDURE dbo.sp_prorratear_cif_periodo
    @periodo_contable VARCHAR(7),          -- 'YYYY-MM'
    @id_centro_costo INT = NULL            -- NULL = todos los centros con CIF pendiente en el periodo
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @id_cuenta_cif_absorbido INT;
        SELECT @id_cuenta_cif_absorbido = id_cuenta FROM dbo.cat_plan_cuentas WHERE codigo_cuenta = '5.2.02.001';

        IF @id_cuenta_cif_absorbido IS NULL
        BEGIN
            RAISERROR('sp_prorratear_cif_periodo: no se encontró la cuenta 5.2.02.001 (CIF Absorbido). Verifique crear_modulo_contabilidad_transacciones.sql.', 16, 1);
            RETURN;
        END

        -- 1. Centros de costo con CIF neto pendiente de absorber en el periodo
        DECLARE @centros TABLE (id_centro_costo INT, monto_cif_pendiente DECIMAL(18,2));

        INSERT INTO @centros (id_centro_costo, monto_cif_pendiente)
        SELECT d.id_centro_costo, SUM(d.debe - d.haber) AS monto_cif_pendiente
        FROM dbo.tbl_asientos_detalle d
        INNER JOIN dbo.tbl_asientos_cabecera a ON a.id_asiento = d.id_asiento
        INNER JOIN dbo.cat_plan_cuentas cp ON cp.id_cuenta = d.id_cuenta
        WHERE a.periodo_contable = @periodo_contable
          AND cp.codigo_cuenta IN ('5.2.01.001', '5.2.01.002', '5.2.01.003', '5.2.02.001')
          AND d.id_centro_costo IS NOT NULL
          AND (@id_centro_costo IS NULL OR d.id_centro_costo = @id_centro_costo)
        GROUP BY d.id_centro_costo
        HAVING SUM(d.debe - d.haber) > 0.01;

        BEGIN TRANSACTION;

            DECLARE @cc_actual INT, @cif_pendiente DECIMAL(18,2);
            DECLARE cur_cif CURSOR LOCAL FAST_FORWARD FOR SELECT id_centro_costo, monto_cif_pendiente FROM @centros;
            OPEN cur_cif;
            FETCH NEXT FROM cur_cif INTO @cc_actual, @cif_pendiente;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- 2. Base de prorrateo: costo directo estándar (MOD+MPD) de cada
                --    línea de venta de producto FABRICADO en este centro/periodo
                DECLARE @base_total DECIMAL(18,2);

                SELECT @base_total = SUM(base.costo_directo_linea)
                FROM (
                    SELECT
                        -- MOD: costo estándar (BOM) -- no hay kardex de mano de obra
                        vd.cantidad * ISNULL((SELECT SUM(hh.cantidad_horas * ph.costo_hora_referencia)
                                               FROM dbo.tbl_item_composicion_hh hh
                                               INNER JOIN dbo.cat_perfiles_hh ph ON ph.id_perfil_hh = hh.id_perfil_hh
                                               WHERE hh.id_item = vd.id_item), 0)
                        -- MPD (v10): costo REAL ya consumido del kardex de insumos
                        + ISNULL((SELECT SUM(mi.costo_unitario_movimiento * mi.cantidad)
                                  FROM dbo.tbl_movimientos_inventario mi
                                  WHERE mi.origen_documento = 'VENTA'
                                    AND mi.tipo_movimiento = 'SALIDA'
                                    AND mi.id_referencia = vv.id_venta_devengada
                                    AND mi.id_insumo IN (
                                        SELECT ci.id_insumo FROM dbo.tbl_item_composicion_insumos ci WHERE ci.id_item = vd.id_item
                                    )), 0)
                        AS costo_directo_linea
                    FROM dbo.tbl_ventas_detalle vd
                    INNER JOIN dbo.tbl_ventas_devengadas vv ON vv.id_venta_devengada = vd.id_venta_devengada
                    INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                    WHERE ps.modo_obtencion = 'FABRICADO'
                      AND vv.id_centro_costo = @cc_actual
                      AND CONVERT(VARCHAR(7), vv.fecha_emision, 23) = @periodo_contable
                ) base;

                IF @base_total IS NULL OR @base_total <= 0
                BEGIN
                    PRINT 'sp_prorratear_cif_periodo: centro de costo ' + CAST(@cc_actual AS VARCHAR(10))
                        + ' no tiene ventas de productos FABRICADOS en ' + @periodo_contable
                        + '. CIF pendiente de $' + CAST(@cif_pendiente AS VARCHAR(20)) + ' queda SIN ABSORBER (costo del periodo).';
                END
                ELSE
                BEGIN
                    DECLARE @tasa_cif DECIMAL(18,8) = @cif_pendiente / @base_total;

                    DECLARE @vd_id INT, @item_id INT, @folio VARCHAR(50), @fecha DATE, @costo_directo_linea DECIMAL(18,2);
                    DECLARE cur_lineas CURSOR LOCAL FAST_FORWARD FOR
                        SELECT vd.id_venta_detalle, vd.id_item, vv.folio_factura, vv.fecha_emision,
                               -- MOD: costo estándar (BOM); MPD (v10): costo REAL de kardex -- ver nota arriba
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
                               AS costo_directo_linea
                        FROM dbo.tbl_ventas_detalle vd
                        INNER JOIN dbo.tbl_ventas_devengadas vv ON vv.id_venta_devengada = vd.id_venta_devengada
                        INNER JOIN dbo.tbl_productos_servicios ps ON ps.id_item = vd.id_item
                        WHERE ps.modo_obtencion = 'FABRICADO'
                          AND vv.id_centro_costo = @cc_actual
                          AND CONVERT(VARCHAR(7), vv.fecha_emision, 23) = @periodo_contable;

                    OPEN cur_lineas;
                    FETCH NEXT FROM cur_lineas INTO @vd_id, @item_id, @folio, @fecha, @costo_directo_linea;
                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        DECLARE @monto_cif_linea DECIMAL(18,2) = ROUND(@costo_directo_linea * @tasa_cif, 2);

                        IF @monto_cif_linea > 0
                        BEGIN
                            DECLARE @id_cuenta_costo_item INT = ISNULL((SELECT id_cuenta_costo_gasto FROM dbo.tbl_productos_servicios WHERE id_item = @item_id), 6215);
                            DECLARE @lineas_cif dbo.tipo_asiento_detalle;
                            DECLARE @id_asiento_cif INT;
                            DECLARE @glosa_cif VARCHAR(250);

                            INSERT INTO @lineas_cif (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                            VALUES (@id_cuenta_costo_item, @monto_cif_linea, 0.00, @cc_actual, 'CIF prorrateado Venta ' + @folio);

                            INSERT INTO @lineas_cif (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                            VALUES (@id_cuenta_cif_absorbido, 0.00, @monto_cif_linea, @cc_actual, 'CIF absorbido Venta ' + @folio);

                            SET @glosa_cif = 'Absorción CIF periodo ' + @periodo_contable + ' - Venta ' + @folio;

                            EXEC dbo.sp_registrar_asiento_contable
                                @id_transaccion = NULL,
                                @fecha_asiento = @fecha,
                                @glosa_general = @glosa_cif,
                                @periodo_contable = @periodo_contable,
                                @lineas = @lineas_cif,
                                @id_asiento_out = @id_asiento_cif OUTPUT;
                        END

                        FETCH NEXT FROM cur_lineas INTO @vd_id, @item_id, @folio, @fecha, @costo_directo_linea;
                    END
                    CLOSE cur_lineas;
                    DEALLOCATE cur_lineas;
                END

                FETCH NEXT FROM cur_cif INTO @cc_actual, @cif_pendiente;
            END
            CLOSE cur_cif;
            DEALLOCATE cur_cif;

        COMMIT TRANSACTION;

        PRINT 'Absorción de CIF para el periodo ' + @periodo_contable + ' completada.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en sp_prorratear_cif_periodo: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO

PRINT 'SP sp_prorratear_cif_periodo creado exitosamente.';
GO
