-- ==========================================
-- SCRIPT DE CREACIÓN: MÓDULO UNIFICADO DE TERCEROS (BUSINESS PARTNER)
-- ==========================================

-- Limpieza previa de objetos (si existen)
DROP TABLE IF EXISTS tbl_terceros_extension_proveedor;
DROP TABLE IF EXISTS tbl_terceros_extension_cliente;
DROP TABLE IF EXISTS rel_terceros_roles;
DROP TABLE IF EXISTS tbl_terceros;
DROP TABLE IF EXISTS cat_tipos_proveedor;
DROP TABLE IF EXISTS cat_tipos_cliente_negocio;
DROP TABLE IF EXISTS cat_roles;
DROP TABLE IF EXISTS cat_tipos_persona;
DROP TABLE IF EXISTS cat_condiciones_pago;
DROP TABLE IF EXISTS cat_paises;

-- ==========================================
-- 1. CREACIÓN DE CATÁLOGOS AUXILIARES
-- ==========================================

CREATE TABLE cat_paises (
    id_pais INT PRIMARY KEY,
    codigo_iso VARCHAR(3) UNIQUE NOT NULL,
    nombre_pais VARCHAR(100) NOT NULL
);

CREATE TABLE cat_condiciones_pago (
    id_condicion_pago INT PRIMARY KEY,
    codigo VARCHAR(50) UNIQUE NOT NULL,
    descripcion VARCHAR(100) NOT NULL,
    dias INT NOT NULL
);

CREATE TABLE cat_tipos_persona (
    id_tipo_persona INT PRIMARY KEY,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(50) NOT NULL
);

CREATE TABLE cat_roles (
    id_rol INT PRIMARY KEY,
    codigo VARCHAR(30) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL
);

CREATE TABLE cat_tipos_cliente_negocio (
    id_tipo_cliente_negocio INT PRIMARY KEY,
    codigo VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL
);

CREATE TABLE cat_tipos_proveedor (
    id_tipo_proveedor INT PRIMARY KEY,
    codigo VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL
);

-- ==========================================
-- 2. NÚCLEO: MAESTRO UNIFICADO DE TERCEROS
-- ==========================================

CREATE TABLE tbl_terceros (
    id_tercero INT PRIMARY KEY,
    codigo_tercero VARCHAR(50) UNIQUE NOT NULL,
    id_tipo_persona INT NOT NULL,
    razon_social VARCHAR(200) NOT NULL,
    nombre_fantasia VARCHAR(150),
    rut_dni VARCHAR(20) UNIQUE NOT NULL,
    direccion VARCHAR(250),
    comuna_ciudad VARCHAR(100),
    id_pais INT NOT NULL,
    contacto_nombre VARCHAR(100),
    contacto_email VARCHAR(100),
    telefono VARCHAR(30),
    estado_activo BIT DEFAULT 1,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_tercero_tipo_persona FOREIGN KEY (id_tipo_persona) REFERENCES cat_tipos_persona(id_tipo_persona),
    CONSTRAINT fk_tercero_pais FOREIGN KEY (id_pais) REFERENCES cat_paises(id_pais)
);

-- ==========================================
-- 3. ASIGNACIÓN DE ROLES (N:M)
-- ==========================================

CREATE TABLE rel_terceros_roles (
    id_tercero INT,
    id_rol INT,
    PRIMARY KEY (id_tercero, id_rol),
    CONSTRAINT fk_rel_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero) ON DELETE CASCADE,
    CONSTRAINT fk_rel_rol FOREIGN KEY (id_rol) REFERENCES cat_roles(id_rol)
);

-- ==========================================
-- 4. EXTENSIONES POR ROL
-- ==========================================

CREATE TABLE tbl_terceros_extension_cliente (
    id_tercero INT PRIMARY KEY,
    id_tipo_cliente_negocio INT NOT NULL,
    id_condicion_pago INT NOT NULL,
    limite_credito DECIMAL(18,2),
    CONSTRAINT fk_ext_cliente_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero) ON DELETE CASCADE,
    CONSTRAINT fk_ext_cliente_negocio FOREIGN KEY (id_tipo_cliente_negocio) REFERENCES cat_tipos_cliente_negocio(id_tipo_cliente_negocio),
    CONSTRAINT fk_ext_cliente_pago FOREIGN KEY (id_condicion_pago) REFERENCES cat_condiciones_pago(id_condicion_pago)
);

CREATE TABLE tbl_terceros_extension_proveedor (
    id_tercero INT PRIMARY KEY,
    id_tipo_proveedor INT NOT NULL,
    id_condicion_pago INT NOT NULL,
    banco_cuenta_detalles VARCHAR(250),
    CONSTRAINT fk_ext_prov_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero) ON DELETE CASCADE,
    CONSTRAINT fk_ext_prov_tipo FOREIGN KEY (id_tipo_proveedor) REFERENCES cat_tipos_proveedor(id_tipo_proveedor),
    CONSTRAINT fk_ext_prov_pago FOREIGN KEY (id_condicion_pago) REFERENCES cat_condiciones_pago(id_condicion_pago)
);
GO

-- ==========================================
-- 5. DATOS BASE (catálogos minimos + un tercero de ejemplo)
-- Necesarios porque el modulo de Contabilidad/Transacciones trae una
-- demostracion (Factura F-1001, id_tercero = 1) que requiere que este
-- tercero exista. Sin estos datos, esa demostracion falla con error
-- de llave foranea (FK) porque id_tercero 1 no existe en la tabla.
-- ==========================================
INSERT INTO cat_paises (id_pais, codigo_iso, nombre_pais) VALUES
(1, 'CHL', 'Chile');

INSERT INTO cat_tipos_persona (id_tipo_persona, codigo, nombre) VALUES
(1, 'JURIDICA', 'Persona Juridica'),
(2, 'NATURAL', 'Persona Natural');

INSERT INTO tbl_terceros (id_tercero, codigo_tercero, id_tipo_persona, razon_social, rut_dni, id_pais)
VALUES (1, 'CLI-0001', 1, 'Cliente Demo S.A.', '76.000.000-0', 1);
GO
