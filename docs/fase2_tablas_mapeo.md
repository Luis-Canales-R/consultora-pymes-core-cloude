# Módulo: Tablas de Mapeo y Homologación (Fase 2)

## Objetivo
Resolver la "heterogeneidad de datos" típica de las PyMEs (nombres de clientes escritos de múltiples formas, faltas de ortografía o descripciones libres de productos) antes de que ingresen al Core RDBMS transaccional. Estas tablas actúan como diccionarios de traducción automáticos, permitiendo homologar las planillas de Excel hacia los IDs canónicos de la Fase 1.

## Estructura de Tablas de Mapeo

1. **`map_clientes`:**
   * **Propósito:** Relaciona el string exacto que el cliente utiliza en sus planillas (`nombre_informal_excel`) con el `id_tercero` oficial y normalizado de `tbl_terceros`.
   * **Campos Principales:**
     * `id_map_cliente` (PK)
     * `nombre_informal_excel` (UNIQUE, NOT NULL)
     * `id_tercero_oficial` (FK hacia `tbl_terceros`)

2. **`map_productos`:**
   * **Propósito:** Cruza las descripciones libres de ítems utilizadas comercialmente en las plantillas de venta o compra (`descripcion_libre_excel`) con el `id_item` (SKU) canónico de `tbl_productos_servicios`.
   * **Campos Principales:**
     * `id_map_producto` (PK)
     * `descripcion_libre_excel` (UNIQUE, NOT NULL)
     * `id_item_oficial` (FK hacia `tbl_productos_servicios`)

3. **`map_insumos` (v7 — Kardex Real de Insumos):**
   * **Propósito:** Cruza las descripciones libres de insumos/materias primas utilizadas en la pestaña `Compras_y_Gastos` (`descripcion_libre_excel`) con el `id_insumo` canónico de `cat_insumos_recursos`. Una fila de `Compras_y_Gastos` homologa contra `map_productos` (compra de un ítem) **o** contra esta tabla (compra de un insumo) — nunca ambas; `Ventas_Devengadas` solo homologa contra `map_productos`, porque un insumo no se vende directamente.
   * **Campos Principales:**
     * `id_map_insumo` (PK)
     * `descripcion_libre_excel` (UNIQUE, NOT NULL)
     * `id_insumo_oficial` (FK hacia `cat_insumos_recursos`)