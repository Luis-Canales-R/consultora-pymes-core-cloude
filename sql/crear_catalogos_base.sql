-- ==========================================================================
-- crear_catalogos_base.sql
--
-- Datos base mínimos para que el esquema real sea usable desde una
-- plataforma de captura (no solo desde scripts de demostración). Hasta
-- ahora ningún catálogo base tenía datos: ni roles (cliente/proveedor),
-- ni tipo de ítem, categoría o unidad de medida. Sin esto, no se puede
-- registrar ni un tercero (como cliente o proveedor) ni un producto.
--
-- Se ejecuta DESPUÉS de crear_modulo_terceros.sql y
-- crear_modulo_productos_servicios.sql (necesita que esas tablas existan).
-- ==========================================================================

USE consultora_pymes_core;
GO

-- Roles de terceros (reemplaza el antiguo es_cliente/es_proveedor booleano)
INSERT INTO cat_roles (id_rol, codigo, nombre) VALUES
(1, 'CLIENTE', 'Cliente'),
(2, 'PROVEEDOR', 'Proveedor');
GO

-- Tipos de ítem
INSERT INTO cat_tipos_item (id_tipo_item, codigo, nombre) VALUES
(1, 'PRODUCTO', 'Producto'),
(2, 'SERVICIO', 'Servicio');
GO

-- Unidades de medida
INSERT INTO cat_unidades_medida (id_unidad_medida, codigo, nombre) VALUES
(1, 'UN', 'Unidad'),
(2, 'HR', 'Hora'),
(3, 'KG', 'Kilogramo'),
(4, 'MES', 'Mes');
GO

-- Categorías de ítem (genéricas; se pueden ampliar según el rubro real)
INSERT INTO cat_categorias_item (id_categoria_item, codigo, nombre) VALUES
(1, 'GENERAL', 'General'),
(2, 'CONSULTORIA', 'Consultoría / Honorarios'),
(3, 'MERCADERIA', 'Mercadería / Reventa');
GO

PRINT 'Catálogos base (roles, tipos de ítem, unidades de medida, categorías) creados exitosamente.';
GO
