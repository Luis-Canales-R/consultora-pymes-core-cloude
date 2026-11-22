-- ============================================================================
-- Migración: agrega tbl_productos_servicios.id_cuenta_clearing_compra
-- ============================================================================
-- CORRECCIÓN DE DISEÑO (Fase 6, 2026-11-22): el plan original (Hallazgo #21)
-- proponía reconfigurar id_cuenta_costo_gasto de un ítem de honorarios para
-- que apuntara directo a la cuenta de pasivo (2125), de modo que comprar ese
-- ítem cancelara el pasivo en vez de duplicar el gasto.
--
-- Esa idea resultó estar MAL, porque id_cuenta_costo_gasto NO es un campo de
-- uso exclusivo de sp_procesar_compra_externa: sp_procesar_venta_externa
-- (rama SERVICIO, v6) también lo lee -- como @id_cuenta_costo_gasto_raw, con
-- fallback a 5113 -- para decidir a qué cuenta debitar el "Costo Directo
-- Servicio (Honorarios+Insumos real)" generado por la VENTA (sql/sp_procesar_
-- transaccion_externa.sql, líneas ~334). Si ese mismo campo apunta a 2125,
-- la venta termina debitando Y acreditando la cuenta 2125 por el mismo monto
-- (honorarios_linea), anulando entre sí: el "costo estándar aplicado" nunca
-- llega a reflejarse como saldo pendiente, y solo queda el efecto de la
-- compra -- exactamente el síntoma que se detectó al validar (saldo
-- pendiente = -$140.000 en vez de +$10.000, con una venta de $150.000 que no
-- dejó ningún rastro en la cuenta 2125).
--
-- SOLUCIÓN: un campo nuevo, de uso exclusivo de sp_procesar_compra_externa,
-- que NO toca nada de lo que ya lee sp_procesar_venta_externa. Si está
-- informado, la compra debita esa cuenta en vez de id_cuenta_costo_gasto
-- (que sigue sirviendo, sin cambios, como fallback de costo/gasto normal
-- tanto para la venta como para cualquier otra compra). Se deja con nombre
-- genérico (no "...honorarios") porque el mismo mecanismo podría reutilizarse
-- a futuro para Mano de Obra propia (cuenta 2131), si se construye un módulo
-- de nómina -- ver Backlog Tarea #49.
-- ============================================================================

USE consultora_pymes_core;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.tbl_productos_servicios')
      AND name = 'id_cuenta_clearing_compra'
)
BEGIN
    ALTER TABLE tbl_productos_servicios
        ADD id_cuenta_clearing_compra INT NULL;

    ALTER TABLE tbl_productos_servicios
        ADD CONSTRAINT fk_item_cuenta_clearing_compra
        FOREIGN KEY (id_cuenta_clearing_compra) REFERENCES cat_plan_cuentas(id_cuenta);

    PRINT 'Columna id_cuenta_clearing_compra agregada a tbl_productos_servicios.';
END
ELSE
BEGIN
    PRINT 'La columna id_cuenta_clearing_compra ya existía -- no se hizo nada (migración idempotente).';
END
GO
