# Módulo: Productos, Servicios y Composición de Costos (BOM / CBS)

## Objetivo
Estandarizar el catálogo de ítems de la consultora y sus clientes PyME, permitiendo gestionar tanto bienes tangibles (con control de inventario y logística) como servicios intangibles (con asignación de perfiles profesionales y costos de horas hombre).

## Arquitectura y Patrones de Diseño
1. **Cabecera Unificada (`tbl_productos_servicios`)**: Contiene los atributos comunes de cualquier producto o servicio (SKU, nombre, tipo, categoría, unidad de medida y precio base).
2. **Patrón de Extensión ERP (Tablas 1:1)**:
   - `tbl_item_extension_producto`: Atributos logísticos y de inventario (stock mínimo, peso, dimensiones).
   - `tbl_item_extension_servicio`: Atributos operativos (modalidad de entrega, SLA, soporte).
3. **Estructura BOM / CBS (Bill of Materials / Cost Breakdown Structure)**:
   - `tbl_item_composicion_hh`: Define las horas requeridas por perfil profesional (`cat_perfiles_hh`) para ejecutar un servicio.
   - `tbl_item_composicion_insumos`: Define los insumos o materiales necesarios (`cat_insumos_recursos`).

## Vista Financiera de Costeo (`vw_productos_servicios_costeo`)
Permite calcular en tiempo real el costo total base y el margen de contribución de cada producto o servicio a partir de sus componentes atómicos.

## Costeo Directo por Flujo de Venta (v4 / v6 / v7)
`tbl_productos_servicios.modo_obtencion` clasifica cada ítem según cómo se determina su costo real al venderse:

| `modo_obtencion` | Mecanismo de costeo | Cuentas (Debe / Haber) | Dónde se implementa |
|---|---|---|---|
| `COMPRADO_REVENTA` (PRODUCTO) | Costo Promedio Ponderado (CPP), vía el kardex `tbl_movimientos_inventario` (ver `docs/modulo_inventario_costeo.md`) | Debe Costo/Gasto del ítem (fallback `5111`) / Haber `1141` Inventario | `sp_registrar_movimiento_inventario`, llamado desde `sp_procesar_etl_fase3` y `sp_procesar_venta_externa` |
| `FABRICADO` (PRODUCTO) | Mano de Obra Directa a costo estándar (`tbl_item_composicion_hh`) + Materia Prima Directa a costo **real de kardex** (v7: `tbl_item_composicion_insumos` define QUÉ insumos y en qué cantidad, pero el COSTO de cada salida es el CPP vigente en `tbl_movimientos_inventario` al momento de la venta), más CIF prorrateado al cierre | Debe Costo/Gasto del ítem (fallback `5111`) / Haber `2131` (MOD) + Haber `2123` (MPD) | `sp_registrar_movimiento_inventario` (MPD) + cálculo aritmético (MOD) en `sp_procesar_etl_fase3` / `sp_procesar_venta_externa`; absorción de CIF en `sp_prorratear_cif_periodo` |
| `SERVICIO` (v6) | Honorarios a costo estándar (`tbl_item_composicion_hh`) + Insumos a costo **real de kardex** (v7, misma mecánica que la MPD de `FABRICADO`) — misma fuente BOM para definir componentes, sin CIF | Debe Costo/Gasto del ítem (fallback `5113` Honorarios/Servicios Subcontratados) / Haber `2125` (Honorarios) + Haber `2124` (Insumos) | `sp_registrar_movimiento_inventario` (Insumos) + cálculo aritmético (Honorarios) en `sp_procesar_etl_fase3` / `sp_procesar_venta_externa` |
| `NULL` (sin clasificar) | Sin leg de costo directo automático | — | — |

**v7 — Kardex Real de Insumos**: la compra de un insumo se homologa vía `map_insumos` y se registra en `tbl_compras_detalle.id_insumo` (antes solo existía `id_item`), generando una ENTRADA a kardex (cuenta `1143 Inventario de Insumos y Materias Primas`). Al venderse un `FABRICADO`/`SERVICIO`, cada componente de insumo del BOM se consume como una SALIDA de kardex a su CPP vigente — por lo que la venta **fallará con "stock insuficiente"** si no se compró insumo suficiente de antemano. Ver `CHANGELOG.md` (v7) para el detalle.

**Limitaciones que permanecen documentadas**:
- Desde **v10**, `sp_prorratear_cif_periodo` prorratea el CIF sobre la base de MOD a costo estándar + MPD a costo **real de kardex** (antes, hasta v9, ambos componentes usaban costo estándar) — ver `CHANGELOG.md` (v10).
- Los Honorarios de `SERVICIO` y el MOD de `FABRICADO` se calculan sobre horas estándar del BOM (`tbl_item_composicion_hh`), no sobre horas realmente registradas para esa venta puntual (no hay registro de horas trabajadas por transacción en este esquema).
- El kardex solo referencia `id_venta_devengada` (no `id_venta_detalle`): si una venta tiene 2+ líneas `FABRICADO`/`SERVICIO` que comparten un insumo, `dw.fact_margen_venta` no puede discriminar cuánto consumió cada línea (ver `CHANGELOG.md` v7).