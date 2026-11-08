# Documentación Técnica: Lógica ETL y Procesamiento de Transición (Fase 2)

## Objetivo
Definir el mecanismo mediante el cual los datos operativos provenientes de las plantillas de Excel de las PyMEs se validan, cruzan a través de las tablas de homologación (`map_clientes`, `map_productos`) y se insertan de forma íntegra en el Core RDBMS transaccional (Fase 1).

---

## 1. Flujo Lógico del Procesamiento (ETL)

1. **Ingesta de Datos Estructurados:** Los registros de las planillas unificadas se procesan mediante procedimientos almacenados en SQL Server.
2. **Homologación Automática (Lookup):**
   * El nombre informal del cliente (`nombre_informal_excel`) se busca en `map_clientes` para obtener el `id_tercero_oficial`. Si no existe, el motor rechaza el lote para evitar datos huérfanos.
   * La descripción del producto (`descripcion_libre_excel`) se cruza con `map_productos` para recuperar el `id_item_oficial` canónico.
3. **Inyección Transaccional al Core RDBMS:** 
   * Las transacciones se ejecutan bajo bloques `BEGIN TRANSACTION` / `COMMIT` / `ROLLBACK` para asegurar la atomicidad y evitar registros parciales ante errores de mapeo.