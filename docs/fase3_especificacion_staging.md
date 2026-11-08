# Especificación Técnica: Tabla de Staging - Fase 3 (`tbl_staging_carga`)

## 1. Objetivo
La tabla `tbl_staging_carga` actúa como el área de transferencia temporal (*staging area*) para almacenar los registros sin procesar extraídos de las **tres pestañas operativas** de la plantilla Excel (`Ventas_Devengadas`, `Compras_y_Gastos`, `Movimientos_Caja`) antes de aplicar las validaciones cruzadas del motor ETL.

## 2. Principio de diseño: columnas crudas, no tipadas
Todas las columnas de negocio (fecha, cantidad, montos) se almacenan como `VARCHAR`, **no** como `DATE` o `DECIMAL`. Si se tipara la columna, SQL Server rechazaría el `INSERT` completo apenas un valor viniera mal formateado desde el Excel, y ese error nunca llegaría a registrarse en `tbl_log_errores_etl`. Guardar el valor crudo permite que sea `sp_procesar_etl_fase3` quien decida si el dato es válido y, si no lo es, quién lo registre con detalle.

## 3. Estructura de Campos
* `id_staging` (INT IDENTITY, PK).
* `nombre_archivo` (VARCHAR(150)): identifica la corrida de carga; permite aislar un archivo de otro sin necesidad de truncar la tabla.
* `pestana_origen` (VARCHAR(50)): `Ventas_Devengadas` | `Compras_y_Gastos` | `Movimientos_Caja`.
* `numero_fila` (INT): número de línea en la hoja Excel origen.
* `folio_documento_raw` (VARCHAR(50)): Folio Factura / Folio OC (Ventas y Compras).
* `tercero_informal_raw` (VARCHAR(150)): Cliente o Proveedor, a homologar contra `map_clientes`.
* `item_informal_raw` (VARCHAR(150)): Ítem/Servicio o Insumo, a homologar contra `map_productos`.
* `cantidad_raw` / `precio_unitario_raw` (VARCHAR(50)): valores crudos de Ventas y Compras.
* `estado_documento_raw` (VARCHAR(30)): Estado Venta / Estado OC.
* `cuenta_bancaria_raw` / `tipo_flujo_raw` / `monto_absoluto_raw` (VARCHAR): exclusivos de `Movimientos_Caja`.
* `fecha_raw` (VARCHAR(20)): se exige formato `AAAA-MM-DD`, validado por el SP.
* `monto_total_raw` (VARCHAR(50)): monto total informado (si la plantilla lo incluye como columna independiente).
* `glosa` (VARCHAR(250)): glosa descriptiva (obligatoria en `Movimientos_Caja`).
* `estado_carga` (VARCHAR(30)): `PENDIENTE` (default) | `CARGADO` | `RECHAZADO`.
* `fecha_proceso` / `created_at` (DATETIME).

## 4. Ciclo de vida de una fila
`PENDIENTE` → (validaciones de `sp_procesar_etl_fase3`) → `CARGADO` (si pasó todo e insertó en el Core) **o** `RECHAZADO` (si alguna validación falló; el detalle queda en `tbl_log_errores_etl`). Una fila `RECHAZADO` vuelve a `PENDIENTE` automáticamente la próxima vez que se ejecuta el SP sobre su mismo `nombre_archivo`, para permitir reprocesos tras corregir el dato de origen.
