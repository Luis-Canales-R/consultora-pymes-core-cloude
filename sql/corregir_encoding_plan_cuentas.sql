-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestion
-- Objeto: Correccion de encoding en cat_plan_cuentas.nombre_cuenta
-- ====================================================================
-- CAUSA RAIZ: el archivo original crear_modulo_contabilidad_
-- transacciones.sql esta guardado en UTF-8 SIN BOM (marca de encoding).
-- SSMS, al no poder detectar automaticamente que es UTF-8, probablemente
-- lo abrio como 'Western European (Windows) - Codepage 1252' la primera
-- vez que se ejecuto, lo que corrompio cada caracter acentuado en dos
-- caracteres (ej. 'o' + tilde paso a mostrarse como 'Ã³'). Esta
-- corrupcion quedo guardada tal cual en la base de datos real.
--
-- ESTE ARCHIVO SI tiene BOM UTF-8 (lo agrega Claude al generarlo), para
-- que SSMS lo detecte correctamente y no repita el mismo problema. Si al
-- abrirlo en SSMS los nombres de cuenta de abajo se ven con tildes
-- correctas (no con simbolos raros), es seguro ejecutarlo tal cual.
-- Si se ven mal IGUAL, antes de ejecutar: en SSMS, Archivo > Abrir con...
-- o el boton de flecha junto a 'Guardar', elegir codificacion
-- 'Unicode (UTF-8 con firma) - Codepage 65001'.
-- ====================================================================

USE consultora_pymes_core;
GO

UPDATE cat_plan_cuentas SET nombre_cuenta = N'Depósitos a Plazo' WHERE codigo_cuenta = '1.1.01.003';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'( - ) Estimación Deudores Incobrables' WHERE codigo_cuenta = '1.1.02.009';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Inventario / Mercaderías en Bodega' WHERE codigo_cuenta = '1.1.04.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Productos en Tránsito / Importaciones' WHERE codigo_cuenta = '1.1.04.002';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'IVA Crédito Fiscal' WHERE codigo_cuenta = '1.1.05.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Remanente de Crédito Fiscal' WHERE codigo_cuenta = '1.1.05.003';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Equipos Médicos / Maquinarias' WHERE codigo_cuenta = '1.2.01.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'( - ) Depreciación Acumulada Activo Fijo' WHERE codigo_cuenta = '1.2.01.099';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Materia Prima Aplicada a Producción por Regularizar' WHERE codigo_cuenta = '2.1.02.003';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Obligaciones con el Personal (Nómina)' WHERE codigo_cuenta = '2.1.03';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Impuesto Único a los Trabajadores por Pagar' WHERE codigo_cuenta = '2.1.03.003';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'IVA Débito Fiscal' WHERE codigo_cuenta = '2.1.04.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Retención Impuesto 2da Categoría (Honorarios)' WHERE codigo_cuenta = '2.1.04.002';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Préstamos Bancarios CP / Créditos de Enlace' WHERE codigo_cuenta = '2.1.05.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Créditos Hipotecarios / Leasing Financiero LP' WHERE codigo_cuenta = '2.2.01.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Resultados Acumulados (Años Anteriores)' WHERE codigo_cuenta = '3.1.03.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Resultado del Ejercicio (Utilidad/Pérdida)' WHERE codigo_cuenta = '3.1.04.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'COSTOS INDIRECTOS DE FABRICACIÓN (CIF)' WHERE codigo_cuenta = '5.2';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'CIF - Arriendo y Depreciación de Planta' WHERE codigo_cuenta = '5.2.01.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'CIF - Supervisión y Mano de Obra Indirecta' WHERE codigo_cuenta = '5.2.01.002';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'CIF - Servicios Básicos y Mantención de Planta' WHERE codigo_cuenta = '5.2.01.003';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'GASTOS DE ADMINISTRACIÓN Y VENTAS (OPEX)' WHERE codigo_cuenta = '6';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Sueldos Administración y Gerencia' WHERE codigo_cuenta = '6.1.01.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'GASTOS GENERALES Y DE OPERACIÓN' WHERE codigo_cuenta = '6.2';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Servicios Básicos (Luz, Agua, Telecomunicaciones)' WHERE codigo_cuenta = '6.2.01.002';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Mantención y Reparaciones' WHERE codigo_cuenta = '6.2.01.004';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'DEPRECIACIÓN Y AMORTIZACIÓN' WHERE codigo_cuenta = '6.3';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Depreciación del Ejercicio' WHERE codigo_cuenta = '6.3.01.001';
UPDATE cat_plan_cuentas SET nombre_cuenta = N'Impuesto a la Renta Primera Categoría' WHERE codigo_cuenta = '6.4.01.002';
GO

-- Verificacion: deberia devolver 0 filas si la correccion funciono
-- (ya no deberian quedar caracteres 'Ã' sueltos en nombre_cuenta).
SELECT codigo_cuenta, nombre_cuenta FROM cat_plan_cuentas WHERE nombre_cuenta LIKE '%Ã%';
GO

PRINT 'Correccion de encoding aplicada: 29 cuentas actualizadas.';
GO
