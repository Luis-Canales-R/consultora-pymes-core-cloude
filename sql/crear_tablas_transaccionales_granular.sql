-- ==========================================
-- PRERREQUISITOS: Ejecutar previamente, en este orden:
--   1) sql/crear_modulo_terceros.sql                    (tbl_terceros)
--   2) sql/crear_modulo_centros_costo_empleados.sql      (tbl_centros_costo, tbl_empleados_usuarios)
--   3) sql/crear_modulo_contabilidad_transacciones.sql   (cat_plan_cuentas)
--   4) sql/crear_modulo_productos_servicios.sql          (tbl_productos_servicios)
--
-- Nota v3 (Control de Gestión): cada transacción (venta, compra, mov. de
-- caja) ahora se imputa a un Centro de Costo y a un Empleado/Responsable,
-- para poder construir reportes de control de gestión segmentados (ej.
-- Estado de Resultados por centro de costo). Ambas columnas son NULL-ables
-- para no romper cargas históricas sin esa información.
-- ==========================================

USE consultora_pymes_core;
GO

-- ==========================================
-- 1. LIMPIEZA PREVIA DE TABLAS DEPENDIENTES
-- ==========================================
DROP TABLE IF EXISTS tbl_movimientos_caja;
DROP TABLE IF EXISTS tbl_ventas_detalle;
DROP TABLE IF EXISTS tbl_ventas_devengadas;
DROP TABLE IF EXISTS tbl_compras_detalle;
DROP TABLE IF EXISTS tbl_ordenes_compra;
GO

-- ==========================================
-- 2. MÓDULO DE COMPRAS (Órdenes y Detalle)
-- ==========================================
CREATE TABLE tbl_ordenes_compra (
    id_orden_compra INT PRIMARY KEY,
    folio_oc VARCHAR(50) UNIQUE NOT NULL,
    id_tercero INT NOT NULL, -- Proveedor (vinculado a tbl_terceros)
    fecha_emision DATE NOT NULL,
    fecha_entrega_esperada DATE NULL,
    monto_neto DECIMAL(18,2) NOT NULL,
    monto_iva DECIMAL(18,2) NOT NULL,
    monto_total DECIMAL(18,2) NOT NULL,
    estado_oc VARCHAR(30) NOT NULL CHECK (estado_oc IN ('BORRADOR', 'APROBADA', 'RECIBIDA', 'ANULADA')),
    id_centro_costo INT NULL, -- v3: Centro de costo que solicita/recibe la compra
    id_empleado INT NULL,     -- v3: Empleado responsable/comprador
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_oc_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero),
    CONSTRAINT fk_oc_centro_costo FOREIGN KEY (id_centro_costo) REFERENCES tbl_centros_costo(id_centro_costo),
    CONSTRAINT fk_oc_empleado FOREIGN KEY (id_empleado) REFERENCES tbl_empleados_usuarios(id_empleado)
);

-- v7 (Kardex Real de Insumos): id_item pasa a ser NULL-able y se agrega
-- id_insumo (FK polimórfica pero tipada, mismo patrón que tbl_movimientos_
-- inventario): una compra puede ser de un ítem (tbl_productos_servicios,
-- típicamente COMPRADO_REVENTA) o de un insumo (cat_insumos_recursos,
-- materia prima para FABRICADO/SERVICIO), nunca ambos ni ninguno.
CREATE TABLE tbl_compras_detalle (
    id_compra_detalle INT PRIMARY KEY,
    id_orden_compra INT NOT NULL,
    id_item INT NULL,    -- Producto (vinculado a tbl_productos_servicios)
    id_insumo INT NULL,  -- Insumo/materia prima (vinculado a cat_insumos_recursos) -- v7
    cantidad DECIMAL(18,4) NOT NULL,
    precio_unitario DECIMAL(18,2) NOT NULL,
    porcentaje_descuento DECIMAL(5,2) DEFAULT 0.00,
    subtotal_neto DECIMAL(18,2) NOT NULL,
    CONSTRAINT fk_compra_oc FOREIGN KEY (id_orden_compra) REFERENCES tbl_ordenes_compra(id_orden_compra) ON DELETE CASCADE,
    CONSTRAINT fk_compra_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item),
    CONSTRAINT fk_compra_insumo FOREIGN KEY (id_insumo) REFERENCES cat_insumos_recursos(id_insumo),
    CONSTRAINT ck_compra_detalle_una_entidad CHECK (
        (id_item IS NOT NULL AND id_insumo IS NULL) OR (id_item IS NULL AND id_insumo IS NOT NULL)
    )
);

-- ==========================================
-- 3. MÓDULO DE VENTAS (Devengadas y Detalle)
-- ==========================================
CREATE TABLE tbl_ventas_devengadas (
    id_venta_devengada INT PRIMARY KEY,
    folio_factura VARCHAR(50) UNIQUE NOT NULL,
    id_tercero INT NOT NULL, -- Cliente / Sponsor (vinculado a tbl_terceros)
    fecha_emision DATE NOT NULL,
    fecha_vencimiento DATE NULL,
    monto_neto DECIMAL(18,2) NOT NULL,
    monto_iva DECIMAL(18,2) NOT NULL,
    monto_total DECIMAL(18,2) NOT NULL,
    estado_venta VARCHAR(30) NOT NULL CHECK (estado_venta IN ('DEVENGADO', 'FACTURADO', 'PAGADO', 'ANULADO')),
    id_centro_costo INT NULL, -- v3: Centro de costo que genera la venta
    id_empleado INT NULL,     -- v3: Vendedor / responsable comercial
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_venta_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero),
    CONSTRAINT fk_venta_centro_costo FOREIGN KEY (id_centro_costo) REFERENCES tbl_centros_costo(id_centro_costo),
    CONSTRAINT fk_venta_empleado FOREIGN KEY (id_empleado) REFERENCES tbl_empleados_usuarios(id_empleado)
);

CREATE TABLE tbl_ventas_detalle (
    id_venta_detalle INT PRIMARY KEY,
    id_venta_devengada INT NOT NULL,
    id_item INT NOT NULL, -- Producto o Servicio (vinculado a tbl_productos_servicios)
    cantidad DECIMAL(18,4) NOT NULL,
    precio_unitario DECIMAL(18,2) NOT NULL,
    porcentaje_descuento DECIMAL(5,2) DEFAULT 0.00,
    subtotal_neto DECIMAL(18,2) NOT NULL,
    CONSTRAINT fk_venta_cabecera FOREIGN KEY (id_venta_devengada) REFERENCES tbl_ventas_devengadas(id_venta_devengada) ON DELETE CASCADE,
    CONSTRAINT fk_venta_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item)
);

-- ==========================================
-- 4. MÓDULO DE TESORERÍA / CAJA (Capa de Liquidez)
-- Diseño con montos absolutos y atributos direccionales explícitos
-- ==========================================
CREATE TABLE tbl_movimientos_caja (
    id_movimiento INT PRIMARY KEY,
    fecha_movimiento DATE NOT NULL,
    id_cuenta_bancaria INT NOT NULL, -- Vinculada a cat_plan_cuentas (ej: Banco Principal 1.1.01.002)
    tipo_flujo VARCHAR(30) NOT NULL CHECK (tipo_flujo IN ('INGRESO', 'EGRESO', 'TRASPASO_HASTA', 'TRASPASO_DESDE')),
    monto_absoluto DECIMAL(18,2) NOT NULL CHECK (monto_absoluto > 0), -- Siempre positivo
    glosa_movimiento VARCHAR(250) NOT NULL,
    id_tercero INT NULL, -- Opcional: asociado si proviene de un cobro o pago externo
    id_centro_costo INT NULL, -- v3: Centro de costo imputado al movimiento
    id_empleado INT NULL,     -- v3: Empleado responsable del movimiento
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_caja_cuenta FOREIGN KEY (id_cuenta_bancaria) REFERENCES cat_plan_cuentas(id_cuenta),
    CONSTRAINT fk_caja_tercero FOREIGN KEY (id_tercero) REFERENCES tbl_terceros(id_tercero),
    CONSTRAINT fk_caja_centro_costo FOREIGN KEY (id_centro_costo) REFERENCES tbl_centros_costo(id_centro_costo),
    CONSTRAINT fk_caja_empleado FOREIGN KEY (id_empleado) REFERENCES tbl_empleados_usuarios(id_empleado)
);
GO