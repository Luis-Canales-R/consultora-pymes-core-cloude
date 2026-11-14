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

**Catálogos (Terceros, Productos, Centros de costo), Ventas y Compras y
Gastos ya están adaptados al esquema real.** Falta Caja (sigue apuntando al
esquema simplificado, además de un bug de sintaxis SQLite/`LIMIT`) —
próximo paso.

### Requisitos antes de usarlo

1. El esquema real desplegado (carpeta `/sql`) **más**
   `sql/crear_catalogos_base.sql` (roles, tipo de ítem, unidad de medida,
   categoría — sin esto no se puede registrar ni un tercero ni un producto).
2. `pip install pyodbc` en la máquina donde corre la plataforma (no viene
   con Python; hay que instalarlo aparte).
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

### Pendiente

- Caja: aún no adaptada (sigue con el esquema simplificado, con un bug de
  sintaxis SQLite/`LIMIT` que no es válida en SQL Server).
- El Dashboard sigue calculando sus totales directo sobre las tablas
  operativas; falta conectarlo a `vw_balance_general` / `vw_estado_resultados`
  para mostrar el Balance General y Estado de Resultados reales.
- No se pudo probar `DB_ENGINE=mssql` end-to-end en el entorno de
  desarrollo (sin pyodbc ni acceso al SQL Server del usuario) — probar en
  la máquina real y reportar cualquier error para corregirlo.
