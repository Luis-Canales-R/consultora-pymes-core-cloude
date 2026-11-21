-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql y
-- sql/crear_tablas_transaccionales_granular.sql deben estar ejecutados
-- (definen dbo.tipo_asiento_detalle, sp_registrar_asiento_contable y
-- tbl_movimientos_caja). Este archivo es un ALTER seguro: no borra tablas
-- ni datos, solo crea/reemplaza este stored procedure.

USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_procesar_movimiento_caja_externo
-- PROPÓSITO: contraparte de sp_procesar_venta_externa / sp_procesar_
--            compra_externa para el módulo de Tesorería/Caja -- uso
--            interactivo desde la plataforma web (un movimiento puntual
--            a la vez), con generación automática de su asiento contable.
--
-- Replica la lógica ya probada en sp_procesar_etl_fase3 (sección 4.3/4.3b/
-- 4.3c) para los 3 tipos de movimiento, pero resuelta en una sola llamada
-- (sin staging ni emparejamiento por lote):
--   INGRESO:   Debe cuenta de tesorería; Haber Clientes (1121, si hay
--              tercero informado) o Ingreso (4113, si no).
--   EGRESO:    Debe Proveedores (2111, si hay tercero) o Gasto (6215, si
--              no); Haber cuenta de tesorería.
--   TRASPASO:  un solo movimiento con cuenta ORIGEN y cuenta DESTINO
--              informadas en la misma llamada (evita la ambigüedad de
--              "esperar la fila que haga match" del proceso por Excel):
--              se insertan dos filas en tbl_movimientos_caja (TRASPASO_
--              DESDE / TRASPASO_HASTA) y un único asiento de 2 líneas
--              (Debe cuenta destino; Haber cuenta origen).
--
-- La cuenta de tesorería se identifica por su código en el plan de
-- cuentas (ej. '1.1.01.002' = Banco Principal), igual que el resto de
-- las homologaciones de este proyecto.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_procesar_movimiento_caja_externo
    @fecha_movimiento        DATE,
    @tipo_flujo              VARCHAR(30),         -- 'INGRESO' | 'EGRESO' | 'TRASPASO'
    @monto_absoluto          DECIMAL(18,2),
    @glosa_movimiento        VARCHAR(250),
    @codigo_cuenta_origen    VARCHAR(20),         -- cuenta de Caja/Banco afectada (en TRASPASO: cuenta "desde")
    @codigo_cuenta_destino   VARCHAR(20) = NULL,  -- solo TRASPASO: cuenta "hasta"
    @nombre_informal_tercero VARCHAR(150) = NULL, -- opcional: cliente/proveedor asociado al movimiento
    @id_centro_costo         INT = NULL,
    @id_empleado             INT = NULL,
    @id_asiento_out          INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_cuenta_origen INT;
    DECLARE @id_cuenta_destino INT;
    DECLARE @id_tercero_oficial INT;
    DECLARE @id_movimiento_generado INT;
    DECLARE @id_asiento_generado INT;
    DECLARE @lineas_mov dbo.tipo_asiento_detalle;
    DECLARE @glosa_tmp VARCHAR(250);
    DECLARE @periodo_tmp VARCHAR(7);

    BEGIN TRY
        -- 1. Validaciones de negocio básicas
        IF @tipo_flujo NOT IN ('INGRESO', 'EGRESO', 'TRASPASO')
        BEGIN
            RAISERROR('tipo_flujo inválido: debe ser INGRESO, EGRESO o TRASPASO.', 16, 1);
            RETURN;
        END

        IF @monto_absoluto IS NULL OR @monto_absoluto <= 0
        BEGIN
            RAISERROR('El monto debe ser numérico y mayor a cero.', 16, 1);
            RETURN;
        END

        -- 2. Homologación de la cuenta de tesorería (origen, siempre requerida)
        SELECT @id_cuenta_origen = id_cuenta
        FROM cat_plan_cuentas
        WHERE codigo_cuenta = @codigo_cuenta_origen AND es_imputable = 1;

        IF @id_cuenta_origen IS NULL
        BEGIN
            RAISERROR('La cuenta de tesorería "%s" no existe o no es imputable en el plan de cuentas.', 16, 1, @codigo_cuenta_origen);
            RETURN;
        END

        IF @tipo_flujo = 'TRASPASO'
        BEGIN
            IF @codigo_cuenta_destino IS NULL
            BEGIN
                RAISERROR('Un TRASPASO requiere informar la cuenta de destino.', 16, 1);
                RETURN;
            END

            SELECT @id_cuenta_destino = id_cuenta
            FROM cat_plan_cuentas
            WHERE codigo_cuenta = @codigo_cuenta_destino AND es_imputable = 1;

            IF @id_cuenta_destino IS NULL
            BEGIN
                RAISERROR('La cuenta de tesorería destino "%s" no existe o no es imputable en el plan de cuentas.', 16, 1, @codigo_cuenta_destino);
                RETURN;
            END

            IF @id_cuenta_destino = @id_cuenta_origen
            BEGIN
                RAISERROR('La cuenta de origen y destino de un traspaso no pueden ser la misma.', 16, 1);
                RETURN;
            END
        END

        -- 3. Homologación de tercero (opcional -- no todo movimiento de caja tiene uno: aporte de capital, retiro del dueño, etc.)
        IF @nombre_informal_tercero IS NOT NULL
        BEGIN
            SELECT @id_tercero_oficial = id_tercero_oficial
            FROM map_clientes
            WHERE nombre_informal_excel = @nombre_informal_tercero;

            IF @id_tercero_oficial IS NULL
            BEGIN
                RAISERROR('El tercero "%s" no se encuentra homologado en map_clientes.', 16, 1, @nombre_informal_tercero);
                RETURN;
            END
        END

        BEGIN TRANSACTION;

            SET @id_movimiento_generado = ISNULL((SELECT MAX(id_movimiento) FROM tbl_movimientos_caja), 0) + 1;

            IF @tipo_flujo IN ('INGRESO', 'EGRESO')
            BEGIN
                INSERT INTO tbl_movimientos_caja
                    (id_movimiento, fecha_movimiento, id_cuenta_bancaria, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero, id_centro_costo, id_empleado)
                VALUES
                    (@id_movimiento_generado, @fecha_movimiento, @id_cuenta_origen, @tipo_flujo, @monto_absoluto, @glosa_movimiento, @id_tercero_oficial, @id_centro_costo, @id_empleado);

                IF @tipo_flujo = 'INGRESO'
                BEGIN
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (@id_cuenta_origen, @monto_absoluto, 0.00, @id_centro_costo, @glosa_movimiento);
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (CASE WHEN @id_tercero_oficial IS NOT NULL THEN 1121 ELSE 4113 END, 0.00, @monto_absoluto, @id_centro_costo, @glosa_movimiento);

                    SET @glosa_tmp = 'Ingreso de caja: ' + @glosa_movimiento;
                END
                ELSE -- EGRESO
                BEGIN
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (CASE WHEN @id_tercero_oficial IS NOT NULL THEN 2111 ELSE 6215 END, @monto_absoluto, 0.00, @id_centro_costo, @glosa_movimiento);
                    INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                    VALUES (@id_cuenta_origen, 0.00, @monto_absoluto, @id_centro_costo, @glosa_movimiento);

                    SET @glosa_tmp = 'Egreso de caja: ' + @glosa_movimiento;
                END
            END
            ELSE -- TRASPASO: dos filas (DESDE / HASTA) ligadas a UN solo asiento de 2 líneas
            BEGIN
                INSERT INTO tbl_movimientos_caja
                    (id_movimiento, fecha_movimiento, id_cuenta_bancaria, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero, id_centro_costo, id_empleado)
                VALUES
                    (@id_movimiento_generado, @fecha_movimiento, @id_cuenta_origen, 'TRASPASO_DESDE', @monto_absoluto, @glosa_movimiento, @id_tercero_oficial, @id_centro_costo, @id_empleado);

                INSERT INTO tbl_movimientos_caja
                    (id_movimiento, fecha_movimiento, id_cuenta_bancaria, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero, id_centro_costo, id_empleado)
                VALUES
                    (@id_movimiento_generado + 1, @fecha_movimiento, @id_cuenta_destino, 'TRASPASO_HASTA', @monto_absoluto, @glosa_movimiento, @id_tercero_oficial, @id_centro_costo, @id_empleado);

                INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (@id_cuenta_destino, @monto_absoluto, 0.00, @id_centro_costo, @glosa_movimiento);
                INSERT INTO @lineas_mov (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (@id_cuenta_origen, 0.00, @monto_absoluto, @id_centro_costo, @glosa_movimiento);

                SET @glosa_tmp = 'Traspaso de caja: ' + @glosa_movimiento;
            END

            SET @periodo_tmp = CONVERT(VARCHAR(7), @fecha_movimiento, 23);

            EXEC dbo.sp_registrar_asiento_contable
                @id_transaccion = NULL,
                @fecha_asiento = @fecha_movimiento,
                @glosa_general = @glosa_tmp,
                @periodo_contable = @periodo_tmp,
                @lineas = @lineas_mov,
                @id_asiento_out = @id_asiento_generado OUTPUT;

            SET @id_asiento_out = @id_asiento_generado;

        COMMIT TRANSACTION;

        PRINT 'Movimiento de caja procesado exitosamente. id_movimiento = ' + CAST(@id_movimiento_generado AS VARCHAR(20))
            + ', id_asiento = ' + CAST(@id_asiento_generado AS VARCHAR(20));

        -- Igual que en sp_procesar_venta_externa / sp_procesar_compra_externa:
        -- se devuelve como SELECT propio (no solo OUTPUT) porque pyodbc no
        -- maneja bien el parámetro OUTPUT combinado con un SELECT en un
        -- mismo EXEC.
        SELECT @id_movimiento_generado AS id_movimiento, @id_asiento_generado AS id_asiento;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
