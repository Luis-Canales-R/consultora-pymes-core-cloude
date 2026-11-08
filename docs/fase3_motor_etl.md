# Especificación Técnica: Motor ETL y Validación Automática (Fase 3)

## 1. Propósito y Alcance
El Motor ETL de la Fase 3 automatiza la lectura, la validación de reglas de negocio complejas y la carga masiva de los datos contenidos en `plantilla_captura_estandarizada_fase2.xlsx` hacia el Core RDBMS. Su diseño prioriza la tolerancia a fallos mediante una bitácora centralizada de errores para garantizar que ningún registro corrupto, huérfano o mal formateado ingrese al sistema financiero.

---

## 2. Flujo de Procesamiento y Validación

1. **Lectura y Parsing Iterativo:** El motor procesa de forma estructurada las tres pestañas operativas (`Ventas_Devengadas`, `Compras_y_Gastos`, `Movimientos_Caja`).
2. **Validaciones Previas de Calidad (Data Quality Check):**
   * **Integridad de Formato Estricto:** Validación de cadenas de fecha bajo el estándar `AAAA-MM-DD` y campos numéricos estrictamente mayores a cero (`> 0`).
   * **Homologación de Entidades (Lookups):** Cruce automático contra las tablas `map_clientes` y `map_productos` definidas en la Fase 2.
3. **Gestión de Excepciones y Auditoría:**
   * Si se detecta un error de formato, un valor negativo no permitido o un cliente/producto no homologado, la fila es rechazada de inmediato, omitiendo la inserción en el Core e insertando un registro detallado en la tabla de auditoría `tbl_log_errores_etl`.
   * Las filas que **sí** superan todas las validaciones de la corrida se insertan al Core dentro de una única transacción atómica (`BEGIN TRANSACTION` / `COMMIT`); un error inesperado durante la inserción revierte toda la carga de esa corrida (`ROLLBACK`). El rechazo de una fila puntual por regla de negocio no bloquea la carga del resto de filas válidas del mismo archivo.

---

## 3. Estructura de Auditoría (`tbl_log_errores_etl`)
* Registra el archivo, la pestaña, el número de fila, el tipo de error y un mensaje descriptivo para facilitar la corrección operativa por parte de las áreas de negocio.