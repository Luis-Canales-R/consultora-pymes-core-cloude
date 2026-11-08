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

## Modo producción (SQL Server real) — pendiente

`db.py` ya soporta `DB_ENGINE=mssql` con autenticación de Windows (igual
que `sqlcmd -E`, sin pedir usuario/clave), apuntando por defecto a
`.\SQLEXPRESS` / `consultora_pymes_core`. **Pero el esquema real (carpeta
`/sql` del proyecto) es más rico que el esquema simplificado de este MVP**:

- Cliente/Proveedor en el esquema real es una tabla de roles N:M
  (`rel_terceros_roles` + `cat_roles`), no un par de columnas booleanas.
- Compras tiene cabecera (`tbl_ordenes_compra`) + detalle
  (`tbl_compras_detalle`, por ítem o insumo), no una tabla plana.
- Para mantener la contabilidad de partida doble correcta, registrar una
  venta o compra debería invocar los stored procedures reales
  (`sp_procesar_venta_externa`, etc.) en vez de un INSERT directo.

Conectar esta app tal cual contra las tablas reales daría datos
incompletos. Antes de usar `DB_ENGINE=mssql` en producción, falta adaptar
las consultas de `app.py` al esquema real (o exponerlas a través de vistas
de compatibilidad / los stored procedures existentes). Ese trabajo no
alcanzó a hacerse en este MVP — queda como siguiente paso.
