# Especificación Técnica: Procedimiento ETL - Fase 3 (`sp_procesar_etl_fase3`)

## 1. Objetivo
El Stored Procedure `sp_procesar_etl_fase3` centraliza la lógica de control transaccional para la ingesta de las planillas operativas, ejecutando las validaciones cruzadas **y, si una fila las supera todas, insertándola en el Core RDBMS** dentro de la misma transacción atómica.

## 2. Parámetros de Entrada
* `@nombre_archivo` (VARCHAR(150)): Identificador del archivo Excel origen procesado en la sesión de carga. Acota todas las operaciones (limpieza de errores previos, validación y carga) a ese archivo.
* `@pestana_origen` (VARCHAR(50), opcional): Nombre de la pestaña a procesar (`Ventas_Devengadas`, `Compras_y_Gastos` o `Movimientos_Caja`). Si se omite (`NULL`), el procedimiento procesa las tres pestañas presentes para ese archivo en una sola ejecución.

## 3. Reglas de Validación Implementadas
| Regla | Pestañas | `tipo_error` |
|---|---|---|
| Formato de fecha `AAAA-MM-DD` | Las 3 | `FORMATO_FECHA_INVALIDO` |
| Cliente/Proveedor homologado en `map_clientes` | Ventas, Compras | `CLIENTE_NO_HOMOLOGADO` |
| Ítem/Insumo homologado en `map_productos` | Ventas, Compras | `ITEM_NO_HOMOLOGADO` |
| Cantidad numérica y > 0 | Ventas, Compras | `CANTIDAD_INVALIDA` |
| Precio unitario numérico y ≥ 0 | Ventas, Compras | `PRECIO_INVALIDO` |
| Folio informado | Ventas, Compras | `FOLIO_VACIO` |
| Estado dentro del dominio permitido | Ventas, Compras | `ESTADO_INVALIDO` |
| Cuenta bancaria existente en `cat_plan_cuentas` | Caja | `CUENTA_BANCARIA_NO_EXISTE` |
| Tipo de flujo dentro del dominio permitido | Caja | `TIPO_FLUJO_INVALIDO` |
| Monto absoluto numérico y > 0 | Caja | `MONTO_INVALIDO` |
| Glosa informada | Caja | `GLOSA_VACIA` |

## 4. Manejo de Errores y Auditoría
Cualquier inconsistencia detectada genera automáticamente una inserción en la tabla de auditoría `tbl_log_errores_etl` detallando el archivo, la pestaña, la fila y un mensaje descriptivo. La fila correspondiente en `tbl_staging_carga` queda marcada como `RECHAZADO` y no se propaga al Core.

## 5. Carga al Core
Las filas que no generaron ningún error quedan en estado `PENDIENTE` tras la fase de validación y se procesan así:
* **`Ventas_Devengadas`**: se agrupan por folio para crear (si no existe) la cabecera en `tbl_ventas_devengadas` (montos neto/IVA/total calculados según `aplica_iva` del ítem homologado) y se inserta el detalle en `tbl_ventas_detalle`.
* **`Compras_y_Gastos`**: análogo, hacia `tbl_ordenes_compra` y `tbl_compras_detalle`.
* **`Movimientos_Caja`**: inserción directa (sin cabecera) en `tbl_movimientos_caja`, resolviendo `id_cuenta_bancaria` contra `cat_plan_cuentas.codigo_cuenta` y, si aplica, `id_tercero` contra `map_clientes`.

Toda la carga al Core se ejecuta dentro de un único `BEGIN TRANSACTION / COMMIT`; si cualquier paso falla, se hace `ROLLBACK` completo y el error se eleva con `RAISERROR`. Al finalizar, las filas insertadas con éxito quedan marcadas `CARGADO` en `tbl_staging_carga`.
