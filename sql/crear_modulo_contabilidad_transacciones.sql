-- ==========================================
-- PRERREQUISITO (v3): Ejecutar previamente, EN ESTE ORDEN:
--   1) sql/crear_modulo_terceros.sql              (tbl_transacciones_cabecera.id_tercero)
--   2) sql/crear_modulo_centros_costo_empleados.sql (tbl_asientos_detalle.id_centro_costo)
-- Nota v3 (Control de Gestión): el módulo de Centros de Costo/Empleados se
-- adelantó en el orden de despliegue porque tbl_asientos_detalle ahora
-- imputa cada línea contable a un centro de costo. Ver CHANGELOG.md.
-- ==========================================

USE consultora_pymes_core;
GO

-- ==========================================
-- 1. LIMPIEZA PREVIA DE TABLAS Y OBJETOS DEPENDIENTES
-- ==========================================
-- Se eliminan primero los SPs que dependen del TYPE tipo_asiento_detalle,
-- para permitir re-despliegues limpios sobre una base de datos existente.
DROP PROCEDURE IF EXISTS sp_procesar_etl_fase3;
DROP PROCEDURE IF EXISTS sp_procesar_venta_externa;
DROP PROCEDURE IF EXISTS sp_registrar_asiento_contable;
IF TYPE_ID(N'dbo.tipo_asiento_detalle') IS NOT NULL DROP TYPE dbo.tipo_asiento_detalle;
GO

DROP TABLE IF EXISTS tbl_asientos_detalle;
DROP TABLE IF EXISTS tbl_asientos_cabecera;
DROP TABLE IF EXISTS tbl_transacciones_cabecera;
DROP TABLE IF EXISTS cat_tipos_transaccion;
DROP TABLE IF EXISTS cat_plan_cuentas;
GO

-- ==========================================
-- 2. TABLA MAESTRA: PLAN DE CUENTAS CHILE
-- ==========================================
CREATE TABLE cat_plan_cuentas (
    id_cuenta INT PRIMARY KEY,
    codigo_cuenta VARCHAR(20) UNIQUE NOT NULL,
    nombre_cuenta VARCHAR(150) NOT NULL,
    nivel INT NOT NULL,
    id_cuenta_padre INT NULL,
    naturaleza VARCHAR(10) NOT NULL CHECK (naturaleza IN ('DEUDORA', 'ACREEDORA')),
    -- v3 (Control de Gestión): clasificación explícita de la cuenta. Se
    -- deja NULL aquí y se completa por UPDATE al final de la carga masiva
    -- (paso 4b) para no tener que repetir el valor en cada fila de INSERT;
    -- luego se fija NOT NULL + CHECK. Es la fuente de verdad para construir
    -- el Balance General (ACTIVO=PASIVO+PATRIMONIO) y el Estado de
    -- Resultados (INGRESO-COSTO-GASTO), en vez de parsear codigo_cuenta.
    tipo_cuenta VARCHAR(20) NULL,
    es_imputable BIT NOT NULL DEFAULT 1,
    estado_activo BIT DEFAULT 1,
    CONSTRAINT fk_cuenta_padre FOREIGN KEY (id_cuenta_padre) REFERENCES cat_plan_cuentas(id_cuenta)
);

-- ==========================================
-- 3. TRANSACCIONES Y ASIENTOS CONTABLES
-- ==========================================
CREATE TABLE cat_tipos_transaccion (
    id_tipo_transaccion INT PRIMARY KEY,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(50) NOT NULL
);

CREATE TABLE tbl_transacciones_cabecera (
    id_transaccion INT PRIMARY KEY,
    folio_documento VARCHAR(50) NOT NULL,
    id_tipo_transaccion INT NOT NULL,
    id_tercero INT NOT NULL, -- Vincula con tbl_terceros
    fecha_emision DATE NOT NULL,
    fecha_vencimiento DATE NULL,
    monto_neto DECIMAL(18,2) NOT NULL,
    monto_iva DECIMAL(18,2) NOT NULL,
    monto_total DECIMAL(18,2) NOT NULL,
    estado_operacion VARCHAR(20) NOT NULL CHECK (estado_operacion IN ('DEVENGADO', 'LIQUIDADO', 'ANULADO')),
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_trans_tipo FOREIGN KEY (id_tipo_transaccion) REFERENCES cat_tipos_transaccion(id_tipo_transaccion),
    CONSTRAINT fk_trans_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero)
);

CREATE TABLE tbl_asientos_cabecera (
    id_asiento INT PRIMARY KEY,
    id_transaccion INT NULL,
    numero_asiento INT NOT NULL,
    fecha_asiento DATE NOT NULL,
    glosa_general VARCHAR(250) NOT NULL,
    periodo_contable VARCHAR(7) NOT NULL,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_asiento_trans FOREIGN KEY (id_transaccion) REFERENCES tbl_transacciones_cabecera(id_transaccion)
);

CREATE TABLE tbl_asientos_detalle (
    id_asiento_detalle INT PRIMARY KEY,
    id_asiento INT NOT NULL,
    id_cuenta INT NOT NULL,
    debe DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    haber DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    -- v3 (Control de Gestión): imputación de la línea contable a un centro
    -- de costo. NULL para cuentas de balance que no se gestionan por CC
    -- (ej. Clientes, Proveedores, Banco); obligatorio en la práctica para
    -- las líneas de Ingreso/Costo/Gasto si se quiere un Estado de
    -- Resultados por centro de costo (ver vw_estado_resultados).
    id_centro_costo INT NULL,
    glosa_detalle VARCHAR(250) NULL,
    CONSTRAINT fk_det_asiento FOREIGN KEY (id_asiento) REFERENCES tbl_asientos_cabecera(id_asiento) ON DELETE CASCADE,
    CONSTRAINT fk_det_cuenta FOREIGN KEY (id_cuenta) REFERENCES cat_plan_cuentas(id_cuenta),
    CONSTRAINT fk_det_centro_costo FOREIGN KEY (id_centro_costo) REFERENCES tbl_centros_costo(id_centro_costo)
);
GO

-- ==========================================
-- 4. CARGA MASIVA DEL PLAN DE CUENTAS ESTÁNDAR CHILE
-- ==========================================

-- 1. ACTIVOS
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(100, '1', 'ACTIVO', 1, NULL, 'DEUDORA', 0),
(110, '1.1', 'ACTIVO CORRIENTE', 2, 100, 'DEUDORA', 0),
(111, '1.1.01', 'Disponible y Equivalentes de Efectivo', 3, 110, 'DEUDORA', 0),
(1111, '1.1.01.001', 'Caja Chica / Efectivo', 4, 111, 'DEUDORA', 1),
(1112, '1.1.01.002', 'Banco Principal (Cuenta Corriente)', 4, 111, 'DEUDORA', 1),
(1113, '1.1.01.003', 'Depósitos a Plazo', 4, 111, 'DEUDORA', 1),
(112, '1.1.02', 'Deudores por Ventas (Clientes Facturados)', 3, 110, 'DEUDORA', 0),
(1121, '1.1.02.001', 'Clientes Nacionales Facturados', 4, 112, 'DEUDORA', 1),
(1122, '1.1.02.002', 'Documentos por Cobrar', 4, 112, 'DEUDORA', 1),
(1129, '1.1.02.009', '( - ) Estimación Deudores Incobrables', 4, 112, 'DEUDORA', 1),
(113, '1.1.03', 'Cuentas por Cobrar No Facturadas (Devengos)', 3, 110, 'DEUDORA', 0),
(1131, '1.1.03.001', 'Ingresos por Servicios Devengados Pendientes de Facturar', 4, 113, 'DEUDORA', 1),
(114, '1.1.04', 'Existencias e Inventarios', 3, 110, 'DEUDORA', 0),
(1141, '1.1.04.001', 'Inventario / Mercaderías en Bodega', 4, 114, 'DEUDORA', 1),
(1142, '1.1.04.002', 'Productos en Tránsito / Importaciones', 4, 114, 'DEUDORA', 1),
(1143, '1.1.04.003', 'Inventario de Insumos y Materias Primas', 4, 114, 'DEUDORA', 1), -- v7: Kardex Real de Insumos (distinto de 1141, que es inventario de mercaderías para reventa)
(115, '1.1.05', 'Activos por Impuestos Corrientes (PPM / Fiscal)', 3, 110, 'DEUDORA', 0),
(1151, '1.1.05.001', 'IVA Crédito Fiscal', 4, 115, 'DEUDORA', 1),
(1152, '1.1.05.002', 'Pagos Providenciales Mensuales (PPM)', 4, 115, 'DEUDORA', 1),
(1153, '1.1.05.003', 'Remanente de Crédito Fiscal', 4, 115, 'DEUDORA', 1),
(120, '1.2', 'ACTIVO NO CORRIENTE', 2, 100, 'DEUDORA', 0),
(121, '1.2.01', 'Propiedades, Planta y Equipo (Activo Fijo)', 3, 120, 'DEUDORA', 0),
(1211, '1.2.01.001', 'Equipos Médicos / Maquinarias', 4, 121, 'DEUDORA', 1),
(1212, '1.2.01.002', 'Equipos Computacionales y TI', 4, 121, 'DEUDORA', 1),
(1219, '1.2.01.099', '( - ) Depreciación Acumulada Activo Fijo', 4, 121, 'DEUDORA', 1);

-- 2. PASIVOS
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(200, '2', 'PASIVO', 1, NULL, 'ACREEDORA', 0),
(210, '2.1', 'PASIVO CORRIENTE', 2, 200, 'ACREEDORA', 0),
(211, '2.1.01', 'Cuentas por Pagar (Proveedores Facturados)', 3, 210, 'ACREEDORA', 0),
(2111, '2.1.01.001', 'Proveedores Nacionales Facturados', 4, 211, 'ACREEDORA', 1),
(2112, '2.1.01.002', 'Facturas por Pagar a Plazo', 4, 211, 'ACREEDORA', 1),
(212, '2.1.02', 'Pasivos por Devengos y Provisiones', 3, 210, 'ACREEDORA', 0),
(2121, '2.1.02.001', 'Provisiones de Costos Operativos Pendientes de Factura', 4, 212, 'ACREEDORA', 1),
(2122, '2.1.02.002', 'Provisiones de Gastos Generales', 4, 212, 'ACREEDORA', 1),
-- v4 (Costeo Directo por Flujo de Venta): contra-cuenta de provisión para
-- la Materia Prima Directa (MPD) aplicada al costo de un producto
-- FABRICADO vendido, cuando esa MPD se calcula a costo estándar de
-- referencia (BOM) y no se ha comprado/registrado aún una compra real
-- del insumo específico. Se regulariza manualmente cuando se registre la
-- compra real del insumo (fuera de alcance de esta fase).
(2123, '2.1.02.003', 'Materia Prima Aplicada a Producción por Regularizar', 4, 212, 'ACREEDORA', 1),
-- v6 (Costeo Directo de Servicios): análogas a 2123 pero para la venta de
-- un ítem SERVICIO. Los insumos consumidos se aplican a costo estándar de
-- referencia (BOM); los honorarios representan el costo de las horas
-- profesionales (propias o subcontratadas) consumidas para prestar el
-- servicio. Ambas se regularizan manualmente contra la compra/liquidación
-- real (fuera de alcance de esta fase, misma limitación que 2123).
(2124, '2.1.02.004', 'Insumos Aplicados a Servicios por Regularizar', 4, 212, 'ACREEDORA', 1),
(2125, '2.1.02.005', 'Honorarios Profesionales por Pagar (Servicios)', 4, 212, 'ACREEDORA', 1),
(213, '2.1.03', 'Obligaciones con el Personal (Nómina)', 3, 210, 'ACREEDORA', 0),
(2131, '2.1.03.001', 'Remuneraciones por Pagar', 4, 213, 'ACREEDORA', 1),
(2132, '2.1.03.002', 'Retenciones Previsionales por Pagar (AFP, Isapre, Fonasa)', 4, 213, 'ACREEDORA', 1),
(2133, '2.1.03.003', 'Impuesto Único a los Trabajadores por Pagar', 4, 213, 'ACREEDORA', 1),
(2134, '2.1.03.004', 'Provisiones Vacaciones / Finiquitos', 4, 213, 'ACREEDORA', 1),
(214, '2.1.04', 'Obligaciones Tributarias Corrientes', 3, 210, 'ACREEDORA', 0),
(2141, '2.1.04.001', 'IVA Débito Fiscal', 4, 214, 'ACREEDORA', 1),
(2142, '2.1.04.002', 'Retención Impuesto 2da Categoría (Honorarios)', 4, 214, 'ACREEDORA', 1),
(215, '2.1.05', 'Obligaciones Financieras Corto Plazo', 3, 210, 'ACREEDORA', 0),
(2151, '2.1.05.001', 'Préstamos Bancarios CP / Créditos de Enlace', 4, 215, 'ACREEDORA', 1),
(220, '2.2', 'PASIVO NO CORRIENTE', 2, 200, 'ACREEDORA', 0),
(221, '2.2.01', 'Deudas Financieras Largo Plazo', 3, 220, 'ACREEDORA', 0),
(2211, '2.2.01.001', 'Créditos Hipotecarios / Leasing Financiero LP', 4, 221, 'ACREEDORA', 1);

-- 3. PATRIMONIO
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(300, '3', 'PATRIMONIO NETO', 1, NULL, 'ACREEDORA', 0),
(310, '3.1', 'PATRIMONIO', 2, 300, 'ACREEDORA', 0),
(3111, '3.1.01.001', 'Capital Pagado / Enterado', 4, 310, 'ACREEDORA', 1),
(3121, '3.1.02.001', 'Reservas de Utilidades', 4, 310, 'ACREEDORA', 1),
(3131, '3.1.03.001', 'Resultados Acumulados (Años Anteriores)', 4, 310, 'ACREEDORA', 1),
(3141, '3.1.04.001', 'Resultado del Ejercicio (Utilidad/Pérdida)', 4, 310, 'ACREEDORA', 1);

-- 4. INGRESOS
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(400, '4', 'INGRESOS', 1, NULL, 'ACREEDORA', 0),
(410, '4.1', 'INGRESOS DE ACTIVIDADES ORDINARIAS', 2, 400, 'ACREEDORA', 0),
(4111, '4.1.01.001', 'Ingresos por Servicios Devengados', 4, 410, 'ACREEDORA', 1),
(4112, '4.1.01.002', 'Ingresos por Venta de productos', 4, 410, 'ACREEDORA', 1),
(4113, '4.1.01.003', 'Otros Ingresos Operacionales (Default ETL)', 4, 410, 'ACREEDORA', 1),
(4119, '4.1.01.099', '( - ) Descuentos y Rebajas en Ventas', 4, 410, 'ACREEDORA', 1),
(420, '4.2', 'OTROS INGRESOS', 2, 400, 'ACREEDORA', 0),
(4211, '4.2.01.001', 'Ingresos Financieros (Intereses Ganados)', 4, 420, 'ACREEDORA', 1),
(4212, '4.2.01.002', 'Ganancia por Diferencia de Cambio / Reajustes', 4, 420, 'ACREEDORA', 1);

-- 5. COSTOS DIRECTOS
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(500, '5', 'COSTOS (COGS)', 1, NULL, 'DEUDORA', 0),
(510, '5.1', 'COSTOS OPERACIONALES DIRECTOS', 2, 500, 'DEUDORA', 0),
(5111, '5.1.01.001', 'Costo de Ventas Insumos / Bodega', 4, 510, 'DEUDORA', 1),
(5112, '5.1.02.001', 'Remuneraciones Directas', 4, 510, 'DEUDORA', 1),
(5113, '5.1.03.001', 'Honorarios / Servicios Subcontratados', 4, 510, 'DEUDORA', 1),
(5114, '5.1.04.001', 'Arriendos de Equipos Directos', 4, 510, 'DEUDORA', 1),
-- v4 (Costeo Directo por Flujo de Venta): Costos Indirectos de Fabricación
-- (CIF). Las 3 primeras acumulan el gasto indirecto REAL a medida que se
-- compra/paga (vía id_cuenta_costo_gasto de ítems de tipo gasto indirecto,
-- o asiento manual); la cuarta (5.2.02.001) es la CONTRA-CUENTA que usa
-- sp_prorratear_cif_periodo para absorber ese CIF hacia el costo de cada
-- producto FABRICADO vendido en el periodo. El saldo neto del subgrupo
-- 5.2 tras el cierre es, idealmente, cero; si no lo es, representa CIF
-- sub/sobre-absorbido (variación), visible directamente en
-- vw_estado_resultados.
(520, '5.2', 'COSTOS INDIRECTOS DE FABRICACIÓN (CIF)', 2, 500, 'DEUDORA', 0),
(5211, '5.2.01.001', 'CIF - Arriendo y Depreciación de Planta', 4, 520, 'DEUDORA', 1),
(5212, '5.2.01.002', 'CIF - Supervisión y Mano de Obra Indirecta', 4, 520, 'DEUDORA', 1),
(5213, '5.2.01.003', 'CIF - Servicios Básicos y Mantención de Planta', 4, 520, 'DEUDORA', 1),
(5219, '5.2.02.001', 'CIF Absorbido a Productos (contra-cuenta)', 4, 520, 'DEUDORA', 1);

-- 6. GASTOS (OPEX)
INSERT INTO cat_plan_cuentas (id_cuenta, codigo_cuenta, nombre_cuenta, nivel, id_cuenta_padre, naturaleza, es_imputable) VALUES
(600, '6', 'GASTOS DE ADMINISTRACIÓN Y VENTAS (OPEX)', 1, NULL, 'DEUDORA', 0),
(610, '6.1', 'GASTOS DE PERSONAL ADMINISTRATIVO', 2, 600, 'DEUDORA', 0),
(6111, '6.1.01.001', 'Sueldos Administración y Gerencia', 4, 610, 'DEUDORA', 1),
(6112, '6.1.01.002', 'Leyes Sociales y Beneficios', 4, 610, 'DEUDORA', 1),
(620, '6.2', 'GASTOS GENERALES Y DE OPERACIÓN', 2, 600, 'DEUDORA', 0),
(6211, '6.2.01.001', 'Arriendos de Inmuebles / Sucursales', 4, 620, 'DEUDORA', 1),
(6212, '6.2.01.002', 'Servicios Básicos (Luz, Agua, Telecomunicaciones)', 4, 620, 'DEUDORA', 1),
(6213, '6.2.01.003', 'Software, Licencias TI y Servidores Cloud', 4, 620, 'DEUDORA', 1),
(6214, '6.2.01.004', 'Mantención y Reparaciones', 4, 620, 'DEUDORA', 1),
(6215, '6.2.01.005', 'Gastos Operacionales Generales (Default ETL)', 4, 620, 'DEUDORA', 1),
(630, '6.3', 'DEPRECIACIÓN Y AMORTIZACIÓN', 2, 600, 'DEUDORA', 0),
(6311, '6.3.01.001', 'Depreciación del Ejercicio', 4, 630, 'DEUDORA', 1),
(640, '6.4', 'GASTOS FINANCIEROS Y OTROS', 2, 600, 'DEUDORA', 0),
(6411, '6.4.01.001', 'Intereses Bancarios y Comisiones', 4, 640, 'DEUDORA', 1),
(6412, '6.4.01.002', 'Impuesto a la Renta Primera Categoría', 4, 640, 'DEUDORA', 1);

-- Tipos de Transacción
INSERT INTO cat_tipos_transaccion (id_tipo_transaccion, codigo, nombre) VALUES
(1, 'FACTURA_VENTA', 'Factura de Venta Emitida'),
(2, 'PAGO_CLIENTE', 'Cobro / Pago de Cliente');
GO

-- ==========================================
-- 4b. BACKFILL DE tipo_cuenta (v3) Y ENDURECIMIENTO DE LA COLUMNA
-- ==========================================
-- Se deriva una sola vez, a partir del dígito raíz de codigo_cuenta, para
-- las 60+ cuentas recién cargadas. Desde este punto en adelante,
-- tipo_cuenta es NOT NULL + CHECK: cualquier cuenta nueva que se inserte
-- manualmente deberá declarar su tipo explícitamente.
UPDATE cat_plan_cuentas
SET tipo_cuenta = CASE LEFT(codigo_cuenta, 1)
    WHEN '1' THEN 'ACTIVO'
    WHEN '2' THEN 'PASIVO'
    WHEN '3' THEN 'PATRIMONIO'
    WHEN '4' THEN 'INGRESO'
    WHEN '5' THEN 'COSTO'
    WHEN '6' THEN 'GASTO'
END;
GO

ALTER TABLE cat_plan_cuentas ALTER COLUMN tipo_cuenta VARCHAR(20) NOT NULL;
ALTER TABLE cat_plan_cuentas ADD CONSTRAINT ck_cuenta_tipo
    CHECK (tipo_cuenta IN ('ACTIVO','PASIVO','PATRIMONIO','INGRESO','COSTO','GASTO'));
GO

-- ==========================================
-- 5. DEMOSTRACIÓN PRÁCTICA: CICLO COMPLETO (DEVENGADO + LIQUIDACIÓN)
-- ==========================================

-- A) Registro Documento Comercial (Factura de Venta #1001 a Cliente ID 1 por $1.000.000 + IVA)
INSERT INTO tbl_transacciones_cabecera 
(id_transaccion, folio_documento, id_tipo_transaccion, id_tercero, fecha_emision, fecha_vencimiento, monto_neto, monto_iva, monto_total, estado_operacion)
VALUES 
(1, 'F-1001', 1, 1, '2026-10-15', '2026-11-15', 1000000.00, 190000.00, 1190000.00, 'DEVENGADO');

-- B) ASIENTO 1: EL DEVENGADO (Reconocimiento de la Venta e Impuestos)
INSERT INTO tbl_asientos_cabecera (id_asiento, id_transaccion, numero_asiento, fecha_asiento, glosa_general, periodo_contable)
VALUES (1, 1, 101, '2026-10-15', 'Reconocimiento devengado Venta Servicio F-1001', '2026-10');

-- Detalle Asiento Devengado:
-- Debe: Clientes Nacionales (1.1.02.001) por $1.190.000
-- Haber: Ingresos por Servicios Devengados (4.1.01.001) por $1.000.000
-- Haber: IVA Débito Fiscal (2.1.04.001) por $190.000
INSERT INTO tbl_asientos_detalle (id_asiento_detalle, id_asiento, id_cuenta, debe, haber, glosa_detalle) VALUES
(1, 1, 1121, 1190000.00, 0.00, 'Cuenta por Cobrar Cliente F-1001'),
(2, 1, 4111, 0.00, 1000000.00, 'Reconocimiento Ingreso Neto'),
(3, 1, 2141, 0.00, 190000.00, 'IVA Débito Fiscal 19%');

-- C) ASIENTO 2: LA LIQUIDACIÓN / COBRO (Pago recibido en Banco Principal)
INSERT INTO tbl_asientos_cabecera (id_asiento, id_transaccion, numero_asiento, fecha_asiento, glosa_general, periodo_contable)
VALUES (2, 1, 102, '2026-10-20', 'Recaudación y liquidación bancaria F-1001', '2026-10');

-- Detalle Asiento Liquidación:
-- Debe: Banco Principal (1.1.01.002) por $1.190.000
-- Haber: Clientes Nacionales (1.1.02.001) por $1.190.000 (Extingue la Cta por Cobrar)
INSERT INTO tbl_asientos_detalle (id_asiento_detalle, id_asiento, id_cuenta, debe, haber, glosa_detalle) VALUES
(4, 2, 1112, 1190000.00, 0.00, 'Ingreso de caja a Banco Principal'),
(5, 2, 1121, 0.00, 1190000.00, 'Liquidación de la Cta por Cobrar Cliente');

-- Actualizar estado del documento comercial a LIQUIDADO
UPDATE tbl_transacciones_cabecera SET estado_operacion = 'LIQUIDADO' WHERE id_transaccion = 1;
GO

-- ==========================================
-- 6. VALIDACIÓN DE CUADRATURA CONTABLE Y BALANCE GENERAL COMPROBACIÓN
-- ==========================================
SELECT 
    a.numero_asiento,
    a.fecha_asiento,
    a.glosa_general,
    SUM(d.debe) AS total_debe,
    SUM(d.haber) AS total_haber,
    CASE WHEN SUM(d.debe) = SUM(d.haber) THEN 'CUADRADO (PARTIDA DOBLE OK)' ELSE 'DESCUADRADO' END AS estado_cuadratura
FROM tbl_asientos_cabecera a
INNER JOIN tbl_asientos_detalle d ON a.id_asiento = d.id_asiento
GROUP BY a.numero_asiento, a.fecha_asiento, a.glosa_general;
GO

-- ==========================================
-- 7. (v3) TIPO TABLA Y SP REUTILIZABLE PARA CONTABILIZACIÓN AUTOMÁTICA
-- ==========================================
-- Objetivo "plataforma de control de gestión": todo módulo transaccional
-- (ventas, compras, caja) debe poder generar su asiento de partida doble
-- llamando a UN solo punto de entrada, en vez de reimplementar el
-- INSERT a tbl_asientos_cabecera/detalle en cada stored procedure.
-- sp_procesar_venta_externa y sp_procesar_etl_fase3 son los consumidores.

CREATE TYPE dbo.tipo_asiento_detalle AS TABLE (
    id_cuenta       INT NOT NULL,
    debe            DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    haber           DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    id_centro_costo INT NULL,
    glosa_detalle   VARCHAR(250) NULL
);
GO

CREATE PROCEDURE sp_registrar_asiento_contable
    @id_transaccion     INT = NULL,       -- FK opcional a tbl_transacciones_cabecera, si aplica
    @fecha_asiento       DATE,
    @glosa_general       VARCHAR(250),
    @periodo_contable     VARCHAR(7),       -- formato 'YYYY-MM'
    @lineas               dbo.tipo_asiento_detalle READONLY,
    @id_asiento_out       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- Regla de oro de partida doble: Debe TOTAL = Haber TOTAL.
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

            DECLARE @nuevo_id_asiento INT = ISNULL((SELECT MAX(id_asiento) FROM tbl_asientos_cabecera), 0) + 1;
            DECLARE @nuevo_numero_asiento INT = ISNULL((SELECT MAX(numero_asiento) FROM tbl_asientos_cabecera), 100) + 1;

            INSERT INTO tbl_asientos_cabecera (id_asiento, id_transaccion, numero_asiento, fecha_asiento, glosa_general, periodo_contable)
            VALUES (@nuevo_id_asiento, @id_transaccion, @nuevo_numero_asiento, @fecha_asiento, @glosa_general, @periodo_contable);

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