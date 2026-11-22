# Plataforma de Control de Gestión (MVP)

Aplicación web (Flask + HTML/CSS/JS, sin frameworks) para capturar Ventas,
Compras/Gastos y Movimientos de Caja, y ver un Dashboard con los totales —
pensada para eventualmente reemplazar el flujo manual de Excel/ETL del
proyecto `consultora-pymes-core`.

## Cómo correrla (modo local / demo, con SQLite)

No necesita SQL Server ni ninguna instalación adicional: usa la librería
estándar de Python (`sqlite3`).

```bash
cd plataforma/backend
python3 app.py
```

Abre `http://localhost:5000` en el navegador. La primera vez que corre,
crea automáticamente el archivo `plataforma.db` (SQLite) con el esquema
definido en `schema_sqlite.sql`.

## Estructura

```
plataforma/
  backend/
    app.py            API REST (Flask) + sirve el frontend
    db.py             Capa de acceso a datos (sqlite o mssql, ver abajo)
    schema_sqlite.sql Esquema simplificado para el modo local/demo
  frontend/
    index.html         Interfaz (Dashboard, Ventas, Compras, Caja, Catálogos)
    style.css
    app.js              Lógica de navegación + llamadas a la API
```

## Estado actual

Probado de punta a punta en modo SQLite: todos los endpoints (catálogos,
ventas, compras, caja, dashboard), cálculo automático de IVA, validación de
campos requeridos y manejo de errores (duplicados, campos faltantes).

## Modo producción (SQL Server real)

**Catálogos (Terceros, Productos, Centros de costo), Ventas, Compras y
Gastos, y Caja ya están adaptados al esquema real.**

### Requisitos antes de usarlo

1. El esquema real desplegado (carpeta `/sql`) **más**
   `sql/crear_catalogos_base.sql` (roles, tipo de ítem, unidad de medida,
   categoría — sin esto no se puede registrar ni un tercero ni un producto).
2. `pip install pyodbc openpyxl` en la máquina donde corre la plataforma
   (no vienen con Python; hay que instalarlos aparte). `openpyxl` es
   necesario desde que se agregó la exportación de Informes a Excel
   (2026-11-22) — sin él, `python app.py` falla con
   `ModuleNotFoundError: No module named 'openpyxl'`.
3. El "ODBC Driver 18 for SQL Server" instalado en Windows (normalmente ya
   viene si instalaste SSMS; si no, se descarga de Microsoft).

### Cómo correrla contra SQL Server real

```powershell
$env:DB_ENGINE = "mssql"
cd plataforma\backend
python app.py
```

Por defecto apunta a `.\SQLEXPRESS` / `consultora_pymes_core` con
autenticación de Windows (igual que `sqlcmd -E`, sin pedir usuario ni
clave). Para apuntar a otra instancia o base, definir también
`MSSQL_SERVER` / `MSSQL_DATABASE` antes de `python app.py`.

### Cómo funciona por dentro

Para mantener la contabilidad de partida doble correcta (y no duplicar esa
lógica, bastante compleja, en Python), **Ventas no hace INSERT directo**:
invoca el stored procedure real `sp_procesar_venta_externa`, que genera el
asiento contable automáticamente según el tipo de ítem vendido.

Ese procedure fue diseñado para el flujo de importación desde Excel, y
resuelve el cliente/producto por *nombre* a través de tablas de
homologación (`map_clientes`, `map_productos`) en vez de por ID. Para que
funcione también desde esta plataforma, al crear un Cliente o un Producto
se agrega automáticamente una fila de homologación "1:1" (el nombre real
apunta a sí mismo), así la venta pasa por el mismo camino ya probado.

**Documentos con varios ítems (multi-línea):** una factura de venta o de
compra real puede traer varios productos/servicios distintos. En la
plataforma web esto se registra como un **documento con líneas**, igual
que en un ERP real: se llena el encabezado (folio, cliente/proveedor,
centro de costo, fecha, estado) una sola vez, se agregan uno a uno los
ítems (producto, cantidad, precio unitario) a una tabla de líneas, y un
único botón "Registrar" envía todo de una vez.

A nivel de base de datos, el frontend arma el arreglo `lineas` y el
backend (`crear_venta` / `crear_compra` en `app.py`) llama a
`sp_procesar_venta_externa` / `sp_procesar_compra_externa` **una vez por
línea**, todas sobre la misma conexión/transacción (o se registran todas,
o no se registra ninguna). Cada llamada agrega su propia fila de detalle
a la cabecera (creándola en la primera línea, acumulando montos en las
siguientes) — eso no cambió. Lo que sí se agregó es el enlace de
**un solo asiento contable por documento**: la primera línea crea el
asiento (vía `sp_registrar_asiento_contable`) y devuelve su `id_asiento`;
cada línea siguiente reenvía ese mismo `id_asiento` como
`@id_asiento_existente`, por lo que sus líneas contables se agregan al
asiento ya existente en vez de crear uno nuevo. Resultado: un folio con 3
ítems queda con **un solo asiento** en `tbl_asientos_cabecera` (con todas
las líneas Debe/Haber de los 3 ítems en `tbl_asientos_detalle`), igual que
en SAP/NetSuite/Odoo/Dynamics 365 o los ERP chilenos (Defontana/Nubox/
Bsale) — no con un asiento por cada ítem.

**IMPORTANTE — ejecutar antes de probar esto:** además de
`sql/sp_procesar_compra_externa.sql` y `sql/sp_procesar_transaccion_externa.sql`
(que ya tenían que estar desplegados), ahora también hay que desplegar
`sql/sp_registrar_asiento_contable.sql` (archivo nuevo, `CREATE OR ALTER`,
no borra nada) — agrega el parámetro `@id_asiento_existente` al SP central
de contabilización que usan ambos módulos.

**Compras y Gastos** sigue el mismo patrón, a través de un nuevo stored
procedure `sql/sp_procesar_compra_externa.sql` (análogo a
`sp_procesar_venta_externa`, no existía antes): homologa proveedor/producto
igual que Ventas (reutilizando `map_clientes` también para proveedores), y
genera el asiento contable correspondiente (Debe Inventario o Gasto + IVA
Crédito Fiscal, Haber Proveedores). Si el ítem comprado es
`COMPRADO_REVENTA`, además registra la ENTRADA real al kardex
(`sp_registrar_movimiento_inventario`) estableciendo el costo de compra
como costo de entrada (recalcula el CPP). Solo cubre compra de ítems del
catálogo de Productos/Servicios — no cubre compra de insumos/materia prima
(`cat_insumos_recursos`), que queda fuera de alcance de esta primera
versión.

**IMPORTANTE — ejecutar antes de usar Compras:**
`sql/sp_procesar_compra_externa.sql` debe desplegarse en SQL Server (es un
archivo nuevo, no estaba en el despliegue original). Además, como antes de
este cambio solo los Clientes recibían la fila de homologación "1:1" en
`map_clientes`, cualquier Proveedor creado en sesiones anteriores a este
cambio no podrá usarse en una Compra hasta correr este backfill una vez:

```sql
INSERT INTO map_clientes (nombre_informal_excel, id_tercero_oficial)
SELECT t.razon_social, t.id_tercero
FROM tbl_terceros t
JOIN rel_terceros_roles r ON r.id_tercero = t.id_tercero AND r.id_rol = 2 -- proveedor
WHERE NOT EXISTS (SELECT 1 FROM map_clientes m WHERE m.nombre_informal_excel = t.razon_social);
```

**Caja (Movimientos de Caja)** usa el nuevo stored procedure
`sql/sp_procesar_movimiento_caja_externo.sql` (análogo a Ventas/Compras,
no existía antes): recibe un movimiento puntual (Ingreso, Egreso o
Traspaso entre cuentas) y genera su asiento automáticamente, replicando la
lógica ya probada en `sp_procesar_etl_fase3` (sección 4.3/4.3b/4.3c) para
el flujo de importación por Excel, pero resuelta en una sola llamada:

- **Ingreso**: Debe la cuenta de tesorería elegida; Haber Clientes (1121,
  si el movimiento tiene un tercero asociado) o Ingreso (4113, si no).
- **Egreso**: Debe Proveedores (2111, si hay tercero) o Gasto (6215, si
  no); Haber la cuenta de tesorería.
- **Traspaso entre cuentas**: a diferencia del Excel (que arma el traspaso
  emparejando dos filas por fecha/monto/glosa idénticos, cargadas por
  separado), acá se registra en **una sola operación**: se elige la cuenta
  de origen y la cuenta de destino en el mismo formulario, y el SP inserta
  las dos filas (`TRASPASO_DESDE` / `TRASPASO_HASTA`) y arma un único
  asiento de 2 líneas (Debe cuenta destino; Haber cuenta origen) — sin
  ambigüedad de emparejamiento posible.

La cuenta de tesorería (Caja Chica, Banco Principal, Depósitos a Plazo) se
identifica por su código en el plan de cuentas, listado por el nuevo
endpoint `GET /api/catalogos/cuentas-tesoreria`
(`cat_plan_cuentas WHERE id_cuenta_padre = 111`, el nodo "Disponible y
Equivalentes de Efectivo"). En modo demo SQLite ese endpoint devuelve una
única cuenta genérica, ya que el prototipo no tiene un plan de cuentas
real — el campo existe igual para que el formulario sea idéntico en ambos
modos, pero el backend SQLite lo ignora a efectos contables.

**IMPORTANTE — ejecutar antes de usar Caja:**
`sql/sp_procesar_movimiento_caja_externo.sql` debe desplegarse en SQL
Server (archivo nuevo).

### Dashboard (conectado a los informes de gestión reales)

En modo SQL Server, `GET /api/dashboard` ya NO suma directo sobre las
tablas operativas: se calcula a partir de las vistas de
`sql/crear_vistas_reportes_gestion.sql`, que a su vez agregan
`tbl_asientos_detalle` (los asientos reales generados por Ventas, Compras
y Caja).

- `ventas_neto` / `compras_neto` ahora representan Ingresos y
  (Costos + Gastos) acumulados, tomados de `vw_estado_resultados`
  (`GROUP BY tipo_cuenta`), no el `monto_neto` crudo de los documentos.
- `ventas_por_mes` / `compras_por_mes` (gráfico mensual) salen de
  `vw_estado_resultados` agrupada por `periodo_contable` — mismo formato
  `'YYYY-MM'` que ya usaba el modo demo, así que el frontend no necesitó
  cambios para esa parte.
- `saldo_caja` es la suma de `vw_balance_general.saldo` para las cuentas
  bajo `cat_plan_cuentas.id_cuenta_padre = 111` (Disponible y Equivalentes
  de Efectivo) — el saldo contable real de Caja Chica + Banco + Depósitos,
  no un recálculo manual de los movimientos.
- Nuevo: `total_activo`, `total_pasivo`, `total_patrimonio`, sumados desde
  `vw_balance_general` (`GROUP BY tipo_cuenta`) — el Balance General real.
  El Dashboard muestra estos tres totales en un panel nuevo, más una
  cuarta tarjeta "Resultado acumulado" (`Activo − Pasivo − Patrimonio`):
  como todavía no existe un asiento de cierre de ejercicio, ese valor no
  es una descuadratura — es el resultado del periodo, y debería coincidir
  con `margen_bruto`. El panel se oculta automáticamente en modo demo
  SQLite (no hay plan de cuentas real detrás).

El contrato JSON del endpoint se mantuvo retrocompatible (mismas claves
que ya consumía `app.js`), agregando solo las tres claves nuevas del
Balance General; el modo SQLite sigue calculando como antes, sin tocar
ese código.

### Informes Financieros Avanzados (Controller)

Nueva pestaña "Informes", con dos reportes que no requieren cambios de
esquema (se construyeron primero por eso):

- **Balance de 8 Columnas**: hoja de trabajo tradicional (Sumas Debe/Haber,
  Saldos Deudor/Acreedor, Inventario Activo/Pasivo/Patrimonio, Pérdida/
  Ganancia), acumulada a la fecha. Vista nueva `vw_balance_ocho_columnas`
  en `sql/crear_vista_balance_ocho_columnas.sql` (reutiliza la misma
  lógica de saldo por naturaleza de `vw_balance_general`). Adaptación
  respecto del formato clásico: el Patrimonio queda en su propia columna
  en vez de fusionarlo con Pasivo.
- **Comparación entre Periodos**: variación mes-a-mes (MoM), contra el
  mismo mes del año anterior (YoY), y acumulado Año a la Fecha (YTD) vs.
  el mismo rango del año anterior — para Ingresos, Costos y Gastos, y
  Resultado. Se calcula 100% en Python (`calcular_comparacion_periodos`
  en `app.py`, función pura sin acceso a BD, testeada con datos
  sintéticos cubriendo primer periodo sin histórico, cruce de año y YTD
  parcial) a partir de `vw_estado_resultados` agrupada por
  `periodo_contable` — sin vista ni columna nueva.

- **KPIs Estándar (Liquidez, Apalancamiento, Rentabilidad)**: Razón
  Corriente, Prueba Ácida, Capital de Trabajo; Endeudamiento, Deuda/
  Patrimonio; Margen Bruto, Margen Neto, ROE, ROA — fórmulas estándar de
  finanzas corporativas. Requirió una columna nueva,
  `cat_plan_cuentas.clasificacion_corriente` (migración aditiva en
  `sql/agregar_clasificacion_corriente.sql`), para poder separar Activo/
  Pasivo Corriente de No Corriente. Esa columna es **COMPUTED**, derivada
  directamente del `codigo_cuenta` (`1.1.x`/`2.1.x` = Corriente,
  `1.2.x`/`2.2.x` = No Corriente — la distinción ya existía implícita en
  la jerarquía del plan de cuentas estándar cargado), así que no necesitó
  ningún backfill manual ni se puede desincronizar con cuentas nuevas que
  seguían la misma convención de código. Calculado en
  `calcular_kpis` (`app.py`, función pura, testeada con datos sintéticos
  y con los números reales ya validados del Dashboard, incluyendo el caso
  límite Patrimonio = 0 → ratios que lo dividen quedan en `None`/"N/D" en
  vez de reventar). El "Inventario" para la Prueba Ácida se identifica
  por el grupo `1.1.04.*` del plan de cuentas (Existencias e
  Inventarios) — una convención de este plan de cuentas específico, no
  un estándar universal.

Los tres endpoints (`GET /api/informes/balance-8-columnas`,
`GET /api/informes/comparacion-periodos`, `GET /api/informes/kpis`)
devuelven `modo_demo: true` y datos vacíos en SQLite, porque dependen de
un plan de cuentas real que el prototipo no modela; el frontend oculta
los paneles automáticamente en ese caso.

**IMPORTANTE — ejecutar antes de usar Informes:**
`sql/crear_vista_balance_ocho_columnas.sql` y
`sql/agregar_clasificacion_corriente.sql` deben desplegarse en SQL
Server (archivos nuevos). Ambos son additivos (no borran ni modifican
datos existentes).

**Nota sobre encoding de archivos .sql**: si un `.sql` nuevo tiene texto
con tildes/ñ en literales de datos (no solo en comentarios), debe
guardarse con BOM UTF-8 para que SSMS lo abra con la codificación
correcta — ver Hallazgo #8 en el plan del proyecto para el bug que esto
evita (mojibake en `cat_plan_cuentas.nombre_cuenta`, ya corregido).

### Exportación a Excel (Fase 1)

Cada uno de los tres informes de arriba tiene un botón "⬇ Descargar
Excel" que llama a su propio endpoint de exportación:

- `GET /api/informes/kpis/export`
- `GET /api/informes/balance-8-columnas/export`
- `GET /api/informes/comparacion-periodos/export`

Los tres devuelven un `.xlsx` (mimetype
`application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`) listo
para descargar, generado con `openpyxl` a través de un módulo nuevo,
`plataforma/backend/excel_export.py`, que centraliza el estilo
(encabezados, formato de moneda/razón/porcentaje, fila de totales en
negrita, ancho de columna) para que los endpoints de exportación
siguientes (catálogos, luego transaccionales — ver el plan del proyecto)
lo reutilicen en vez de reinventarlo. En modo SQLite (demo) devuelven
`400` con un mensaje claro en vez de datos vacíos, porque no tiene
sentido exportar un informe que no existe en ese modo.

Cada endpoint de exportación reutiliza exactamente el mismo cálculo que
su endpoint JSON ya validado (`_obtener_kpis`, `_obtener_balance_ocho_
columnas`, `_obtener_comparacion_periodos` — se factorizaron para esto),
así que el número en el Excel no puede divergir del número que se ve en
pantalla. Probado con datos sintéticos que imitan la forma real de
`vw_balance_ocho_columnas`/`vw_balance_general`/`vw_estado_resultados`
(incluyendo el caso límite Patrimonio = 0 → celda "N/D"), usando el test
client de Flask + `openpyxl.load_workbook` para confirmar que el archivo
generado es un `.xlsx` válido con las hojas y los números esperados — no
validado todavía visualmente por el usuario abriendo el archivo
descargado.

Esta es la Fase 1 de la meta más amplia "Exportación a Excel y Carga/
Exportación Masiva" (ver plan del proyecto): exportación masiva de
catálogos, exportación masiva de módulos transaccionales, carga masiva
de catálogos y carga masiva de transaccionales siguen, en ese orden.

### Pendiente

- Exportación masiva de catálogos (Terceros, Productos/Servicios,
  Centros de Costo) y de módulos transaccionales (Ventas, Compras,
  Caja), y carga masiva de todos los módulos (plantilla descargable,
  validación fila por fila, reporte de errores) — ver el documento de
  plan del proyecto para el orden de fases y los riesgos de cada una.
- Flujo de Caja Proyectado (control de liquidez): no implementado todavía
  — ver el documento de plan del proyecto para el alcance y los pasos
  propuestos (requiere resolver la trazabilidad Caja↔documento y agregar
  fecha de vencimiento de pago a Compras).
- Informes Financieros Avanzados — EBITDA y el Estado de Resultados en
  cascada: pendientes, requieren agregar `subclasificacion_resultado` a
  `cat_plan_cuentas` (ver plan del proyecto). El formato de presentación
  SII queda pendiente de que el contador de la empresa confirme el
  régimen tributario y los códigos vigentes del Formulario 22.
