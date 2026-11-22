-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql (dbo.tipo_asiento_detalle,
-- sp_registrar_asiento_contable) y sql/crear_modulo_inventario_costeo.sql
-- (sp_registrar_movimiento_inventario) deben estar ejecutados.

USE consultora_pymes_core;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- ======================================================================
-- STORED PROCEDURE: sp_procesar_compra_externa
-- PROPÓSITO: Contraparte de sp_procesar_venta_externa para el flujo de
--            Compras y Gastos de la plataforma web. Recibe una compra
--            puntual (proveedor + ítem del catálogo, homologados igual
--            que en Ventas vía map_clientes / map_productos), inserta la
--            orden de compra (cabecera + detalle) y genera su asiento de
--            partida doble automático.
--
-- NOTA: Solo compra ítems de tbl_productos_servicios (vía map_productos),
--       igual que hace hoy el formulario de Ventas. No cubre compra de
--       insumos/materia prima (cat_insumos_recursos / map_insumos) -- eso
--       queda fuera de alcance de esta primera versión del módulo web.
--
-- NOTA: Reutiliza map_clientes como tabla de homologación "nombre informal
--       -> id_tercero oficial" también para proveedores (mismo mecanismo
--       de "mapeo identidad" ya usado por la plataforma al crear un
--       tercero), ya que el esquema real no tiene una tabla map_proveedores
--       separada y map_clientes no es más que esa homologación genérica.
--
-- LÓGICA CONTABLE (partida doble):
--   Si el ítem comprado es modo_obtencion = 'COMPRADO_REVENTA':
--     Debe Inventario / Mercaderías en Bodega (1141) por el monto neto,
--     y además se registra la ENTRADA correspondiente al kardex real
--     (sp_registrar_movimiento_inventario), estableciendo el costo de
--     compra como costo unitario de entrada (CPP).
--   Si el ítem comprado es FABRICADO / SERVICIO / sin clasificar:
--     Debe Costo/Gasto del ítem (id_cuenta_costo_gasto, fallback 5111)
--     por el monto neto. No hay movimiento de kardex (no es inventariable
--     en esta versión).
--   Si aplica_iva = 1 en el ítem:
--     Debe IVA Crédito Fiscal (1151) por el monto de IVA.
--   Siempre:
--     Haber Proveedores Nacionales Facturados (2111) por el monto total.
-- ======================================================================
CREATE OR ALTER PROCEDURE sp_procesar_compra_externa
    @folio_oc VARCHAR(50),
    @fecha_emision DATE,
    @nombre_informal_proveedor VARCHAR(150),
    @descripcion_libre_item VARCHAR(150),
    @cantidad DECIMAL(18,4),
    @precio_unitario DECIMAL(18,2),
    @estado_oc VARCHAR(30),
    @id_centro_costo INT = NULL,
    @id_empleado INT = NULL,
    -- CAMBIO (Un Asiento por Documento): mismo mecanismo que
    -- sp_procesar_venta_externa -- ver comentario allá.
    @id_asiento_existente INT = NULL,
    @id_asiento_out INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id_tercero_oficial INT;
    DECLARE @id_item_oficial INT;
    DECLARE @aplica_iva BIT;
    DECLARE @id_cuenta_costo_gasto INT;
    DECLARE @id_cuenta_clearing_compra INT;  -- Fase 6: ver sql/agregar_cuenta_clearing_compra_productos.sql
    DECLARE @modo_obtencion VARCHAR(20);
    DECLARE @id_orden_compra INT;
    DECLARE @subtotal_neto DECIMAL(18,2);
    DECLARE @monto_iva DECIMAL(18,2);
    DECLARE @monto_total DECIMAL(18,2);
    DECLARE @id_asiento_generado INT;
    DECLARE @glosa_tmp VARCHAR(250);
    DECLARE @periodo_tmp VARCHAR(7);
    DECLARE @costo_unitario_resultante DECIMAL(18,4);

    BEGIN TRY
        -- 1. Validación y Homologación de Proveedor (reusa map_clientes)
        SELECT @id_tercero_oficial = id_tercero_oficial
        FROM map_clientes
        WHERE nombre_informal_excel = @nombre_informal_proveedor;

        IF @id_tercero_oficial IS NULL
        BEGIN
            RAISERROR('El proveedor informal "%s" no se encuentra homologado en map_clientes.', 16, 1, @nombre_informal_proveedor);
            RETURN;
        END

        -- 2. Validación y Homologación de Producto / Servicio comprado
        SELECT @id_item_oficial = p.id_item, @aplica_iva = p.aplica_iva,
               @id_cuenta_costo_gasto = ISNULL(p.id_cuenta_costo_gasto, 5111),
               @id_cuenta_clearing_compra = p.id_cuenta_clearing_compra,
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

            -- v2 (Documentos Multi-Ítem): un folio de compra puede traer
            -- varios ítems distintos (una misma OC/factura de proveedor con
            -- varias líneas). Si el folio YA existe, se AGREGA una línea de
            -- detalle más a esa misma cabecera (acumulando sus montos) en
            -- vez de rechazarlo; si es la primera línea de ese folio, se
            -- crea la cabecera. Mismo mecanismo que sp_procesar_venta_externa.
            IF EXISTS (SELECT 1 FROM tbl_ordenes_compra WHERE folio_oc = @folio_oc)
            BEGIN
                SELECT @id_orden_compra = id_orden_compra
                FROM tbl_ordenes_compra
                WHERE folio_oc = @folio_oc;

                IF (SELECT id_tercero FROM tbl_ordenes_compra WHERE id_orden_compra = @id_orden_compra) <> @id_tercero_oficial
                BEGIN
                    RAISERROR('El folio "%s" ya existe para otro proveedor. No se puede agregar un ítem con un proveedor distinto al mismo folio.', 16, 1, @folio_oc);
                    ROLLBACK TRANSACTION;
                    RETURN;
                END

                UPDATE tbl_ordenes_compra
                SET monto_neto = monto_neto + @subtotal_neto,
                    monto_iva = monto_iva + @monto_iva,
                    monto_total = monto_total + @monto_total
                WHERE id_orden_compra = @id_orden_compra;
            END
            ELSE
            BEGIN
                SELECT @id_orden_compra = ISNULL(MAX(id_orden_compra), 0) + 1 FROM tbl_ordenes_compra;

                INSERT INTO tbl_ordenes_compra
                    (id_orden_compra, folio_oc, id_tercero, fecha_emision, monto_neto, monto_iva, monto_total, estado_oc, id_centro_costo, id_empleado)
                VALUES
                    (@id_orden_compra, @folio_oc, @id_tercero_oficial, @fecha_emision, @subtotal_neto, @monto_iva, @monto_total, @estado_oc, @id_centro_costo, @id_empleado);
            END

            INSERT INTO tbl_compras_detalle
                (id_compra_detalle, id_orden_compra, id_item, cantidad, precio_unitario, subtotal_neto)
            VALUES
                ((SELECT ISNULL(MAX(id_compra_detalle), 0) + 1 FROM tbl_compras_detalle),
                 @id_orden_compra, @id_item_oficial, @cantidad, @precio_unitario, @subtotal_neto);

            DECLARE @lineas_compra_externa dbo.tipo_asiento_detalle;

            IF @modo_obtencion = 'COMPRADO_REVENTA'
            BEGIN
                -- Ingreso real a kardex: establece el costo de compra como
                -- costo unitario de entrada (recalcula el CPP del ítem).
                SET @glosa_tmp = 'Entrada por Compra ' + @folio_oc;
                EXEC dbo.sp_registrar_movimiento_inventario
                    @id_item = @id_item_oficial,
                    @tipo_movimiento = 'ENTRADA',
                    @cantidad = @cantidad,
                    @costo_unitario_entrada = @precio_unitario,
                    @origen_documento = 'COMPRA',
                    @id_referencia = @id_orden_compra,
                    @glosa = @glosa_tmp,
                    @costo_unitario_resultante = @costo_unitario_resultante OUTPUT;

                INSERT INTO @lineas_compra_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (1141, @subtotal_neto, 0.00, @id_centro_costo, 'Ingreso a Inventario Compra ' + @folio_oc);
            END
            ELSE
            BEGIN
                -- Ítem no inventariable (FABRICADO / SERVICIO / sin clasificar):
                -- va directo a Costo/Gasto, sin pasar por el kardex. Si el
                -- ítem tiene configurada una cuenta de "clearing" (Fase 6:
                -- honorarios reales que deben cancelar el pasivo aplicado a
                -- estándar en la venta, en vez de duplicar el gasto), se
                -- debita esa cuenta en su lugar.
                INSERT INTO @lineas_compra_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (ISNULL(@id_cuenta_clearing_compra, @id_cuenta_costo_gasto), @subtotal_neto, 0.00, @id_centro_costo, 'Gasto Compra ' + @folio_oc);
            END

            IF @monto_iva > 0
                INSERT INTO @lineas_compra_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
                VALUES (1151, @monto_iva, 0.00, NULL, 'IVA Crédito Fiscal Compra ' + @folio_oc);

            INSERT INTO @lineas_compra_externa (id_cuenta, debe, haber, id_centro_costo, glosa_detalle)
            VALUES (2111, 0.00, @monto_total, NULL, 'Cuenta por pagar Compra ' + @folio_oc);

            SET @glosa_tmp = 'Registro automático Compra ' + @folio_oc + ' (compra puntual)';
            SET @periodo_tmp = CONVERT(VARCHAR(7), @fecha_emision, 23);
            EXEC dbo.sp_registrar_asiento_contable
                @id_transaccion = NULL,
                @fecha_asiento = @fecha_emision,
                @glosa_general = @glosa_tmp,
                @periodo_contable = @periodo_tmp,
                @lineas = @lineas_compra_externa,
                @id_asiento_existente = @id_asiento_existente,
                @id_asiento_out = @id_asiento_generado OUTPUT;

            SET @id_asiento_out = @id_asiento_generado;

        COMMIT TRANSACTION;
        PRINT 'Transacción procesada e integrada al Core exitosamente. id_orden_compra = ' + CAST(@id_orden_compra AS VARCHAR(20))
            + ', id_asiento = ' + CAST(@id_asiento_generado AS VARCHAR(20));

        -- CAMBIO (Un Asiento por Documento): ver mismo comentario en
        -- sp_procesar_venta_externa -- se expone el id_asiento como
        -- resultset propio para que pyodbc lo lea con un fetchone() simple.
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
