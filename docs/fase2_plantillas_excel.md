# Especificación Técnica: Plantillas Excel de Captura Estandarizada (Fase 2)

# Especificación Técnica: Plantillas Excel de Captura Estandarizada (Fase 2)

## Objetivo
Establecer el estándar de diseño y las reglas de validación (*Data Entry Safeguards*) para las planillas operativas unificadas (`plantilla_captura_estandarizada_fase2.xlsx`). El propósito es garantizar la integridad de los datos en la fuente antes de ser procesados por las tablas de mapeo y cargados al Core RDBMS, apoyándose en una pestaña de catálogos ocultos para evitar la manipulación operativa de los valores permitidos.

---

## 1. Estructura del Libro y Hojas Operativas

* **`_Catalogos_Maestros` (Hoja Oculta):** Contiene los arreglos de referencia maestra para alimentar las listas desplegables (`Estados Venta`, `Estados OC`, `Tipos de Flujo`). Su estado es `hidden` para proteger la integridad de las versiones.
* **`Ventas_Devengadas`:** Captura facturas y devengos de clientes/sponsors conectando con los alias informales.
* **`Compras_y_Gastos`:** Registra órdenes de compra y gastos operativos con proveedores.
* **`Movimientos_Caja`:** Garantiza el registro limpio del flujo de efectivo con montos absolutos positivos.

---

## 2. Reglas de Validación y Campos por Pestaña

### A. Pestaña `Ventas_Devengadas`
1. `Folio Factura`: Texto único sin espacios (ej: `FAC-2026-001`). Obligatorio.
2. `Fecha Emisión`: Formato fecha estricto `AAAA-MM-DD`. Obligatorio.
3. `Cliente (Excel)`: Celda de texto para capturar el nombre informal del cliente a homologar.
4. `Ítem / Servicio (Excel)`: Celda de texto para la descripción libre del producto/servicio.
5. `Cantidad`: Numérico decimal estricto (`> 0`).
6. `Precio Unitario`: Numérico decimal estricto (`>= 0`).
7. `Estado Venta`: Lista desplegable validada contra el rango de catálogos ocultos (`DEVENGADO`, `FACTURADO`, `PAGADO`, `ANULADO`).

### B. Pestaña `Compras_y_Gastos`
1. `Folio OC`: Texto único (ej: `OC-2026-001`). Obligatorio.
2. `Fecha Emisión`: Formato fecha estricto `AAAA-MM-DD`. Obligatorio.
3. `Proveedor (Excel)`: Nombre informal del proveedor.
4. `Insumo / Ítem (Excel)`: Descripción libre del insumo.
5. `Cantidad`: Numérico decimal estricto (`> 0`).
6. `Precio Unitario`: Numérico decimal estricto (`>= 0`).
7. `Estado OC`: Lista desplegable validada contra catálogos ocultos (`BORRADOR`, `APROBADA`, `RECIBIDA`, `ANULADA`).

### C. Pestaña `Movimientos_Caja`
1. `Fecha Movimiento`: Formato fecha estricto `AAAA-MM-DD`. Obligatorio.
2. `Código Cuenta Bancaria`: Texto descriptivo vinculado al plan de cuentas de la Fase 1.
3. `Tipo de Flujo`: Lista desplegable validada (`INGRESO`, `EGRESO`, `TRASPASO_HASTA`, `TRASPASO_DESDE`).
4. `Monto Absoluto`: Numérico decimal estricto positivo (`> 0`). *Prohibido ingresar valores negativos*.
5. `Glosa Movimiento`: Texto descriptivo obligatorio.