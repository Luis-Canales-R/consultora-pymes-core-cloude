# Manual de Operación e Instructivo Técnico: Fase 2 (Interfaz de Transición y Carga Homologada)

## 1. Propósito y Alcance del Manual
Este documento describe la arquitectura, los controles de integridad y el procedimiento operativo de la **Fase 2** del sistema RDBMS para PyMEs. Su objetivo es asegurar que la captura manual de datos en planillas Excel se realice bajo estándares estrictos de validación, evitando la inserción de registros huérfanos o mal formateados antes de su carga en el Core RDBMS mediante los procedimientos almacenados (ETL).

---

## 2. Arquitectura de Componentes (Docs-as-Code)
La Fase 2 se compone de los siguientes artefactos versionados en el repositorio Git del proyecto:

* **Modelado de Datos (`dbml/fase2_tablas_mapeo.dbml`):** Definición arquitectónica de las tablas de homologación.
* **Scripts DDL (`sql/crear_tablas_mapeo.sql`):** Creación de las tablas `map_clientes` y `map_productos` en SQL Server.
* **Lógica ETL y Stored Procedures (`sql/sp_procesar_transaccion_externa.sql`):** Procedimientos almacenados transaccionales que validan y migran la información cruda al Core RDBMS.
* **Documentación Técnica (`docs/`):** Especificaciones de plantillas (`fase2_plantillas_excel.md`) y flujos ETL (`fase2_etl_mapeo.md`).
* **Plantilla Operativa Unificada (`plantilla_captura_estandarizada_fase2.xlsx`):** Archivo Excel con listas desplegables, catálogos protegidos y formato estricto.

---

## 3. Instructivo Operativo: Uso de la Plantilla de Captura

### 3.1. Estructura del Archivo Excel
El archivo `plantilla_captura_estandarizada_fase2.xlsx` contiene cuatro pestañas:
1. **`_Catalogos_Maestros` (Oculta):** Contiene los arreglos de referencia utilizados para poblar dinámicamente las listas desplegables. Está protegida y oculta para preservar el control de versiones.
2. **`Ventas_Devengadas`:** Destinada al registro de facturas y devengos de clientes.
3. **`Compras_y_Gastos`:** Destinada al registro de órdenes de compra y gastos operativos con proveedores.
4. **`Movimientos_Caja`:** Destinada a la tesorería, registrando flujos monetarios con montos absolutos estrictamente positivos ($> 0$).

### 3.2. Controles de Entrada (*Data Entry Safeguards*)
Para garantizar que la información cumpla con el contrato de datos del sistema, la plantilla cuenta con restricciones rígidas:
* **Listas Desplegables:** Los campos de estado y tipo de flujo no permiten escritura libre. Los usuarios deben seleccionarlos exclusivamente de las opciones predefinidas.
* **Fechas:** Deben ingresarse estrictamente en formato `AAAA-MM-DD`.
* **Montos y Cantidades:** Las columnas numéricas fuerzan valores decimales o enteros positivos. Está prohibido ingresar caracteres especiales o símbolos de moneda en las celdas de cálculo.

---

## 4. Instructivo Técnico: Procesamiento y ETL en SQL Server

### 4.1. Homologación de Datos (Lookup Tables)
Antes de ingresar al Core, el motor utiliza tablas de mapeo para relacionar los textos libres o informales de la planilla con las llaves primarias canónicas:
* `map_clientes`: Vincula el nombre comercial informal de la fuente (`nombre_informal_excel`) con el `id_tercero_oficial`.
* `map_productos`: Vincula la descripción libre de la fuente (`descripcion_libre_excel`) con el `id_item_oficial`.

### 4.2. Ejecución del Stored Procedure de Carga
El procedimiento almacenado principal (`sp_procesar_venta_externa`) opera bajo un diseño transaccional seguro (`BEGIN TRY ... BEGIN TRANSACTION ... COMMIT / ROLLBACK`):
1. **Validación de Clientes:** Si el nombre informal no se encuentra en `map_clientes`, la ejecución se detiene y genera un error controlado, evitando datos huérfanos.
2. **Validación de Ítems:** Verifica la existencia de la descripción en `map_productos`.
3. **Inserción Atómica:** Una vez superadas las validaciones de homologación, la transacción se consolida en el Core RDBMS.