-- ==========================================
-- PRERREQUISITO: Ejecutar previamente sql/crear_modulo_terceros.sql
-- (sin dependencia directa de FK, pero mantiene el orden estándar)
--
-- Nota v3 (Control de Gestión): este módulo se adelantó en el orden de
-- despliegue (antes era el paso 4, ahora es el paso 2) porque
-- tbl_asientos_detalle.id_centro_costo y las columnas id_centro_costo /
-- id_empleado de las tablas transaccionales referencian tbl_centros_costo
-- y tbl_empleados_usuarios. Ver README.md y CHANGELOG.md.
-- ==========================================

USE consultora_pymes_core;
GO

-- ==========================================
-- 1. LIMPIEZA PREVIA DE TABLAS
-- ==========================================
DROP TABLE IF EXISTS tbl_empleados_usuarios;
DROP TABLE IF EXISTS tbl_centros_costo;
GO

-- ==========================================
-- 2. CREACIÓN DE TABLAS MAESTRAS
-- ==========================================
CREATE TABLE tbl_centros_costo (
    id_centro_costo INT PRIMARY KEY,
    codigo_cc VARCHAR(30) UNIQUE NOT NULL,
    nombre_cc VARCHAR(150) NOT NULL,
    nivel INT NOT NULL,
    id_centro_padre INT NULL,
    es_activo BIT DEFAULT 1,
    CONSTRAINT fk_cc_padre FOREIGN KEY (id_centro_padre) REFERENCES tbl_centros_costo(id_centro_costo)
);

CREATE TABLE tbl_empleados_usuarios (
    id_empleado INT PRIMARY KEY,
    rut_dni VARCHAR(20) UNIQUE NOT NULL,
    nombre_completo VARCHAR(150) NOT NULL,
    cargo VARCHAR(100) NULL,
    correo_electronico VARCHAR(100) NULL,
    id_centro_costo INT NOT NULL,
    es_activo BIT DEFAULT 1,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_empleado_cc FOREIGN KEY (id_centro_costo) REFERENCES tbl_centros_costo(id_centro_costo)
);
GO

-- ==========================================
-- 3. INSERCIÓN DE DATOS DE EJEMPLO (SEED DATA)
-- ==========================================

-- Centros de Costo (Estructura Jerárquica)
INSERT INTO tbl_centros_costo (id_centro_costo, codigo_cc, nombre_cc, nivel, id_centro_padre) VALUES
(10, 'CC-CORP', 'Administración Central y Gerencia', 1, NULL),
(11, 'CC-FIN', 'Departamento de Finanzas y Procesos', 2, 10),
(12, 'CC-OPS', 'Operaciones y Clinical Trials Site', 2, 10),
(13, 'CC-COM', 'Comercial y Ventas', 2, 10);

-- Empleados / Usuarios de Prueba
INSERT INTO tbl_empleados_usuarios (id_empleado, rut_dni, nombre_completo, cargo, correo_electronico, id_centro_costo) VALUES
(1, '15234567-8', 'Luis Canales', 'Analista de Procesos Financieros', 'luis.canales@consultora.cl', 11),
(2, '16432109-K', 'Majo Fernandez', 'Gerente de Finanzas', 'majo.fernandez@consultora.cl', 11),
(3, '18987654-3', 'Matías Soto', 'Especialista de Facturación', 'matias.soto@consultora.cl', 13);
GO

-- ==========================================
-- 4. CONSULTA DE VALIDACIÓN
-- ==========================================
SELECT 
    e.rut_dni,
    e.nombre_completo,
    e.cargo,
    cc.codigo_cc AS codigo_centro_costo,
    cc.nombre_cc AS centro_costo
FROM tbl_empleados_usuarios e
INNER JOIN tbl_centros_costo cc ON e.id_centro_costo = cc.id_centro_costo;
GO
