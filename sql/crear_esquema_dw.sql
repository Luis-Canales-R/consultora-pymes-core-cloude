-- ====================================================================
-- Proyecto: Sistema RDBMS para PyMEs -- Plataforma de Control de Gestión
-- Objeto: Data Warehouse en modelo ESTRELLA -- Fase B (Capa 3: Core
--         Analítico y Linaje)
-- ====================================================================
-- PRERREQUISITO: todo el esquema transaccional (dbo) debe estar desplegado,
-- incluyendo v4 (Costeo Directo por Flujo de Venta): sql/crear_modulo_
-- inventario_costeo.sql y las cuentas CIF de sql/crear_modulo_contabilidad_
-- transacciones.sql.
--
-- DISEÑO (Capa 3 del framework de 4 capas del usuario: Origen/Ingesta ->
-- Transformación/Calidad -> Enriquecimiento/Negocio/Core Analítico y
-- Linaje -> Consumo/Gobierno):
--   - Esquema separado `dw` dentro de la misma base consultora_pymes_core
--     (mismo motor, esquema separado -- decisión explícita del usuario).
--   - Dimensiones de Tipo 2 (SCD, historizadas) desde v8: `dim_cuenta_
--     contable`, `dim_centro_costo`, `dim_tercero`, `dim_empleado` y
--     `dim_item` versionan cada vez que cambia alguno de sus atributos
--     (p. ej. un ítem que pasa de `COMPRADO_REVENTA` a `FABRICADO`), en
--     vez de sobrescribir el valor vigente (Tipo 1, hasta v7). Cada
--     dimensión tiene una clave surrogada propia (`sk_*`, PK real) y la
--     clave natural (`id_*`) queda como columna normal, repetida en cada
--     versión. `dim_tiempo` NO se historiza (es aditiva por naturaleza:
--     un día calendario no cambia de atributos).
--   - `fact_asientos_contables` es la tabla CENTRAL, con grano = 1 fila
--     por línea de `tbl_asientos_detalle` (la misma fuente que hoy
--     alimenta vw_balance_general / vw_estado_resultados). Es el punto
--     desde donde se deben poder reconstruir ambos reportes. Desde v8
--     guarda tanto la clave natural (`id_cuenta`/`id_centro_costo`,
--     degenerada, para filtrar por "estado actual") como la clave
--     surrogada (`sk_*`) de la VERSIÓN de la dimensión vigente al
--     momento del asiento (resuelta por fecha en la carga) -- esto es lo
--     que permite reportes point-in-time correctos (ver sp_cargar_dw.sql).
--   - `fact_margen_venta` es una tabla de hechos secundaria, con grano =
--     1 fila por línea de `tbl_ventas_detalle`, que expone el margen de
--     contribución (ingreso - costo directo) ya resuelto por línea de
--     venta, evitando que cada consumo (BI, reportes) tenga que
--     recalcular el costeo por flujo de venta de v4. También guarda
--     claves naturales + surrogadas (v8) por el mismo motivo.
--   - Estrategia de carga: los HECHOS siguen en FULL REFRESH (DELETE +
--     reload) en cada ejecución de sp_cargar_dw_completo; las
--     DIMENSIONES (desde v8) ya NO se borran -- se versionan (INSERT de
--     una nueva fila + cierre de la fila vigente anterior) para preservar
--     el historial. Una carga incremental de los HECHOS (solo deltas
--     desde la última corrida) queda documentada como mejora futura.
-- ====================================================================

USE consultora_pymes_core;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
    EXEC('CREATE SCHEMA dw');
GO

------------------------------------------------------------------------
-- DIMENSIONES
------------------------------------------------------------------------

DROP TABLE IF EXISTS dw.fact_margen_venta;
DROP TABLE IF EXISTS dw.fact_asientos_contables;
DROP TABLE IF EXISTS dw.dim_tiempo;
DROP TABLE IF EXISTS dw.dim_cuenta_contable;
DROP TABLE IF EXISTS dw.dim_centro_costo;
DROP TABLE IF EXISTS dw.dim_tercero;
DROP TABLE IF EXISTS dw.dim_empleado;
DROP TABLE IF EXISTS dw.dim_item;
DROP TABLE IF EXISTS dw.tbl_control_carga_incremental; -- v9
GO

-- dim_tiempo: una fila por día calendario. id_fecha en formato AAAAMMDD
-- (entero), convención estándar de modelado dimensional para poder
-- filtrar/ordenar sin castear fechas.
CREATE TABLE dw.dim_tiempo (
    id_fecha INT PRIMARY KEY,              -- AAAAMMDD
    fecha DATE NOT NULL,
    anio INT NOT NULL,
    mes INT NOT NULL,
    nombre_mes VARCHAR(20) NOT NULL,
    dia INT NOT NULL,
    nombre_dia VARCHAR(20) NOT NULL,
    trimestre INT NOT NULL,
    periodo_contable VARCHAR(7) NOT NULL,  -- 'AAAA-MM', calza con tbl_asientos_cabecera.periodo_contable
    es_fin_de_semana BIT NOT NULL
);
GO

-- dim_cuenta_contable: espejo de cat_plan_cuentas. v8 (SCD Tipo 2): la PK
-- pasa a ser la clave surrogada sk_cuenta_contable; id_cuenta (clave
-- natural) puede repetirse en varias filas -- una por versión histórica.
CREATE TABLE dw.dim_cuenta_contable (
    sk_cuenta_contable INT IDENTITY(1,1) PRIMARY KEY, -- v8: clave surrogada
    id_cuenta INT NOT NULL,                            -- clave natural (dbo.cat_plan_cuentas.id_cuenta)
    codigo_cuenta VARCHAR(20) NOT NULL,
    nombre_cuenta VARCHAR(150) NOT NULL,
    nivel INT NOT NULL,
    id_cuenta_padre INT NULL,
    naturaleza VARCHAR(10) NOT NULL,
    tipo_cuenta VARCHAR(20) NOT NULL,      -- ACTIVO/PASIVO/PATRIMONIO/INGRESO/COSTO/GASTO
    es_imputable BIT NOT NULL,
    estado_activo BIT NOT NULL,
    fecha_inicio_vigencia DATE NOT NULL,   -- v8 (SCD Tipo 2)
    fecha_fin_vigencia DATE NULL,          -- v8: NULL = versión vigente
    es_vigente BIT NOT NULL                -- v8: redundante con fecha_fin_vigencia IS NULL, para índice/legibilidad
);
GO
CREATE INDEX IX_dim_cuenta_contable_natural ON dw.dim_cuenta_contable (id_cuenta, fecha_inicio_vigencia, fecha_fin_vigencia);
CREATE UNIQUE INDEX UX_dim_cuenta_contable_vigente ON dw.dim_cuenta_contable (id_cuenta) WHERE es_vigente = 1;
GO

-- dim_centro_costo: v8 (SCD Tipo 2), mismo patrón que dim_cuenta_contable.
CREATE TABLE dw.dim_centro_costo (
    sk_centro_costo INT IDENTITY(1,1) PRIMARY KEY,
    id_centro_costo INT NOT NULL,
    codigo_cc VARCHAR(30) NOT NULL,
    nombre_cc VARCHAR(150) NOT NULL,
    nivel INT NOT NULL,
    id_centro_padre INT NULL,              -- v8: se mantiene como referencia a la clave NATURAL del padre (no se encadena a un sk de padre, por simplicidad)
    es_activo BIT NOT NULL,
    fecha_inicio_vigencia DATE NOT NULL,
    fecha_fin_vigencia DATE NULL,
    es_vigente BIT NOT NULL
);
GO
CREATE INDEX IX_dim_centro_costo_natural ON dw.dim_centro_costo (id_centro_costo, fecha_inicio_vigencia, fecha_fin_vigencia);
CREATE UNIQUE INDEX UX_dim_centro_costo_vigente ON dw.dim_centro_costo (id_centro_costo) WHERE es_vigente = 1;
GO

-- dim_tercero: v8 (SCD Tipo 2), mismo patrón.
CREATE TABLE dw.dim_tercero (
    sk_tercero INT IDENTITY(1,1) PRIMARY KEY,
    id_tercero INT NOT NULL,
    codigo_tercero VARCHAR(50) NOT NULL,
    razon_social VARCHAR(200) NOT NULL,
    nombre_fantasia VARCHAR(150) NULL,
    rut_dni VARCHAR(20) NOT NULL,
    comuna_ciudad VARCHAR(100) NULL,
    es_cliente BIT NOT NULL,
    es_proveedor BIT NOT NULL,
    estado_activo BIT NOT NULL,
    fecha_inicio_vigencia DATE NOT NULL,
    fecha_fin_vigencia DATE NULL,
    es_vigente BIT NOT NULL
);
GO
CREATE INDEX IX_dim_tercero_natural ON dw.dim_tercero (id_tercero, fecha_inicio_vigencia, fecha_fin_vigencia);
CREATE UNIQUE INDEX UX_dim_tercero_vigente ON dw.dim_tercero (id_tercero) WHERE es_vigente = 1;
GO

-- dim_empleado: v8 (SCD Tipo 2), mismo patrón.
CREATE TABLE dw.dim_empleado (
    sk_empleado INT IDENTITY(1,1) PRIMARY KEY,
    id_empleado INT NOT NULL,
    rut_dni VARCHAR(20) NOT NULL,
    nombre_completo VARCHAR(150) NOT NULL,
    cargo VARCHAR(100) NULL,
    id_centro_costo INT NULL,              -- v8: referencia a la clave NATURAL del centro de costo (no a su sk)
    es_activo BIT NOT NULL,
    fecha_inicio_vigencia DATE NOT NULL,
    fecha_fin_vigencia DATE NULL,
    es_vigente BIT NOT NULL
);
GO
CREATE INDEX IX_dim_empleado_natural ON dw.dim_empleado (id_empleado, fecha_inicio_vigencia, fecha_fin_vigencia);
CREATE UNIQUE INDEX UX_dim_empleado_vigente ON dw.dim_empleado (id_empleado) WHERE es_vigente = 1;
GO

-- dim_item: espejo de tbl_productos_servicios, incluyendo modo_obtencion
-- (v4) para poder segmentar el margen por flujo de venta sin volver al
-- OLTP. v8 (SCD Tipo 2) -- es el caso motivador de esta historización: un
-- ítem puede cambiar de modo_obtencion en el tiempo (p. ej. de
-- COMPRADO_REVENTA a FABRICADO) y las ventas históricas deben seguir
-- reportando el modo_obtencion vigente AL MOMENTO de cada venta, no el
-- actual.
CREATE TABLE dw.dim_item (
    sk_item INT IDENTITY(1,1) PRIMARY KEY,
    id_item INT NOT NULL,
    sku_codigo VARCHAR(50) NOT NULL,
    nombre VARCHAR(150) NOT NULL,
    tipo_item VARCHAR(20) NOT NULL,        -- PRODUCTO | SERVICIO (desde cat_tipos_item)
    categoria_item VARCHAR(100) NULL,
    modo_obtencion VARCHAR(20) NULL,       -- v4/v6: COMPRADO_REVENTA | FABRICADO | SERVICIO | NULL
    precio_venta_base DECIMAL(18,2) NOT NULL,
    estado_activo BIT NOT NULL,
    fecha_inicio_vigencia DATE NOT NULL,
    fecha_fin_vigencia DATE NULL,
    es_vigente BIT NOT NULL
);
GO
CREATE INDEX IX_dim_item_natural ON dw.dim_item (id_item, fecha_inicio_vigencia, fecha_fin_vigencia);
CREATE UNIQUE INDEX UX_dim_item_vigente ON dw.dim_item (id_item) WHERE es_vigente = 1;
GO

------------------------------------------------------------------------
-- TABLA DE HECHOS CENTRAL: fact_asientos_contables
-- Grano: 1 fila = 1 línea de tbl_asientos_detalle. Desde aquí se debe
-- poder reconstruir Balance General y Estado de Resultados.
------------------------------------------------------------------------
CREATE TABLE dw.fact_asientos_contables (
    id_asiento_detalle INT PRIMARY KEY,    -- = dbo.tbl_asientos_detalle.id_asiento_detalle (clave natural)
    id_asiento INT NOT NULL,               -- degenerada: cabecera del asiento
    numero_asiento INT NOT NULL,
    id_transaccion INT NULL,               -- degenerada: documento comercial de origen, si existe
    id_fecha INT NOT NULL,
    id_cuenta INT NOT NULL,                -- v8: clave NATURAL de la cuenta (degenerada; para filtrar/agrupar por "estado actual", ver vw_dw_balance_general)
    sk_cuenta_contable INT NOT NULL,       -- v8 (SCD Tipo 2): versión de la cuenta vigente AL MOMENTO del asiento (point-in-time)
    id_centro_costo INT NULL,              -- v8: clave NATURAL del centro de costo (degenerada)
    sk_centro_costo INT NULL,              -- v8 (SCD Tipo 2): versión del centro de costo vigente al momento del asiento
    periodo_contable VARCHAR(7) NOT NULL,
    glosa_general VARCHAR(250) NOT NULL,
    glosa_detalle VARCHAR(250) NULL,
    debe DECIMAL(18,2) NOT NULL,
    haber DECIMAL(18,2) NOT NULL,
    monto_neto DECIMAL(18,2) NOT NULL,     -- debe - haber (signo útil para sumar directo por tipo_cuenta)
    fecha_carga DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT fk_fact_asientos_fecha FOREIGN KEY (id_fecha) REFERENCES dw.dim_tiempo(id_fecha),
    CONSTRAINT fk_fact_asientos_sk_cuenta FOREIGN KEY (sk_cuenta_contable) REFERENCES dw.dim_cuenta_contable(sk_cuenta_contable),
    CONSTRAINT fk_fact_asientos_sk_cc FOREIGN KEY (sk_centro_costo) REFERENCES dw.dim_centro_costo(sk_centro_costo)
);
GO

CREATE INDEX IX_fact_asientos_fecha ON dw.fact_asientos_contables (id_fecha);
CREATE INDEX IX_fact_asientos_cuenta ON dw.fact_asientos_contables (id_cuenta);
CREATE INDEX IX_fact_asientos_sk_cuenta ON dw.fact_asientos_contables (sk_cuenta_contable); -- v8
CREATE INDEX IX_fact_asientos_periodo ON dw.fact_asientos_contables (periodo_contable);
CREATE INDEX IX_fact_asientos_cc ON dw.fact_asientos_contables (id_centro_costo);
CREATE INDEX IX_fact_asientos_sk_cc ON dw.fact_asientos_contables (sk_centro_costo); -- v8
GO

------------------------------------------------------------------------
-- TABLA DE HECHOS SECUNDARIA: fact_margen_venta
-- Grano: 1 fila = 1 línea de tbl_ventas_detalle. Expone el costo directo
-- (v4) y el margen de contribución ya resuelto por línea de venta.
------------------------------------------------------------------------
CREATE TABLE dw.fact_margen_venta (
    id_venta_detalle INT PRIMARY KEY,      -- = dbo.tbl_ventas_detalle.id_venta_detalle
    id_venta_devengada INT NOT NULL,       -- degenerada: cabecera de la venta
    folio_factura VARCHAR(50) NOT NULL,
    id_fecha INT NOT NULL,
    id_item INT NOT NULL,                  -- v8: clave NATURAL del ítem (degenerada)
    sk_item INT NOT NULL,                  -- v8 (SCD Tipo 2): versión del ítem vigente al momento de la venta
    id_tercero INT NOT NULL,               -- v8: clave NATURAL del cliente (degenerada)
    sk_tercero INT NOT NULL,               -- v8 (SCD Tipo 2): versión del tercero vigente al momento de la venta
    id_centro_costo INT NULL,              -- v8: clave NATURAL (degenerada)
    sk_centro_costo INT NULL,              -- v8 (SCD Tipo 2)
    id_empleado INT NULL,                  -- v8: clave NATURAL (degenerada)
    sk_empleado INT NULL,                  -- v8 (SCD Tipo 2)
    modo_obtencion VARCHAR(20) NULL,       -- denormalizado desde dbo (OLTP, estado actual) para agrupar rápido sin join; para el valor point-in-time use dim_item vía sk_item
    cantidad DECIMAL(18,4) NOT NULL,
    precio_unitario DECIMAL(18,2) NOT NULL,
    ingreso_neto DECIMAL(18,2) NOT NULL,
    costo_directo DECIMAL(18,2) NOT NULL,  -- CPP*cantidad (COMPRADO_REVENTA) | MOD+MPD real (FABRICADO/SERVICIO, v7) | 0 (sin clasificar)
    margen_contribucion DECIMAL(18,2) NOT NULL, -- ingreso_neto - costo_directo
    fecha_carga DATETIME NOT NULL DEFAULT GETDATE(),
    CONSTRAINT fk_fact_margen_fecha FOREIGN KEY (id_fecha) REFERENCES dw.dim_tiempo(id_fecha),
    CONSTRAINT fk_fact_margen_sk_item FOREIGN KEY (sk_item) REFERENCES dw.dim_item(sk_item),
    CONSTRAINT fk_fact_margen_sk_tercero FOREIGN KEY (sk_tercero) REFERENCES dw.dim_tercero(sk_tercero),
    CONSTRAINT fk_fact_margen_sk_cc FOREIGN KEY (sk_centro_costo) REFERENCES dw.dim_centro_costo(sk_centro_costo),
    CONSTRAINT fk_fact_margen_sk_empleado FOREIGN KEY (sk_empleado) REFERENCES dw.dim_empleado(sk_empleado)
);
GO

CREATE INDEX IX_fact_margen_fecha ON dw.fact_margen_venta (id_fecha);
CREATE INDEX IX_fact_margen_item ON dw.fact_margen_venta (id_item);
CREATE INDEX IX_fact_margen_sk_item ON dw.fact_margen_venta (sk_item); -- v8
CREATE INDEX IX_fact_margen_cc ON dw.fact_margen_venta (id_centro_costo);
GO

------------------------------------------------------------------------
-- dw.tbl_control_carga_incremental (v9): guarda, por cada tabla de
-- hechos, la "alta marca" (high-water mark) de la última clave natural
-- ya cargada -- la carga incremental (sql/sp_cargar_dw.sql) solo trae
-- filas de dbo con clave natural MAYOR a esta marca. Funciona porque
-- tbl_asientos_detalle y tbl_ventas_detalle son de solo-inserción: nunca
-- se les hace UPDATE ni DELETE en todo este esquema (las correcciones
-- contables se registran como asientos nuevos, no editando uno viejo) --
-- ver la limitación de esta suposición en CHANGELOG.md (v9).
-- Nota: igual que el resto de este script, esta tabla SÍ se recrea vacía
-- cada vez que se vuelve a ejecutar crear_esquema_dw.sql (es un script de
-- despliegue desde cero) -- lo que NUNCA se borra es la marca durante la
-- OPERACIÓN normal (ejecuciones repetidas de dw.sp_cargar_dw_incremental).
------------------------------------------------------------------------
CREATE TABLE dw.tbl_control_carga_incremental (
    nombre_hecho VARCHAR(60) PRIMARY KEY,   -- 'fact_asientos_contables' | 'fact_margen_venta'
    ultima_clave_cargada INT NOT NULL,      -- MAX(id_asiento_detalle) / MAX(id_venta_detalle) ya cargado en el DW
    fecha_ultima_carga DATETIME NOT NULL DEFAULT GETDATE()
);
GO

PRINT 'Esquema dw (Data Warehouse en estrella) creado exitosamente.';
GO
