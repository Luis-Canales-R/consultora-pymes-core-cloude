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

**Catálogos (Terceros, Productos, Centros de costo) y Ventas ya están
adaptados al esquema real.** Faltan Compras y Caja (siguen apuntando al
esquema simplificado) — próximo paso.

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

### Pendiente

- Compras y Caja: aún no adaptados (siguen con el esquema simplificado).
- El Dashboard sigue calculando sus totales directo sobre las tablas
  operativas; falta conectarlo a `vw_balance_general` / `vw_estado_resultados`
  para mostrar el Balance General y Estado de Resultados reales.
- No se pudo probar `DB_ENGINE=mssql` end-to-end en el entorno de
  desarrollo (sin pyodbc ni acceso al SQL Server del usuario) — probar en
  la máquina real y reportar cualquier error para corregirlo.
