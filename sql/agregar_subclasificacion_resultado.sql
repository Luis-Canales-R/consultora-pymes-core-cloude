-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Sub-clasificación de cuentas de Resultado (COSTO/GASTO) en
--         cat_plan_cuentas, para habilitar el EBITDA y el Estado de
--         Resultados en formato cascada estándar:
--
--   Ventas Netas
--   (-) Costo de Ventas              = Resultado Bruto
--   (-) GAV (Gastos Admin. y Ventas)  = EBITDA
--   (-) Depreciación y Amortización   = EBIT
--   (+/-) Resultado Financiero        = EBT (Resultado antes de Impuesto)
--   (-) Impuesto a la Renta           = Resultado Neto
--
-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql y
-- sql/crear_vistas_reportes_gestion.sql ya deben estar desplegados.
--
-- DISEÑO: a diferencia de clasificacion_corriente (Hallazgo #7), esta
-- sub-clasificación NO se puede derivar 100% del codigo_cuenta: el
-- grupo 6.4 "GASTOS FINANCIEROS Y OTROS" mezcla a propósito dos
-- naturalezas distintas para el EBITDA (Intereses Bancarios = parte
-- de Resultado Financiero, bajo EBIT; Impuesto a la Renta = la última
-- línea de la cascada, después de EBT) bajo un mismo código de 2do
-- nivel. Por eso esta columna es NULLABLE y se puebla con un backfill
-- explícito (no una columna COMPUTED), y queda documentado que
-- cualquier cuenta NUEVA de tipo COSTO o GASTO debe declarar este
-- valor explícitamente al crearse (no hay un default seguro).
--
-- Valores válidos: 'COSTO_VENTA', 'GAV', 'DEPRECIACION_AMORTIZACION',
-- 'FINANCIERO', 'IMPUESTO'. NULL para cuentas que no son de tipo
-- COSTO/GASTO, y para las cuentas de agrupación (es_imputable = 0).
-- ====================================================================

USE consultora_pymes_core;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.cat_plan_cuentas') AND name = 'subclasificacion_resultado'
)
BEGIN
    ALTER TABLE dbo.cat_plan_cuentas ADD subclasificacion_resultado VARCHAR(30) NULL;
    PRINT 'Columna subclasificacion_resultado agregada a cat_plan_cuentas.';
END
ELSE
BEGIN
    PRINT 'La columna subclasificacion_resultado ya existía -- no se agregó de nuevo.';
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.check_constraints WHERE name = 'ck_subclasificacion_resultado'
)
BEGIN
    ALTER TABLE dbo.cat_plan_cuentas ADD CONSTRAINT ck_subclasificacion_resultado
        CHECK (subclasificacion_resultado IN (
            'COSTO_VENTA', 'GAV', 'DEPRECIACION_AMORTIZACION', 'FINANCIERO', 'IMPUESTO'
        ) OR subclasificacion_resultado IS NULL);
    PRINT 'Constraint ck_subclasificacion_resultado agregada.';
END
GO

-- ====================================================================
-- Backfill de las cuentas del plan de cuentas estándar ya cargado.
-- Se repite sin riesgo si se vuelve a ejecutar (siempre deja el mismo
-- valor final).
-- ====================================================================

-- 5.x -- COSTOS (COGS): todo el grupo es Costo de Venta.
UPDATE dbo.cat_plan_cuentas
SET subclasificacion_resultado = 'COSTO_VENTA'
WHERE tipo_cuenta = 'COSTO' AND es_imputable = 1;

-- 6.1.x y 6.2.x -- Gastos de Personal Administrativo + Gastos Generales
-- y de Operación: ambos son Gastos de Administración y Ventas (GAV).
UPDATE dbo.cat_plan_cuentas
SET subclasificacion_resultado = 'GAV'
WHERE tipo_cuenta = 'GASTO' AND es_imputable = 1
  AND (codigo_cuenta LIKE '6.1.%' OR codigo_cuenta LIKE '6.2.%');

-- 6.3.x -- Depreciación y Amortización: su propia línea de la cascada.
UPDATE dbo.cat_plan_cuentas
SET subclasificacion_resultado = 'DEPRECIACION_AMORTIZACION'
WHERE tipo_cuenta = 'GASTO' AND es_imputable = 1
  AND codigo_cuenta LIKE '6.3.%';

-- 6.4.x -- Gastos Financieros y Otros: el único grupo que SÍ mezcla dos
-- naturalezas distintas, por eso se clasifica cuenta por cuenta (no por
-- prefijo de código) usando el id_cuenta fijo cargado en
-- crear_modulo_contabilidad_transacciones.sql.
UPDATE dbo.cat_plan_cuentas
SET subclasificacion_resultado = 'FINANCIERO'
WHERE id_cuenta = 6411;  -- 6.4.01.001 Intereses Bancarios y Comisiones

UPDATE dbo.cat_plan_cuentas
SET subclasificacion_resultado = 'IMPUESTO'
WHERE id_cuenta = 6412;  -- 6.4.01.002 Impuesto a la Renta Primera Categoría

-- Verificación: cualquier cuenta imputable de tipo COSTO/GASTO que haya
-- quedado sin clasificar (ej. una cuenta agregada manualmente después
-- de este script, antes de declarar su subclasificación) debería dar 0
-- filas. Si no da 0, hay que clasificarla manualmente antes de confiar
-- en el EBITDA / Estado de Resultados en cascada.
SELECT id_cuenta, codigo_cuenta, nombre_cuenta, tipo_cuenta
FROM dbo.cat_plan_cuentas
WHERE tipo_cuenta IN ('COSTO', 'GASTO') AND es_imputable = 1
  AND subclasificacion_resultado IS NULL;
GO
