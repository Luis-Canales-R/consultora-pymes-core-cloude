-- ==========================================
-- SCRIPT DE CREACIÓN: MÓDULO DE PRODUCTOS, SERVICIOS Y EXTENSIONES (ERP PATTERN + BOM)
--
-- PRERREQUISITO (v3): Ejecutar previamente sql/crear_modulo_contabilidad_
-- transacciones.sql (tbl_productos_servicios.id_cuenta_ingreso /
-- id_cuenta_costo_gasto referencian cat_plan_cuentas).
-- ==========================================

DROP TABLE IF EXISTS tbl_item_composicion_insumos;
DROP TABLE IF EXISTS tbl_item_composicion_hh;
DROP TABLE IF EXISTS tbl_item_extension_servicio;
DROP TABLE IF EXISTS tbl_item_extension_producto;
DROP TABLE IF EXISTS tbl_productos_servicios;
DROP TABLE IF EXISTS cat_insumos_recursos;
DROP TABLE IF EXISTS cat_perfiles_hh;
DROP TABLE IF EXISTS cat_categorias_item;
DROP TABLE IF EXISTS cat_unidades_medida;
DROP TABLE IF EXISTS cat_tipos_item;

-- 1. CATÁLOGOS AUXILIARES
CREATE TABLE cat_tipos_item (
    id_tipo_item INT PRIMARY KEY,
    codigo VARCHAR(20) UNIQUE NOT NULL,
    nombre VARCHAR(50) NOT NULL
);

CREATE TABLE cat_unidades_medida (
    id_unidad_medida INT PRIMARY KEY,
    codigo VARCHAR(10) UNIQUE NOT NULL,
    nombre VARCHAR(50) NOT NULL
);

CREATE TABLE cat_categorias_item (
    id_categoria_item INT PRIMARY KEY,
    codigo VARCHAR(30) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL
);

CREATE TABLE cat_perfiles_hh (
    id_perfil_hh INT PRIMARY KEY,
    codigo VARCHAR(30) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    costo_hora_referencia DECIMAL(18,2) NOT NULL
);

CREATE TABLE cat_insumos_recursos (
    id_insumo INT PRIMARY KEY,
    codigo VARCHAR(30) UNIQUE NOT NULL,
    nombre VARCHAR(100) NOT NULL,
    costo_unitario_referencia DECIMAL(18,2) NOT NULL
);

-- 2. CABECERA MAESTRA UNIFICADA DE ÍTEMS
CREATE TABLE tbl_productos_servicios (
    id_item INT PRIMARY KEY,
    sku_codigo VARCHAR(50) UNIQUE NOT NULL,
    nombre VARCHAR(150) NOT NULL,
    descripcion VARCHAR(250),
    id_tipo_item INT NOT NULL,
    id_categoria_item INT NOT NULL,
    id_unidad_medida INT NOT NULL,
    precio_venta_base DECIMAL(18,2) NOT NULL,
    aplica_iva BIT NOT NULL DEFAULT 1,
    -- v3 (Control de Gestión): mapeo contable por ítem. Cada producto/
    -- servicio declara a qué cuenta de Ingreso se abona cuando se VENDE y
    -- a qué cuenta de Costo/Gasto se carga cuando se COMPRA. Ambas son
    -- NULL-ables: si el ítem no tiene mapeo propio, sp_registrar_asiento_*
    -- usa una cuenta "default" genérica (ver crear_modulo_contabilidad_
    -- transacciones.sql, cuentas 4.1.01.003 y 6.2.01.005) para no bloquear
    -- la contabilización automática mientras el catálogo se completa.
    id_cuenta_ingreso INT NULL,
    id_cuenta_costo_gasto INT NULL,
    -- v4/v6 (Costeo Directo por Flujo de Venta): determina cómo se calcula
    -- el costo real de venta de este ítem:
    --   COMPRADO_REVENTA -> (solo PRODUCTO) costo promedio ponderado (CPP)
    --                       del kardex (tbl_movimientos_inventario).
    --   FABRICADO        -> (solo PRODUCTO) MOD (tbl_item_composicion_hh)
    --                       + MPD a costo estándar de referencia
    --                       (tbl_item_composicion_insumos), más CIF
    --                       prorrateado al cierre (sp_prorratear_cif_
    --                       periodo). LIMITACIÓN Fase A: la MPD se aplica a
    --                       costo estándar (BOM), NO se consume contra un
    --                       kardex real de insumos (la compra de insumos no
    --                       está modelada de forma transaccional en este
    --                       esquema); ver limitación documentada en el
    --                       CHANGELOG v4.
    --   SERVICIO         -> (solo SERVICIO, v6) Honorarios (tbl_item_
    --                       composicion_hh, horas por perfil profesional) +
    --                       Insumos a costo estándar de referencia
    --                       (tbl_item_composicion_insumos), asociados en
    --                       forma directa a la venta del servicio. No
    --                       aplica CIF (los costos indirectos de
    --                       fabricación son exclusivos de producción).
    --   NULL             -> sin costeo directo automático (ítem legado o
    --                       aún no clasificado).
    modo_obtencion VARCHAR(20) NULL CHECK (modo_obtencion IN ('COMPRADO_REVENTA', 'FABRICADO', 'SERVICIO')),
    estado_activo BIT DEFAULT 1,
    created_at DATETIME DEFAULT GETDATE(),
    CONSTRAINT fk_item_tipo FOREIGN KEY (id_tipo_item) REFERENCES cat_tipos_item(id_tipo_item),
    CONSTRAINT fk_item_categoria FOREIGN KEY (id_categoria_item) REFERENCES cat_categorias_item(id_categoria_item),
    CONSTRAINT fk_item_unidad FOREIGN KEY (id_unidad_medida) REFERENCES cat_unidades_medida(id_unidad_medida),
    CONSTRAINT fk_item_cuenta_ingreso FOREIGN KEY (id_cuenta_ingreso) REFERENCES cat_plan_cuentas(id_cuenta),
    CONSTRAINT fk_item_cuenta_costo FOREIGN KEY (id_cuenta_costo_gasto) REFERENCES cat_plan_cuentas(id_cuenta)
);

-- 3. TABLAS DE EXTENSIÓN 1:1
CREATE TABLE tbl_item_extension_producto (
    id_item INT PRIMARY KEY,
    controla_stock BIT NOT NULL DEFAULT 1,
    stock_minimo DECIMAL(18,2),
    punto_reorden DECIMAL(18,2),
    peso_kg DECIMAL(18,2),
    volumen_m3 DECIMAL(18,2),
    CONSTRAINT fk_ext_prod_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE
);

CREATE TABLE tbl_item_extension_servicio (
    id_item INT PRIMARY KEY,
    modalidad_entrega VARCHAR(50),
    sla_horas_entrega INT,
    requiere_soporte_postventa BIT NOT NULL DEFAULT 0,
    CONSTRAINT fk_ext_serv_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE
);

-- 4. ESTRUCTURA DE COMPOSICIÓN DINÁMICA (BOM / CBS)
CREATE TABLE tbl_item_composicion_hh (
    id_composicion_hh INT PRIMARY KEY,
    id_item INT NOT NULL,
    id_perfil_hh INT NOT NULL,
    cantidad_horas DECIMAL(18,2) NOT NULL,
    CONSTRAINT fk_comp_hh_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE,
    CONSTRAINT fk_comp_hh_perfil FOREIGN KEY (id_perfil_hh) REFERENCES cat_perfiles_hh(id_perfil_hh)
);

CREATE TABLE tbl_item_composicion_insumos (
    id_composicion_insumo INT PRIMARY KEY,
    id_item INT NOT NULL,
    id_insumo INT NOT NULL,
    cantidad DECIMAL(18,2) NOT NULL,
    CONSTRAINT fk_comp_ins_item FOREIGN KEY (id_item) REFERENCES tbl_productos_servicios(id_item) ON DELETE CASCADE,
    CONSTRAINT fk_comp_ins_insumo FOREIGN KEY (id_insumo) REFERENCES cat_insumos_recursos(id_insumo)
);

-- 5. VISTA DE COSTEO AUTOMÁTICAMENTE CALCULADO
-- NOTA (corrección v2): la versión anterior unía en el mismo SELECT las
-- líneas de HH y las líneas de insumos de un mismo ítem mediante dos
-- LEFT JOIN encadenados. Cuando un ítem tenía N líneas de HH y M líneas
-- de insumos, el producto cartesiano generaba N*M filas antes del SUM(),
-- inflando ambos costos. Se agregan por separado en subconsultas y
-- luego se unen 1:1 por ítem.
GO
CREATE VIEW vw_productos_servicios_costeo AS
WITH costo_hh AS (
    SELECT ch.id_item, SUM(ch.cantidad_horas * pf.costo_hora_referencia) AS costo_total_hh
    FROM tbl_item_composicion_hh ch
    INNER JOIN cat_perfiles_hh pf ON ch.id_perfil_hh = pf.id_perfil_hh
    GROUP BY ch.id_item
),
costo_insumos AS (
    SELECT ci.id_item, SUM(ci.cantidad * ir.costo_unitario_referencia) AS costo_total_insumos
    FROM tbl_item_composicion_insumos ci
    INNER JOIN cat_insumos_recursos ir ON ci.id_insumo = ir.id_insumo
    GROUP BY ci.id_item
)
SELECT
    p.id_item,
    p.sku_codigo,
    p.nombre AS item_nombre,
    t.nombre AS tipo_item,
    p.precio_venta_base,
    ISNULL(hh.costo_total_hh, 0) AS costo_total_hh,
    ISNULL(ins.costo_total_insumos, 0) AS costo_total_insumos,
    ISNULL(hh.costo_total_hh, 0) + ISNULL(ins.costo_total_insumos, 0) AS costo_total_base,
    p.precio_venta_base - (ISNULL(hh.costo_total_hh, 0) + ISNULL(ins.costo_total_insumos, 0)) AS margen_contribucion_base
FROM tbl_productos_servicios p
INNER JOIN cat_tipos_item t ON p.id_tipo_item = t.id_tipo_item
LEFT JOIN costo_hh hh ON p.id_item = hh.id_item
LEFT JOIN costo_insumos ins ON p.id_item = ins.id_item;
GO
