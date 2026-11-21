-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Clasificación Corriente / No Corriente en cat_plan_cuentas,
--         para habilitar los KPIs de Liquidez (Razón Corriente, Prueba
--         Ácida, Capital de Trabajo).
-- ====================================================================
-- PRERREQUISITO: sql/crear_modulo_contabilidad_transacciones.sql y
-- sql/crear_vistas_reportes_gestion.sql ya deben estar desplegados.
--
-- DISEÑO: la distinción Corriente/No Corriente YA existe implícita en
-- el codigo_cuenta del plan de cuentas estándar cargado (1.1.x =
-- "ACTIVO CORRIENTE", 1.2.x = "ACTIVO NO CORRIENTE", 2.1.x = "PASIVO
-- CORRIENTE", 2.2.x = "PASIVO NO CORRIENTE") -- nunca se había
-- materializado en una columna propia. En vez de pedir una
-- clasificación manual cuenta por cuenta (con riesgo de error humano o
-- de quedar desactualizada si se agregan cuentas nuevas), se agrega
-- como una columna COMPUTED derivada del propio codigo_cuenta: siempre
-- queda al día automáticamente, incluida para cualquier cuenta nueva
-- que se agregue en el futuro respetando esta misma convención de
-- codificación. Es NULL para Patrimonio/Ingreso/Costo/Gasto (no aplica
-- el concepto Corriente/No Corriente) y para las cuentas no imputables
-- (de agrupación).
-- ====================================================================

USE consultora_pymes_core;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.cat_plan_cuentas') AND name = 'clasificacion_corriente'
)
BEGIN
    ALTER TABLE dbo.cat_plan_cuentas ADD clasificacion_corriente AS (
        CASE
            WHEN codigo_cuenta LIKE '1.1.%' OR codigo_cuenta LIKE '2.1.%' THEN CAST(1 AS BIT)
            WHEN codigo_cuenta LIKE '1.2.%' OR codigo_cuenta LIKE '2.2.%' THEN CAST(0 AS BIT)
            ELSE NULL
        END
    );
    PRINT 'Columna clasificacion_corriente agregada a cat_plan_cuentas.';
END
ELSE
BEGIN
    PRINT 'La columna clasificacion_corriente ya existia -- no se hizo nada.';
END
GO

-- Se extiende vw_balance_general (no se cambia ningun nombre ni tipo de
-- columna existente, solo se agrega una al final -- retrocompatible con
-- el Dashboard, que selecciona columnas por nombre explicito).
IF OBJECT_ID('dbo.vw_balance_general', 'V') IS NOT NULL DROP VIEW dbo.vw_balance_general;
GO
CREATE VIEW dbo.vw_balance_general AS
SELECT
    cp.id_cuenta,
    cp.codigo_cuenta,
    cp.nombre_cuenta,
    cp.tipo_cuenta,
    cp.naturaleza,
    cp.clasificacion_corriente,
    CASE WHEN cp.naturaleza = 'DEUDORA'
         THEN ISNULL(SUM(d.debe), 0.00) - ISNULL(SUM(d.haber), 0.00)
         ELSE ISNULL(SUM(d.haber), 0.00) - ISNULL(SUM(d.debe), 0.00)
    END AS saldo
FROM dbo.cat_plan_cuentas cp
LEFT JOIN dbo.tbl_asientos_detalle d ON d.id_cuenta = cp.id_cuenta
WHERE cp.es_imputable = 1
  AND cp.tipo_cuenta IN ('ACTIVO', 'PASIVO', 'PATRIMONIO')
GROUP BY cp.id_cuenta, cp.codigo_cuenta, cp.nombre_cuenta, cp.tipo_cuenta, cp.naturaleza, cp.clasificacion_corriente;
GO

PRINT 'vw_balance_general actualizada con clasificacion_corriente.';
GO

-- Verificacion rapida: deberia mostrar, por cuenta imputable de Activo y
-- Pasivo, si quedo clasificada como Corriente (1), No Corriente (0).
-- SELECT codigo_cuenta, nombre_cuenta, tipo_cuenta, clasificacion_corriente
-- FROM cat_plan_cuentas
-- WHERE tipo_cuenta IN ('ACTIVO', 'PASIVO') AND es_imputable = 1
-- ORDER BY codigo_cuenta;
