"""
db.py — Capa de acceso a datos de la Plataforma de Control de Gestión.

Dos backends, elegidos por la variable de entorno DB_ENGINE:

  DB_ENGINE=sqlite (default)
      Usa el archivo local plataforma.db (sqlite3, librería estándar de
      Python, sin dependencias externas). Pensado para desarrollo y demo
      en cualquier máquina, sin necesidad de un SQL Server disponible.

  DB_ENGINE=mssql
      Pensado para apuntar al SQL Server real del usuario (instancia local
      .\\SQLEXPRESS, carpeta /sql del proyecto). Requiere pyodbc instalado
      (pip install pyodbc) y la variable MSSQL_DATABASE (por defecto
      'consultora_pymes_core'). Usa autenticación de Windows (Trusted
      Connection) por default, igual que `sqlcmd -E` -- NO pide usuario
      ni clave, porque la instancia del usuario está configurada así.
      Si en el futuro se usa un SQL Server con login SQL (usuario/clave),
      definir MSSQL_USER y MSSQL_PASSWORD activa ese modo automáticamente.

      Catálogos (terceros/productos/centros_costo) y Ventas ya están
      adaptados al esquema real: ventas se registra invocando el stored
      procedure sp_procesar_venta_externa (mantiene la contabilidad de
      partida doble correcta), y terceros/productos se registran también
      en las tablas de homologación (map_clientes / map_productos) que ese
      procedure usa internamente -- ver app.py. Compras y Caja TODAVÍA no
      están adaptados (siguen apuntando al esquema simplificado) -- queda
      como siguiente paso.

Todas las consultas de app.py usan marcador de posición "?" (estilo
sqlite3 / pyodbc), para que el cambio de motor sea lo más simple posible.
"""

import os
import sqlite3

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SQLITE_PATH = os.path.join(BASE_DIR, "plataforma.db")
SCHEMA_PATH = os.path.join(BASE_DIR, "schema_sqlite.sql")

DB_ENGINE = os.environ.get("DB_ENGINE", "sqlite")


def get_conn():
    if DB_ENGINE == "sqlite":
        conn = sqlite3.connect(SQLITE_PATH)
        conn.execute("PRAGMA foreign_keys = ON")
        conn.row_factory = sqlite3.Row
        return conn

    if DB_ENGINE == "mssql":
        # Requiere: pip install pyodbc  (no disponible en este entorno de
        # desarrollo -- probar en la máquina del usuario, donde vive SQL Server).
        import pyodbc  # noqa: WPS433 (import local a propósito: opcional)

        server = os.environ.get("MSSQL_SERVER", r".\SQLEXPRESS")
        database = os.environ.get("MSSQL_DATABASE", "consultora_pymes_core")
        user = os.environ.get("MSSQL_USER")
        password = os.environ.get("MSSQL_PASSWORD")

        if user and password:
            auth = f"UID={user};PWD={password};"
        else:
            auth = "Trusted_Connection=yes;"  # autenticación de Windows, igual que sqlcmd -E

        conn_str = (
            "DRIVER={ODBC Driver 18 for SQL Server};"
            f"SERVER={server};DATABASE={database};"
            f"{auth}"
            "TrustServerCertificate=yes;"
        )
        return pyodbc.connect(conn_str)

    raise ValueError(f"DB_ENGINE desconocido: {DB_ENGINE!r} (use 'sqlite' o 'mssql')")


def fetch_dicts(conn, sql, params=()):
    """SELECT que devuelve una lista de dicts, igual en sqlite y mssql
    (pyodbc no tiene row_factory; sqlite3.Row sí, pero normalizamos acá)."""
    cur = conn.execute(sql, params)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def fetch_one_dict(conn, sql, params=()):
    rows = fetch_dicts(conn, sql, params)
    return rows[0] if rows else None


def next_id(conn, table, pk_col):
    """Genera el próximo ID para tablas del esquema real que usan PK manual
    (INT PRIMARY KEY, sin IDENTITY) -- mismo patrón MAX+1 que usan los
    scripts de /sql. Solo se usa en modo mssql."""
    row = conn.execute(f"SELECT ISNULL(MAX({pk_col}), 0) + 1 FROM {table}").fetchone()
    return row[0]


def init_db():
    """Crea el esquema si no existe. Solo aplica (y solo es necesaria) en sqlite;
    en mssql el esquema real ya lo define la carpeta /sql del proyecto."""
    if DB_ENGINE != "sqlite":
        return
    conn = get_conn()
    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        conn.executescript(f.read())
    conn.commit()
    conn.close()
