-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Fase 6 -- Regularización de costeo estándar vs. real para
--         Honorarios Subcontratados (Servicios), al cierre del periodo.
-- ====================================================================
-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql y
-- sql/agregar_subclasificacion_resultado.sql ya deben estar desplegados.
--
-- PROBLEMA QUE RESUELVE (Hallazgo #21 del plan del proyecto): cuando se
-- vende un ítem SERVICIO, la plataforma aplica sus Honorarios a un costo
-- ESTÁNDAR de referencia (tbl_item_composicion_hh × cat_perfiles_hh.
-- costo_hora_referencia), contabilizando:
--     Debe 5113 (Honorarios/Servicios Subcontratados, por el estándar)
--     Haber 2125 (Honorarios Profesionales por Pagar -- cuenta "clearing")
-- Pero cuando se compra el servicio REAL de ese contratista vía el flujo
-- normal de Compras (sp_procesar_compra_externa), ese procedimiento
-- contabiliza el monto real DIRECTO a la cuenta de costo/gasto del ítem
-- comprado (típicamente la MISMA 5113), sin tocar nunca la cuenta 2125:
--     Debe 5113 (por el monto REAL)
--     Haber 2111 (Proveedores)
-- Resultado: el gasto de honorarios queda contabilizado DOS VECES en
-- 5113 (una al vender, a estándar; otra al comprar, a real), y la cuenta
-- 2125 nunca se liquida -- queda un pasivo "fantasma" que crece para
-- siempre.
--
-- SOLUCIÓN (sin tocar ningún flujo ya validado de Ventas/Compras):
-- en vez de modificar sp_procesar_compra_externa, se aprovecha que esa
-- SP ya contabiliza cualquier compra directo a `id_cuenta_costo_gasto`
-- del ítem comprado, sea cual sea esa cuenta. La convención para que una
-- compra de honorarios REALES "regularice" lo aplicado en 2125, en vez
-- de duplicar el gasto en 5113, es:
--
--   Crear (o editar) en Productos/Servicios un ítem SERVICIO que
--   represente "Honorarios reales de [contratista]" y apuntar su
--   id_cuenta_costo_gasto DIRECTO a la cuenta 2125 (Honorarios
--   Profesionales por Pagar), NO a 5113. Al comprar ese ítem por el
--   flujo normal de Compras, sp_procesar_compra_externa (sin cambios)
--   contabilizará automáticamente:
--     Debe 2125 (reduce el pasivo aplicado)   Haber 2111 (Proveedores)
--   que es exactamente la liquidación correcta contra lo ya aplicado.
--
-- Con esa convención, el saldo vivo de 2125 en cualquier momento es la
-- diferencia neta entre "estándar aplicado" y "real pagado hasta ahora".
-- Al cierre del periodo (mensual, la práctica estándar del mercado para
-- costeo estándar con análisis de variación), sp_cerrar_variacion_
-- honorarios.sql barre ese saldo hacia esta cuenta de Variación, para
-- que 2125 quede en cero y la diferencia quede visible en el Estado de
-- Resultados como su propia línea (favorable o desfavorable), en vez de
-- quedar enterrada en el mismo 5113 que ya mezclaba estándar + real.
--
-- Por qué la cuenta de Variación se codifica bajo 5.1.03 (hermana de
-- 5113): así hereda automáticamente subclasificacion_resultado =
-- 'COSTO_VENTA' por la regla de prefijo ya existente (ver Hallazgo #20
-- y sql/agregar_subclasificacion_resultado.sql), sin backfill especial.
-- ====================================================================

USE consultora_pymes_core;
GO

IF NOT EXISTS (SELECT 1 FROM cat_plan_cuentas WHERE codigo_cuenta = '5.1.03.002')
BEGIN
    INSERT INTO cat_plan_cuentas
        (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable, tipo_cuenta, subclasificacion_resultado)
    VALUES
        (5115, '5.1.03.002', 'Variación de Costeo en Honorarios (Estándar vs. Real)', 4, 510, 'DEUDORA', 1, 'COSTO', 'COSTO_VENTA');
    PRINT 'Cuenta 5.1.03.002 (Variación de Costeo en Honorarios) agregada a cat_plan_cuentas.';
END
ELSE
BEGIN
    PRINT 'La cuenta 5.1.03.002 ya existía -- no se agregó de nuevo.';
END
GO
