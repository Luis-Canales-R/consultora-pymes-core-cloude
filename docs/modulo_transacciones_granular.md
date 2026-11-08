# Módulo: Transacciones Granulares (Compras, Ventas y Tesorería)

## Objetivo
Desplegar la capa transaccional específica y granular que detalla el ciclo comercial operativo de la PyME, conectando de forma directa las entidades maestras (Terceros y Productos/Servicios) con el flujo operativo y financiero, manteniendo un diseño estricto en Tercera Forma Normal (3FN).

## Arquitectura de Tablas

1. **Gestión de Compras:**
   * `tbl_ordenes_compra`: Cabecera de compras a proveedores con estados de control (`BORRADOR`, `APROBADA`, `RECIBIDA`, `ANULADA`).
   * `tbl_compras_detalle`: Detalle por ítem vinculando los productos o insumos y calculando subtotales limpios.

2. **Gestión de Ventas:**
   * `tbl_ventas_devengadas`: Registro de facturas de venta o devengos hacia clientes/sponsors.
   * `tbl_ventas_detalle`: Detalle de líneas de venta por ítem comercial.

3. **Capa de Liquidez (Tesorería):**
   * `tbl_movimientos_caja`: Registro de flujos de efectivo. Implementa el patrón de diseño financiero de **montos absolutos acompañados de atributos direccionales explícitos** (`INGRESO`, `EGRESO`, `TRASPASO_HASTA`, `TRASPASO_DESDE`) en lugar de almacenar números negativos, asegurando claridad absoluta en los movimientos bancarios.