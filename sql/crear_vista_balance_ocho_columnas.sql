-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Vista "Balance de 8 Columnas" (hoja de trabajo tradicional
--         usada por contadores en Chile/Latinoamérica para pasar del
--         balance de comprobación a los estados financieros finales).
-- ====================================================================
-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql y
-- sql/crear_vistas_reportes_gestion.sql ya deben estar desplegados
-- (reutiliza la misma lógica de saldo por naturaleza que vw_balance_general).
--
-- DISEÑO:
--   Las 4 columnas "Sumas" + "Saldos" tradicionales se construyen igual
--   para todas las cuentas imputables. Las 4 columnas "Inventario" (cuentas
--   de Balance) + "Pérdidas y Ganancias" (cuentas de Resultado) reparten
--   ese mismo saldo según cp.tipo_cuenta -- ninguna cuenta cae en más de
--   un balde de esas 4 columnas finales.
--
--   Adaptación práctica respecto del formato clásico de 8 columnas: el
--   Patrimonio se muestra en su propia columna de Inventario en vez de
--   fusionarlo con Pasivo (como hacían algunos textos antiguos), porque
--   para un controller moderno es más útil verlo separado. Así, el
--   bloque de "cuentas de Balance" queda en 3 columnas (Activo/Pasivo/
--   Patrimonio) en vez de 2, y el de "Resultado" se mantiene en las 2
--   columnas clásicas (Pérdida/Ganancia). El total de columnas de valor
--   queda en 9 en vez de 8, pero el espíritu y el uso son los mismos:
--   es la misma hoja de trabajo, con Patrimonio desagregado de Pasivo.
--
--   Es una fotografía "a la fecha" (acumula TODOS los asientos
--   históricos, igual que vw_balance_general), porque esta hoja de
--   trabajo se usa tradicionalmente para el cierre, no para un periodo
--   específico. Una futura variante con corte a una fecha/periodo
--   determinado se puede agregar como un parámetro adicional si se
--   necesita (hoy no era parte del alcance pedido).
-- ====================================================================

USE consultora_pymes_core;
GO

IF OBJECT_ID('dbo.vw_balance_ocho_columnas', 'V') IS NOT NULL DROP VIEW dbo.vw_balance_ocho_columnas;
GO
CREATE VIEW dbo.vw_balance_ocho_columnas AS
WITH saldos AS (
    SELECT
        cp.id_cuenta,
        cp.codigo_cuenta,
        cp.nombre_cuenta,
        cp.tipo_cuenta,
        cp.naturaleza,
        ISNULL(SUM(d.debe), 0.00)  AS suma_debe,
        ISNULL(SUM(d.haber), 0.00) AS suma_haber,
        CASE WHEN cp.naturaleza = 'DEUDORA'
             THEN ISNULL(SUM(d.debe), 0.00) - ISNULL(SUM(d.haber), 0.00)
             ELSE ISNULL(SUM(d.haber), 0.00) - ISNULL(SUM(d.debe), 0.00)
        END AS saldo
    FROM dbo.cat_plan_cuentas cp
    LEFT JOIN dbo.tbl_asientos_detalle d ON d.id_cuenta = cp.id_cuenta
    WHERE cp.es_imputable = 1
    GROUP BY cp.id_cuenta, cp.codigo_cuenta, cp.nombre_cuenta, cp.tipo_cuenta, cp.naturaleza
)
SELECT
    id_cuenta,
    codigo_cuenta,
    nombre_cuenta,
    tipo_cuenta,
    naturaleza,
    -- Columnas 1-2: Sumas (todos los movimientos, sin netear)
    suma_debe,
    suma_haber,
    -- Columnas 3-4: Saldos (el saldo neto, en la columna de su naturaleza)
    CASE WHEN naturaleza = 'DEUDORA'   THEN saldo ELSE 0.00 END AS saldo_deudor,
    CASE WHEN naturaleza = 'ACREEDORA' THEN saldo ELSE 0.00 END AS saldo_acreedor,
    -- Columnas 5-7: Inventario (cuentas de Balance: Activo / Pasivo / Patrimonio)
    CASE WHEN tipo_cuenta = 'ACTIVO'     THEN saldo ELSE 0.00 END AS inventario_activo,
    CASE WHEN tipo_cuenta = 'PASIVO'     THEN saldo ELSE 0.00 END AS inventario_pasivo,
    CASE WHEN tipo_cuenta = 'PATRIMONIO' THEN saldo ELSE 0.00 END AS inventario_patrimonio,
    -- Columnas 8-9: Pérdidas y Ganancias (cuentas de Resultado)
    CASE WHEN tipo_cuenta IN ('COSTO', 'GASTO') THEN saldo ELSE 0.00 END AS perdida,
    CASE WHEN tipo_cuenta = 'INGRESO'           THEN saldo ELSE 0.00 END AS ganancia
FROM saldos;
GO

PRINT 'Vista vw_balance_ocho_columnas creada exitosamente.';
GO
