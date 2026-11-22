-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql (dbo.tipo_asiento_detalle,
-- sp_registrar_asiento_contable) y sql/agregar_variacion_costeo_honorarios.sql
-- (cuenta 5115 / 5.1.03.002) deben estar ejecutados.

USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_cerrar_variacion_honorarios
-- PROPÓSITO: Fase 6 del plan -- regularización de costeo estándar vs.
--            real para Honorarios Subcontratados (ítems SERVICIO), al
--            cierre del periodo. Ver sql/agregar_variacion_costeo_
--            honorarios.sql para el detalle completo del problema que
--            resuelve y la convención de catálogo que requiere (comprar
--            los honorarios reales de un contratista con un ítem cuyo
--            id_cuenta_costo_gasto apunte directo a la cuenta 2125, no
--            a 5113).
--
-- LÓGICA: la cuenta 2125 (Honorarios Profesionales por Pagar) es una
-- cuenta "clearing": se acredita cuando se vende un Servicio (al costo
-- estándar de sus horas-hombre) y se debita cuando se compra el
-- honorario real de ese contratista (si el ítem comprado apunta a
-- 2125). Su saldo vivo en cualquier momento es, por definición, la
-- diferencia acumulada entre lo aplicado a estándar y lo pagado real.
--
-- Este SP toma ese saldo vivo (TODO el histórico, no solo el periodo que
-- se está cerrando -- así cualquier variación no cerrada en un periodo
-- anterior se arrastra y se cierra ahora) y lo "barre" a la cuenta
-- 5115 (Variación de Costeo en Honorarios), dejando 2125 en cero:
--   Si el saldo de 2125 es ACREEDOR (> 0, se aplicó más estándar del
--   que se ha pagado real): variación FAVORABLE -- se debita 2125 y se
--   ACREDITA 5115 (reduce el costo total ya reconocido, porque el
--   estándar sobreestimó el gasto real).
--   Si el saldo de 2125 es DEUDOR (< 0, se ha pagado más real del que
--   se aplicó a estándar): variación DESFAVORABLE -- se acredita 2125 y
--   se DEBITA 5115 (reconoce el costo adicional no capturado todavía).
--
-- Es idempotente: si el saldo de 2125 ya es 0.00, no genera ningún
-- asiento (@id_asiento_out queda NULL) -- se puede llamar más de una vez
-- para el mismo periodo sin riesgo de duplicar el cierre.
--
-- NOTA: se usa el saldo histórico completo (no agrupado por
-- periodo_contable) porque la cuenta 2125 es de BALANCE (un pasivo), no
-- de resultado -- su saldo se arrastra entre periodos igual que
-- cualquier otra cuenta de Balance General. Esto también significa que
-- una diferencia de timing (se vendió el Servicio este mes, se pagará
-- el honorario real recién el mes que viene) se corrige sola en el
-- cierre siguiente, sin intervención manual.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_cerrar_variacion_honorarios
    @periodo_contable VARCHAR(7),   -- periodo del CIERRE, ej. '2026-11' (no necesariamente el periodo donde se originó la diferencia)
    @fecha_asiento DATE,            -- normalmente el último día del periodo que se cierra
    @id_asiento_out INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @saldo_2125 DECIMAL(18,2);
    DECLARE @id_asiento_generado INT;
    DECLARE @glosa_tmp VARCHAR(250);
    DECLARE @lineas_variacion dbo.tipo_asiento_detalle;

    BEGIN TRY
        IF @periodo_contable IS NULL OR @periodo_contable NOT LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]'
        BEGIN
            RAISERROR('El periodo_contable debe tener el formato AAAA-MM (ej. 2026-11).', 16, 1);
            RETURN;
        END

        IF @fecha_asiento IS NULL
        BEGIN
            RAISERROR('@fecha_asiento es obligatorio (normalmente el último día del periodo a cerrar).', 16, 1);
            RETURN;
        END

        SELECT @saldo_2125 = ISNULL(SUM(haber), 0) - ISNULL(SUM(debe), 0)
        FROM dbo.tbl_asientos_detalle
        WHERE id_cuenta = 2125;

        IF @saldo_2125 = 0.00
        BEGIN
            -- Nada que regularizar: el saldo ya está en cero (o este
            -- cierre ya se corrió antes para esta diferencia).
            SET @id_asiento_out = NULL;
            PRINT 'Sin diferencia que regularizar: la cuenta 2125 (Honorarios Profesionales por Pagar) ya está en cero.';
            -- Mismo shape de resultset que la rama con diferencia, para
            -- que el llamador (pyodbc, vía cur.fetchone()) no tenga que
            -- distinguir dos formas de respuesta.
            SELECT CAST(NULL AS INT) AS id_asiento, CAST(0.00 AS DECIMAL(18,2)) AS monto_regularizado;
            RETURN;
        END

        BEGIN TRANSACTION;

            IF @saldo_2125 > 0
            BEGIN
                -- Favorable: se aplicó más estándar que lo pagado real.
                SET @glosa_tmp = 'Cierre variación Honorarios (favorable) periodo ' + @periodo_contable;
                INSERT INTO @lineas_variacion (id_cuenta, debe, haber, glosa_detalle)
                VALUES (2125, @saldo_2125, 0.00, @glosa_tmp);
                INSERT INTO @lineas_variacion (id_cuenta, debe, haber, glosa_detalle)
                VALUES (5115, 0.00, @saldo_2125, @glosa_tmp);
            END
            ELSE
            BEGIN
                -- Desfavorable: se ha pagado más real que lo aplicado a estándar.
                SET @glosa_tmp = 'Cierre variación Honorarios (desfavorable) periodo ' + @periodo_contable;
                INSERT INTO @lineas_variacion (id_cuenta, debe, haber, glosa_detalle)
                VALUES (2125, 0.00, ABS(@saldo_2125), @glosa_tmp);
                INSERT INTO @lineas_variacion (id_cuenta, debe, haber, glosa_detalle)
                VALUES (5115, ABS(@saldo_2125), 0.00, @glosa_tmp);
            END

            EXEC dbo.sp_registrar_asiento_contable
                @id_transaccion = NULL,
                @fecha_asiento = @fecha_asiento,
                @glosa_general = @glosa_tmp,
                @periodo_contable = @periodo_contable,
                @lineas = @lineas_variacion,
                @id_asiento_existente = NULL,
                @id_asiento_out = @id_asiento_generado OUTPUT;

            SET @id_asiento_out = @id_asiento_generado;

        COMMIT TRANSACTION;
        PRINT 'Variación de Honorarios cerrada. Monto regularizado = ' + CAST(@saldo_2125 AS VARCHAR(30))
            + ', id_asiento = ' + CAST(@id_asiento_generado AS VARCHAR(20));

        SELECT @id_asiento_generado AS id_asiento, @saldo_2125 AS monto_regularizado;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR(@ErrorMessage, 16, 1);
    END CATCH
END;
GO
