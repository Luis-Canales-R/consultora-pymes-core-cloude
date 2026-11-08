-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Kardex de Inventario (Costeo Directo por Flujo de Venta) -- v4
-- ====================================================================
-- PRERREQUISITO: Ejecutar previamente sql/crear_modulo_productos_
-- servicios.sql (tbl_productos_servicios, cat_insumos_recursos).
--
-- POR QUÉ EXISTE ESTE MÓDULO:
-- Hasta v3, el costo de venta que entraba al asiento automático era un
-- monto "default" aproximado (ver id_cuenta_costo_gasto). Eso contabiliza
-- correctamente en PARTIDA DOBLE, pero no refleja el costo REAL: una
-- empresa puede vender (a) productos comprados para reventa, (b)
-- productos fabricados, (c) servicios, o una combinación de las tres, y
-- cada una exige una forma distinta de calcular el costo:
--   (a) Comprado para reventa -> costo promedio ponderado (CPP) del lote
--       comprado, vía este kardex.
--   (b) Fabricado -> Mano de Obra Directa (BOM, ya existente) + Materia
--       Prima Directa consumida de este mismo kardex (para insumos) +
--       Costos Indirectos de Fabricación prorrateados al cierre (ver
--       sql/crear_modulo_cif.sql).
--   (c) Servicio -> fuera de alcance de este kardex (no hay inventario
--       físico); su costo directo (insumos/honorarios) se trata aparte.
--
-- DISEÑO DEL KARDEX: costeo por Costo Promedio Ponderado (CPP), el
-- método más simple y robusto para una PyME (evita la complejidad de
-- rastrear lotes FIFO/LIFO). Cada fila almacena el saldo acumulado DESPUÉS
-- del movimiento (cantidad, valor y costo promedio resultante), de forma
-- que el costo vigente para la PRÓXIMA salida siempre es auditable fila
-- por fila, sin tener que recalcular el historial completo cada vez.
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.sp_registrar_movimiento_inventario', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_registrar_movimiento_inventario;
GO

DROP TABLE IF EXISTS tbl_movimientos_inventario;
GO

CREATE TABLE tbl_movimientos_inventario (
    id_movimiento_inventario INT PRIMARY KEY,
    fecha_movimiento DATETIME NOT NULL DEFAULT GETDATE(),
    id_item INT NULL,          -- Movimiento de un PRODUCTO (tbl_productos_servicios)
    id_insumo INT NULL,        -- Movimiento de un INSUMO/materia prima (cat_insumos_recursos)
    tipo_movimiento VARCHAR(10) NOT NULL CHECK (tipo_movimiento IN ('ENTRADA', 'SALIDA')),
    cantidad DECIMAL(18,4) NOT NULL CHECK (cantidad > 0),
    costo_unitario_movimiento DECIMAL(18,4) NOT NULL, -- ENTRADA: costo de compra. SALIDA: CPP vigente al momento.
    saldo_cantidad DECIMAL(18,4) NOT NULL,             -- Saldo acumulado DESPUÉS de este movimiento
    saldo_valor DECIMAL(18,2) NOT NULL,                -- Valor acumulado DESPUÉS de este movimiento
    costo_promedio_resultante DECIMAL(18,4) NOT NULL,  -- saldo_valor / saldo_cantidad tras este movimiento
    origen_documento VARCHAR(30) NOT NULL CHECK (origen_documento IN ('COMPRA', 'VENTA', 'CONSUMO_PRODUCCION', 'AJUSTE')),
    id_referencia INT NULL,    -- id_orden_compra / id_venta_devengada / etc. del documento que originó el movimiento
    glosa VARCHAR(250) NULL,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_mov_inv_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item),
    CONSTRAINT fk_mov_inv_insumo FOREIGN KEY (id_insumo) REFERENCES cat_insumos_recursos(id_insumo),
    CONSTRAINT ck_mov_inv_una_entidad CHECK (
        (id_item IS NOT NULL AND id_insumo IS NULL) OR (id_item IS NULL AND id_insumo IS NOT NULL)
    )
);
GO

CREATE INDEX IX_mov_inv_item ON tbl_movimientos_inventario (id_item, fecha_movimiento, id_movimiento_inventario);
CREATE INDEX IX_mov_inv_insumo ON tbl_movimientos_inventario (id_insumo, fecha_movimiento, id_movimiento_inventario);
GO

-- ====================================================================
-- SP REUTILIZABLE: registra un movimiento de kardex y devuelve el costo
-- unitario relevante (costo de compra en ENTRADA; CPP vigente en SALIDA,
-- que es el monto que el llamador debe usar para construir el asiento de
-- Costo de Ventas / Consumo de Materia Prima).
-- ====================================================================
CREATE PROCEDURE dbo.sp_registrar_movimiento_inventario
    @id_item INT = NULL,
    @id_insumo INT = NULL,
    @tipo_movimiento VARCHAR(10),
    @cantidad DECIMAL(18,4),
    @costo_unitario_entrada DECIMAL(18,4) = NULL,  -- obligatorio si @tipo_movimiento = 'ENTRADA'
    @origen_documento VARCHAR(30),
    @id_referencia INT = NULL,
    @glosa VARCHAR(250) = NULL,
    @costo_unitario_resultante DECIMAL(18,4) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF (@id_item IS NULL AND @id_insumo IS NULL) OR (@id_item IS NOT NULL AND @id_insumo IS NOT NULL)
        BEGIN
            RAISERROR('sp_registrar_movimiento_inventario: debe informarse exactamente uno de @id_item o @id_insumo.', 16, 1);
            RETURN;
        END

        IF @cantidad IS NULL OR @cantidad <= 0
        BEGIN
            RAISERROR('sp_registrar_movimiento_inventario: @cantidad debe ser mayor a cero.', 16, 1);
            RETURN;
        END

        DECLARE @saldo_cantidad_actual DECIMAL(18,4), @saldo_valor_actual DECIMAL(18,2);

        SELECT TOP 1 @saldo_cantidad_actual = saldo_cantidad, @saldo_valor_actual = saldo_valor
        FROM dbo.tbl_movimientos_inventario
        WHERE (@id_item IS NOT NULL AND id_item = @id_item) OR (@id_insumo IS NOT NULL AND id_insumo = @id_insumo)
        ORDER BY id_movimiento_inventario DESC;

        SET @saldo_cantidad_actual = ISNULL(@saldo_cantidad_actual, 0);
        SET @saldo_valor_actual = ISNULL(@saldo_valor_actual, 0);

        DECLARE @nuevo_saldo_cantidad DECIMAL(18,4), @nuevo_saldo_valor DECIMAL(18,2), @costo_mov DECIMAL(18,4);

        IF @tipo_movimiento = 'ENTRADA'
        BEGIN
            IF @costo_unitario_entrada IS NULL OR @costo_unitario_entrada < 0
            BEGIN
                RAISERROR('sp_registrar_movimiento_inventario: @costo_unitario_entrada es obligatorio y no puede ser negativo en una ENTRADA.', 16, 1);
                RETURN;
            END

            SET @costo_mov = @costo_unitario_entrada;
            SET @nuevo_saldo_cantidad = @saldo_cantidad_actual + @cantidad;
            SET @nuevo_saldo_valor = @saldo_valor_actual + (@cantidad * @costo_unitario_entrada);
        END
        ELSE IF @tipo_movimiento = 'SALIDA'
        BEGIN
            IF @saldo_cantidad_actual < @cantidad
            BEGIN
                RAISERROR('sp_registrar_movimiento_inventario: stock insuficiente (saldo actual %s, solicitado %s). Revise las ENTRADAs registradas para este ítem/insumo.', 16, 1, CAST(@saldo_cantidad_actual AS VARCHAR(30)), CAST(@cantidad AS VARCHAR(30)));
                RETURN;
            END

            -- Costo Promedio Ponderado vigente ANTES de esta salida
            SET @costo_mov = CASE WHEN @saldo_cantidad_actual = 0 THEN 0 ELSE @saldo_valor_actual / @saldo_cantidad_actual END;
            SET @nuevo_saldo_cantidad = @saldo_cantidad_actual - @cantidad;
            SET @nuevo_saldo_valor = @saldo_valor_actual - (@cantidad * @costo_mov);
        END
        ELSE
        BEGIN
            RAISERROR('sp_registrar_movimiento_inventario: @tipo_movimiento debe ser ENTRADA o SALIDA.', 16, 1);
            RETURN;
        END

        INSERT INTO dbo.tbl_movimientos_inventario
            (id_movimiento_inventario, id_item, id_insumo, tipo_movimiento, cantidad, costo_unitario_movimiento,
             saldo_cantidad, saldo_valor, costo_promedio_resultante, origen_documento, id_referencia, glosa)
        VALUES
            ((SELECT ISNULL(MAX(id_movimiento_inventario), 0) + 1 FROM dbo.tbl_movimientos_inventario),
             @id_item, @id_insumo, @tipo_movimiento, @cantidad, @costo_mov,
             @nuevo_saldo_cantidad, @nuevo_saldo_valor,
             CASE WHEN @nuevo_saldo_cantidad = 0 THEN 0 ELSE @nuevo_saldo_valor / @nuevo_saldo_cantidad END,
             @origen_documento, @id_referencia, @glosa);

        SET @costo_unitario_resultante = @costo_mov;
    END TRY
    BEGIN CATCH
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        RAISERROR('Error en sp_registrar_movimiento_inventario: %s', 16, 1, @ErrorMessage);
    END CATCH
END;
GO

PRINT 'Módulo de Inventario y Costeo (kardex CPP) creado exitosamente.';
GO
