# Manual de Operación y Arquitectura - Fase 1 (Core RDBMS PyMEs)

## 1. Propósito del Sistema
El **Core RDBMS de la Consultora** representa el estado canónico ideal para la gestión operativa y financiera de una PyME. Su diseño relacional en Tercera Forma Normal (3FN) desacopla la lógica de negocio de los registros transaccionales, garantizando trazabilidad, integridad referencial estricta y cumplimiento con los estándares tributarios y contables locales (Chile/IFRS).

---

## 2. Estructura y Módulos de la Fase 1

El modelo se divide en cinco grandes pilares interconectados:

### A. Módulo de Terceros (Clientes, Proveedores y Sponsors)
* **Objetivo:** Centraliza la identidad fiscal, comercial y de contacto de todas las entidades externas que interactúan con la empresa.
* **Componentes Clave:** 
  * Datos fiscales (RUT, razón social, dirección).
  * Condiciones de crédito y plazos de pago.

### B. Módulo de Productos, Servicios y Composición (BOM / CBS)
* **Objetivo:** Estandarizar la oferta comercial combinando productos tangibles con servicios profesionales mediante el Patrón de Extensión ERP (1:1) y estructuras de costos modulares.
* **Componentes Clave:**
  * `tbl_productos_servicios`: Cabecera unificada (SKU, nombre, precio base).
  * `tbl_item_extension_producto` & `tbl_item_extension_servicio`: Tablas 1:1 para atributos logísticos o de SLA.
  * `tbl_item_composicion_hh` & `tbl_item_composicion_insumos`: Estructura BOM/CBS para calcular automáticamente el costo total y el margen de contribución a través de la vista `vw_productos_servicios_costeo`.

### C. Módulo Contable, Transaccional y Partida Doble
* **Objetivo:** Automatizar el registro de hechos económicos garantizando la ecuación contable estricta ($Debe = Haber$) y separando conceptualmente el **Devengado** de la **Liquidación (Flujo de Caja)**.
* **Componentes Clave:**
  * `cat_plan_cuentas`: Carga masiva jerárquica del plan de cuentas estándar Chile (Activo, Pasivo, Patrimonio, Ingresos, Costos, Gastos).
  * `tbl_asientos_cabecera` y `tbl_asientos_detalle`: Motor de partida doble.

### D. Módulo de Transacciones Granulares (Operación Comercial y Liquidez)
* **Objetivo:** Detallar el ciclo comercial diario de la PyME y gestionar los flujos monetarios con estricta precisión.
* **Componentes Clave:**
  * `tbl_ordenes_compra` y `tbl_compras_detalle`: Ciclo de compras a proveedores con estados de control (`BORRADOR`, `APROBADA`, `RECIBIDA`, `ANULADA`).
  * `tbl_ventas_devengadas` y `tbl_ventas_detalle`: Registro de facturas y devengos hacia clientes.
  * `tbl_movimientos_caja`: Capa de liquidez implementando el patrón de diseño financiero de **montos absolutos con atributos direccionales explícitos** (`INGRESO`, `EGRESO`, `TRASPASO_HASTA`, `TRASPASO_DESDE`).

### E. Módulo de Organización y Control (Centros de Costo y Empleados)
* **Objetivo:** Aportar las dimensiones organizacionales para el control de gestión (alineado con la taxonomía APQC) y la trazabilidad operativa.
* **Componentes Clave:**
  * `tbl_centros_costo`: Jerarquía de áreas (Finanzas, Operaciones, Ventas, etc.).
  * `tbl_empleados_usuarios`: Registro de colaboradores vinculados a su respectivo centro de costo.

---

## 3. Instructivo de Despliegue y Validación en SQL Server

Para desplegar o levantar el ecosistema completo desde cero en una nueva instancia de base de datos (`consultora_pymes_core`), se debe seguir estrictamente este orden de ejecución de scripts en **SQL Server Management Studio (SSMS)**:

> **Corrección v2:** la versión anterior de este manual omitía `crear_modulo_terceros.sql` del orden de despliegue. Como `tbl_transacciones_cabecera`, `tbl_ordenes_compra`, `tbl_ventas_devengadas` y `tbl_movimientos_caja` ahora declaran `FOREIGN KEY` hacia `tbl_terceros`, el módulo de Terceros debe crearse **primero**; de lo contrario los scripts de los pasos 2 y 5 fallan por referencia a una tabla inexistente.
>
> **Corrección v3 (Control de Gestión):** Centros de Costo/Empleados se adelantó del paso 4 al 2, y Contabilidad del paso 2 al 3, porque `tbl_asientos_detalle.id_centro_costo` y `tbl_productos_servicios.id_cuenta_ingreso/id_cuenta_costo_gasto` ahora referencian esas tablas. Se agregó también el paso 9 (vistas de reporte).

1. **Creación del Módulo Unificado de Terceros** (`sql/crear_modulo_terceros.sql`): Levanta `tbl_terceros` y sus catálogos y extensiones (Cliente/Proveedor). **Debe ejecutarse antes que cualquier otro script**, ya que el resto del modelo transaccional depende de `tbl_terceros`.
2. **Creación de Centros de Costo y Empleados** (`sql/crear_modulo_centros_costo_empleados.sql`): Configura la estructura organizacional y los usuarios.
3. **Creación del Plan de Cuentas y Motor Contable** (`sql/crear_modulo_contabilidad_transacciones.sql`): Levanta las tablas maestras contables, el catálogo de cuentas de Chile, el tipo `tipo_asiento_detalle` y el SP `sp_registrar_asiento_contable` que automatiza la partida doble.
4. **Creación del Módulo de Productos, Servicios y BOM** (`sql/crear_modulo_productos_servicios.sql`): Despliega la cabecera de ítems, extensiones ERP, la vista de costeo y el mapeo contable por ítem.
5. **Creación de Tablas Transaccionales Granulares** (`sql/crear_tablas_transaccionales_granular.sql`): Despliega órdenes de compra, ventas devengadas y la capa de liquidez de caja, cada una con imputación a centro de costo/empleado.
6. **Creación de Tablas de Mapeo** (`sql/crear_tablas_mapeo.sql`): Levanta `map_clientes` y `map_productos` (Fase 2), con FK hacia `tbl_terceros` y `tbl_productos_servicios`.
7. **Creación de Staging y Auditoría ETL** (`sql/crear_tabla_staging.sql` y `sql/crear_tabla_log_errores.sql`): Levanta el área de staging multi-pestaña y la bitácora de errores (Fase 3).
8. **Creación de Stored Procedures** (`sql/sp_procesar_transaccion_externa.sql` y `sql/sp_procesar_etl_fase3.sql`): Despliega la lógica de homologación, validación, carga hacia el Core y contabilización automática.
9. **Creación de Vistas de Reporte** (`sql/crear_vistas_reportes_gestion.sql`): Balance General y Estado de Resultados (global y por centro de costo).

### Verificación de Integridad y Cuadratura
Todo ciclo transaccional debe finalizar validando la cuadratura de los asientos contables ejecutando la consulta de control:
```sql
SELECT 
    a.numero_asiento,
    SUM(d.debe) AS total_debe,
    SUM(d.haber) AS total_haber,
    CASE WHEN SUM(d.debe) = SUM(d.haber) THEN 'CUADRADO (PARTIDA DOBLE OK)' ELSE 'DESCUADRADO' END AS estado_cuadratura
FROM tbl_asientos_cabecera a
INNER JOIN tbl_asientos_detalle d ON a.id_asiento = d.id_asiento
GROUP BY a.numero_asiento, a.fecha_asiento, a.glosa_general;