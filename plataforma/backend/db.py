"""
db.py — Capa de acceso a datos de la Plataforma de Control de Gestión.

Dos backends, elegidos por la variable de entorno DB_ENGINE:

  DB_ENGINE=sqlite (default)
      Usa el archivo local plataforma.db (sqlite3, librería estándar de
      Python, sin dependencias externas). Pensado para desarrollo y demo
      en cualquier máquina, sin necesidad de un SQL Server disponible.

  DB_ENGINE=mssql
      Pensado para apuntar al SQL Server real del usuario (instancia local
      .\SQLEXPRESS, carpeta /sql del proyecto). Requiere pyodbc instalado
      (pip install pyodbc) y la variable MSSQL_DATABASE (por defecto
      'consultora_pymes_core'). Usa autenticación de Windows (Trusted
      Connection) por default, igual que `sqlcmd -E` -- NO pide usuario
      ni clave, porque la instancia del usuario está configurada así.
      Si en el futuro se usa un SQL Server con login SQL (usuario/clave),
      definir MSSQL_USER y MSSQL_PASSWORD activa ese modo automáticamente.

      IMPORTANTE -- este modo todavía NO se puede usar "tal cual": el
      esquema real (carpeta /sql) es más rico que el esquema simplificado
      de este MVP (por ejemplo, cliente/proveedor es una tabla de roles
      N:M -- rel_terceros_roles -- no un par de columnas booleanas; y
      compras tiene cabecera tbl_ordenes_compra + detalle tbl_compras_
      detalle, no una tabla plana). Conectar esta app directo a las tablas
      reales sin adaptar las consultas de app.py (o sin usar los stored
      procedures reales como sp_procesar_venta_externa para mantener la
      contabilidad de partida doble correcta) daría datos incompletos o
      incorrectos. Antes de usar DB_ENGINE=mssql en producción falta ese
      trabajo de adaptación -- no fue parte de este MVP.

Todas las consultas de app.py usan SQL estándar (sin funciones específicas
de un motor) para que esa futura adaptación sea lo más simple posible.
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
