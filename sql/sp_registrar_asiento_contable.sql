-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql debe estar
-- ejecutado (define dbo.tipo_asiento_detalle y la versión original de este
-- SP). Este archivo es un ALTER seguro: NO borra tablas ni datos, solo
-- reemplaza la definición del stored procedure.

USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_registrar_asiento_contable
--
-- CAMBIO (Un Asiento por Documento): se agrega el parámetro opcional
-- @id_asiento_existente. Los documentos multi-línea (una venta o compra
-- con varios ítems bajo el mismo folio) se registran con UNA llamada por
-- línea a sp_procesar_venta_externa / sp_procesar_compra_externa (cada
-- línea puede tener su propia lógica de costeo: reventa / fabricado /
-- servicio / exento de IVA, etc.). Antes, cada llamada generaba su propio
-- asiento contable completo (una cabecera en tbl_asientos_cabecera por
-- línea), por lo que un documento de 3 ítems quedaba con 3 asientos
-- distintos en vez de uno solo -- correcto en los montos, pero no es como
-- lo hacen los ERP reales (un documento = un asiento, con varias líneas).
--
-- Con @id_asiento_existente:
--   - Si viene NULL (comportamiento anterior, sin cambios): crea una
--     cabecera nueva en tbl_asientos_cabecera y le agrega sus líneas.
--   - Si viene con un id_asiento ya existente: NO crea una cabecera
--     nueva: solo agrega las líneas de este llamado a la cabecera ya
--     existente (tbl_asientos_detalle). El caller (sp_procesar_venta_
--     externa / sp_procesar_compra_externa) sigue devolviendo el mismo
--     id_asiento en @id_asiento_out para que la capa web lo reutilice en
--     la siguiente línea del mismo documento.
--
-- La validación de partida doble (Debe total = Haber total, mínimo 2
-- líneas) se sigue aplicando a las líneas de ESTE llamado únicamente --
-- cada línea de un documento ya arma su propio grupo balanceado (ver
-- sp_procesar_venta_externa / sp_procesar_compra_externa), así que la
-- suma de varios llamados balanceados bajo el mismo id_asiento sigue
-- estando balanceada en total.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_registrar_asiento_contable
    @id_transaccion       INT = NULL,       -- FK opcional a tbl_transacciones_cabecera, si aplica
    @fecha_asiento        DATE,
    @glosa_general        VARCHAR(250),
    @periodo_contable     VARCHAR(7),       -- formato 'YYYY-MM'
    @lineas               dbo.tipo_asiento_detalle READONLY,
    @id_asiento_existente INT = NULL,       -- NUEVO: si se informa, agrega líneas a este asiento en vez de crear uno nuevo
    @id_asiento_out       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- Regla de oro de partida doble: Debe TOTAL = Haber TOTAL (de las líneas de este llamado).
        DECLARE @total_debe DECIMAL(18,2) = (SELECT ISNULL(SUM(debe), 0.00) FROM @lineas);
        DECLARE @total_haber DECIMAL(18,2) = (SELECT ISNULL(SUM(haber), 0.00) FROM @lineas);
        DECLARE @num_lineas INT = (SELECT COUNT(*) FROM @lineas);

        IF @num_lineas < 2
        BEGIN
            RAISERROR('sp_registrar_asiento_contable: un asiento requiere al menos 2 líneas (partida doble).', 16, 1);
            RETURN;
        END

        IF @total_debe <> @total_haber
        BEGIN
            RAISERROR('sp_registrar_asiento_contable: asiento descuadrado. Total Debe y Total Haber deben ser iguales.', 16, 1);
            RETURN;
        END

        BEGIN TRANSACTION;

            DECLARE @nuevo_id_asiento INT;

            IF @id_asiento_existente IS NOT NULL
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM tbl_asientos_cabecera WHERE id_asiento = @id_asiento_existente)
                BEGIN
                    RAISERROR('sp_registrar_asiento_contable: el id_asiento_existente %d no existe en tbl_asientos_cabecera.', 16, 1, @id_asiento_existente);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END

                SET @nuevo_id_asiento = @id_asiento_existente;
                -- No se crea cabecera nueva: solo se agregan líneas (más abajo) a la ya existente.
            END
            ELSE
            BEGIN
                SET @nuevo_id_asiento = ISNULL((SELECT MAX(id_asiento) FROM tbl_asientos_cabecera), 0) + 1;
                DECLARE @nuevo_numero_asiento INT = ISNULL((SELECT MAX(numero_asiento) FROM tbl_asientos_cabecera), 100) + 1;

                INSERT INTO tbl_asientos_cabecera (id_asiento, id_transaccion, numero_asiento, fecha_asiento, glosa_general, periodo_contable)
                VALUES (@nuevo_id_asiento, @id_transaccion, @nuevo_numero_asiento, @fecha_asiento, @glosa_general, @periodo_contable);
            END

            DECLARE @base_id_detalle INT = ISNULL((SELECT MAX(id_asiento_detalle) FROM tbl_asientos_detalle), 0);

            INSERT INTO tbl_asientos_detalle (id_asiento_detalle, id_asiento, id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
            SELECT
                @base_id_detalle + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)),
                @nuevo_id_asiento,
                id_cuenta,
                debe,
                haber,
                id_centro_costo,
                glosa_detalle
            FROM @lineas;

            SET @id_asiento_out = @nuevo_id_asiento;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
