# Manual de Operación e Instructivo Técnico - Fase 3
## Motor ETL, Homologación y Auditoría de Calidad de Datos

---

## 1. Propósito y Alcance
Este manual describe la arquitectura, componentes y procedimiento operativo de la **Fase 3** del sistema RDBMS para PyMEs. Su objetivo principal es asegurar la ingesta limpia, validación cruzada y trazabilidad de errores de los datos operacionales provenientes de archivos externos, y su **carga efectiva** al núcleo analítico (Core RDBMS) una vez superadas todas las validaciones.

---

## 2. Arquitectura de Objetos en Base de Datos (`consultora_pymes_core`)

El motor opera sobre los siguientes objetos principales:
* **`tbl_staging_carga`**: Área de transferencia temporal (*staging*). Recibe los registros crudos de las tres pestañas operativas (`Ventas_Devengadas`, `Compras_y_Gastos`, `Movimientos_Caja`) como texto, sin tipar fecha ni montos, para que ningún error de formato se pierda antes de poder auditarlo.
* **`map_clientes`** / **`map_productos`** / **`map_insumos` (v7)**: Tablas de homologación maestra. Relacionan los nombres informales del Excel con los identificadores oficiales de `tbl_terceros`, `tbl_productos_servicios` y `cat_insumos_recursos` respectivamente. En `Compras_y_Gastos`, una fila homologa contra `map_productos` (compra de un ítem) o contra `map_insumos` (compra de un insumo) — nunca ambas.
* **`tbl_log_errores_etl`**: Bitácora de auditoría. Almacena las anomalías detectadas durante el procesamiento, aislando los registros que no cumplen con las reglas de negocio.
* **`sp_procesar_etl_fase3`**: Procedimiento almacenado transaccional que ejecuta las validaciones cruzadas, registra las incidencias y, si una fila supera todas las reglas, la inserta en el Core (`tbl_ventas_devengadas`/`detalle`, `tbl_ordenes_compra`/`detalle` o `tbl_movimientos_caja`, según la pestaña de origen).
* **(v3) `sp_registrar_asiento_contable`**: SP reutilizable (definido en `sql/crear_modulo_contabilidad_transacciones.sql`) que `sp_procesar_etl_fase3` invoca automáticamente, por cada documento nuevo cargado al Core, para generar su asiento de partida doble en `tbl_asientos_cabecera`/`tbl_asientos_detalle`. No se requiere ninguna acción manual: contabilizar es parte de la carga.

---

## 3. Guía de Operación Paso a Paso

Para ejecutar una corrida de validación e ingesta, siga este procedimiento estándar en SQL Server Management Studio (SSMS):

### Paso 1: Carga de datos al área de Staging
Inserte los registros crudos del archivo de origen en la tabla de staging, identificando siempre el archivo y la pestaña de origen. **No se debe truncar la tabla**: el aislamiento entre cargas se logra por `nombre_archivo` + `pestana_origen`, no por vaciar la tabla completa (así se conserva el historial para trazabilidad y reprocesos).

```sql
INSERT INTO dbo.tbl_staging_carga
    (nombre_archivo, pestana_origen, numero_fila, folio_documento_raw,
     tercero_informal_raw, item_informal_raw, cantidad_raw, precio_unitario_raw,
     estado_documento_raw, fecha_raw)
VALUES
    ('plantilla_nov_2026.xlsx', 'Ventas_Devengadas', 1, 'FAC-2026-050',
     'Cliente_A', 'Prod_01', '10', '1500.00',
     'DEVENGADO', '2026-11-07');
```

Para `Movimientos_Caja`, use las columnas específicas de esa pestaña:

```sql
INSERT INTO dbo.tbl_staging_carga
    (nombre_archivo, pestana_origen, numero_fila, cuenta_bancaria_raw,
     tipo_flujo_raw, monto_absoluto_raw, glosa, fecha_raw)
VALUES
    ('plantilla_nov_2026.xlsx', 'Movimientos_Caja', 1, '1.1.01.002',
     'INGRESO', '500000.00', 'Cobro cliente varios', '2026-11-07');
```

### Paso 2: Ejecución del motor ETL
Invoque el procedimiento indicando el archivo a procesar. Si se omite `@pestana_origen`, se procesan las tres pestañas presentes para ese archivo en una sola corrida:

```sql
EXEC dbo.sp_procesar_etl_fase3 @nombre_archivo = 'plantilla_nov_2026.xlsx';
```

El procedimiento:
1. Limpia los errores previos registrados para ese mismo archivo (evita duplicar incidencias de corridas anteriores).
2. Ejecuta las validaciones de formato de fecha, homologación de cliente/proveedor, homologación de ítem/insumo, cantidades, precios, folios, estados, centro de costo/empleado (si vienen informados) y — para `Movimientos_Caja` — cuenta bancaria, tipo de flujo y monto.
3. Marca como `RECHAZADO` toda fila con al menos un error.
4. Inserta en el Core (dentro de una única transacción atómica) todas las filas que sigan en estado `PENDIENTE`, y las marca como `CARGADO`.
5. **(v3)** Por cada venta, compra o movimiento de caja (INGRESO/EGRESO) nuevo, genera automáticamente su asiento de partida doble llamando a `sp_registrar_asiento_contable`. Si el asiento quedara descuadrado (lo que no debería ocurrir salvo un error de datos no contemplado), toda la transacción —carga y asiento— se revierte.
6. **(v4/v7 - Costeo Directo por Flujo de Venta)** Además del asiento de ingreso/compra, por cada línea de venta o compra resuelve `modo_obtencion` del ítem y genera el leg de costo directo correspondiente: para `COMPRADO_REVENTA`, registra el movimiento de kardex (`ENTRADA` en compra, `SALIDA` al CPP vigente en venta, vía `sp_registrar_movimiento_inventario`) y agrega Debe Costo/Haber Inventario (`1141`); para `FABRICADO`, calcula MOD a costo estándar + MPD a costo **real de kardex** (v7) y agrega Debe Costo/Haber Remuneraciones por Pagar (`2131`) + Haber Materia Prima Aplicada por Regularizar (`2123`). Para una compra de **insumo** (v7), registra la `ENTRADA` a kardex y activa a Inventario de Insumos (`1143`). Ver `docs/modulo_inventario_costeo.md` y el `CHANGELOG.md` (v4/v7) para el detalle y las limitaciones.

> **(v11 — Asiento Automático para Traspasos de Caja)** Desde v11, los movimientos `TRASPASO_HASTA`/`TRASPASO_DESDE` de un mismo lote **sí** generan asiento automático (Debe cuenta destino / Haber cuenta origen), siempre que ambas filas del Excel compartan exactamente la misma `fecha_movimiento`, `monto_absoluto` y `glosa` — es la convención requerida para que el motor ETL pueda emparejarlas sin ambigüedad. **Recomendación de captura:** escriba la misma glosa en ambas filas de un traspaso (p. ej. "Traspaso Banco Principal a Caja Chica" en las dos).
>
> **Limitación que permanece (v11):** si la combinación `(fecha, monto, glosa)` no identifica un único par `TRASPASO_DESDE`/`TRASPASO_HASTA` en el lote (porque difiere la glosa entre ambas filas, o porque hay 2+ traspasos coincidentes en fecha/monto/glosa el mismo día), el emparejamiento automático no ocurre para ese par — el SP lo informa por `PRINT` y debe registrarse con un asiento manual usando `sp_registrar_asiento_contable` directamente.

> **Limitación conocida (v4):** la absorción de Costos Indirectos de Fabricación (CIF) **no** ocurre durante la carga del ETL — se ejecuta aparte, al cierre de cada periodo contable, llamando explícitamente a `EXEC sp_prorratear_cif_periodo @periodo_contable = 'AAAA-MM'`. Desde **v10**, su base de prorrateo usa MOD a costo estándar (BOM) + MPD a costo **real de kardex** (antes, hasta v9, ambos componentes usaban costo estándar — ver `CHANGELOG.md`).

> **(v6)** El costeo de ventas de ítems `SERVICIO` (Honorarios + Insumos) **sí** está implementado desde v6 — ver `docs/modulo_productos_servicios.md`. No aplica CIF a servicios (es exclusivo de producción).

> **(v7 — Kardex Real de Insumos)** La MPD de `FABRICADO` y los Insumos de `SERVICIO` ya **no** se aplican a costo estándar de referencia: se consumen desde el kardex real de insumos (comprados previamente vía `Compras_y_Gastos`, homologados contra `map_insumos`). **Consecuencia operacional:** si al momento de cargar el lote no hay insumo suficiente en kardex para una venta `FABRICADO`/`SERVICIO`, `sp_registrar_movimiento_inventario` lanza un error de "stock insuficiente" que revierte **toda la transacción atómica del lote** (no solo esa fila) — compre los insumos (en el mismo archivo o en uno anterior ya cargado) antes de cargar ventas que los consuman.

### Paso 3: Revisión de la bitácora de errores
Revise `tbl_log_errores_etl` para corregir los datos de origen de las filas rechazadas:

```sql
SELECT pestana_origen, numero_fila, tipo_error, detalle_mensaje, fecha_intento
FROM dbo.tbl_log_errores_etl
WHERE nombre_archivo = 'plantilla_nov_2026.xlsx'
ORDER BY pestana_origen, numero_fila;
```

### Paso 4: Verificación del resultado de la carga
Confirme cuántas filas quedaron `CARGADO` versus `RECHAZADO` para el archivo procesado:

```sql
SELECT pestana_origen, estado_carga, COUNT(*) AS filas
FROM dbo.tbl_staging_carga
WHERE nombre_archivo = 'plantilla_nov_2026.xlsx'
GROUP BY pestana_origen, estado_carga;
```

### Paso 5: Corrección y reproceso
Para las filas `RECHAZADO`, corrija el dato de origen directamente en `tbl_staging_carga` (o inserte una fila corregida con un `numero_fila` nuevo) y vuelva a ejecutar el **Paso 2**. El procedimiento vuelve a poner en `PENDIENTE` cualquier fila `RECHAZADO` de ese archivo antes de revalidar, por lo que no es necesario volver a cargar las filas que ya quedaron `CARGADO`.

### Paso 6 (opcional): Purga de staging histórico
Una vez que un archivo quedó 100% `CARGADO` y conciliado, puede archivarse o eliminarse de staging según la política de retención de la consultora:

```sql
DELETE FROM dbo.tbl_staging_carga
WHERE nombre_archivo = 'plantilla_nov_2026.xlsx' AND estado_carga = 'CARGADO';
```

---

## 4. Códigos de error de `tbl_log_errores_etl`

| `tipo_error` | Pestañas aplicables | Descripción |
|---|---|---|
| `FORMATO_FECHA_INVALIDO` | Las 3 | La fecha no cumple `AAAA-MM-DD` o no es una fecha válida. |
| `CLIENTE_NO_HOMOLOGADO` | Ventas, Compras | El tercero informal no existe en `map_clientes`. |
| `ITEM_NO_HOMOLOGADO` | Ventas, Compras | La descripción libre no existe en `map_productos` (Ventas) ni en `map_productos`/`map_insumos` (Compras, v7). |
| `CANTIDAD_INVALIDA` | Ventas, Compras | Cantidad no numérica o ≤ 0. |
| `PRECIO_INVALIDO` | Ventas, Compras | Precio unitario no numérico o negativo. |
| `FOLIO_VACIO` | Ventas, Compras | Falta el folio de factura u orden de compra. |
| `ESTADO_INVALIDO` | Ventas, Compras | El estado no corresponde al dominio permitido de esa pestaña. |
| `CUENTA_BANCARIA_NO_EXISTE` | Caja | El código de cuenta no existe en `cat_plan_cuentas`. |
| `TIPO_FLUJO_INVALIDO` | Caja | El tipo de flujo no está en `{INGRESO, EGRESO, TRASPASO_HASTA, TRASPASO_DESDE}`. |
| `MONTO_INVALIDO` | Caja | Monto absoluto no numérico o ≤ 0. |
| `GLOSA_VACIA` | Caja | Falta la glosa descriptiva del movimiento. |
| `CENTRO_COSTO_NO_EXISTE` | Las 3 (v3) | `centro_costo_raw` viene informado pero el código no existe en `tbl_centros_costo`. |
| `EMPLEADO_NO_EXISTE` | Las 3 (v3) | `empleado_raw` viene informado pero el RUT no existe en `tbl_empleados_usuarios`. |
