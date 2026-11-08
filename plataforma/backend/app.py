"""
app.py — Plataforma de Control de Gestión (MVP)

API REST + archivos estáticos del frontend. Arranca con:

    cd plataforma/backend
    python3 app.py

Sirve en http://localhost:5000  (dashboard + captura de Ventas, Compras y
Caja). Usa SQLite localmente (ver db.py); ver ese archivo para el modo
producción contra SQL Server.
"""

import os
import sqlite3
from datetime import date

from flask import Flask, jsonify, request, send_from_directory

import db

FRONTEND_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "frontend")

app = Flask(__name__, static_folder=None)

IVA_RATE = 0.19


# ---------------------------------------------------------------------------
# Archivos estáticos (frontend)
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    return send_from_directory(FRONTEND_DIR, "index.html")


@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(FRONTEND_DIR, filename)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def rows_to_dicts(rows):
    return [dict(r) for r in rows]


def error(msg, code=400):
    return jsonify({"error": msg}), code


def require_fields(payload, fields):
    missing = [f for f in fields if payload.get(f) in (None, "")]
    if missing:
        return f"Campos requeridos faltantes: {', '.join(missing)}"
    return None


# ---------------------------------------------------------------------------
# Catálogos: terceros, productos/servicios, centros de costo
# ---------------------------------------------------------------------------

@app.route("/api/terceros", methods=["GET"])
def listar_terceros():
    conn = db.get_conn()
    rows = conn.execute(
        "SELECT * FROM tbl_terceros WHERE estado_activo = 1 ORDER BY razon_social"
    ).fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/terceros", methods=["POST"])
def crear_tercero():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["codigo_tercero", "razon_social", "rut_dni"])
    if missing:
        return error(missing)
    conn = db.get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO tbl_terceros
               (codigo_tercero, razon_social, rut_dni, es_cliente, es_proveedor, contacto_email)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                payload["codigo_tercero"],
                payload["razon_social"],
                payload["rut_dni"],
                1 if payload.get("es_cliente") else 0,
                1 if payload.get("es_proveedor") else 0,
                payload.get("contacto_email"),
            ),
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo crear el tercero: {exc}")
    conn.close()
    return jsonify({"id_tercero": new_id}), 201


@app.route("/api/productos", methods=["GET"])
def listar_productos():
    conn = db.get_conn()
    rows = conn.execute(
        "SELECT * FROM tbl_productos_servicios WHERE estado_activo = 1 ORDER BY nombre"
    ).fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/productos", methods=["POST"])
def crear_producto():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["sku_codigo", "nombre", "precio_venta_base"])
    if missing:
        return error(missing)
    conn = db.get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO tbl_productos_servicios
               (sku_codigo, nombre, precio_venta_base, modo_obtencion)
               VALUES (?, ?, ?, ?)""",
            (
                payload["sku_codigo"],
                payload["nombre"],
                payload["precio_venta_base"],
                payload.get("modo_obtencion"),
            ),
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo crear el producto: {exc}")
    conn.close()
    return jsonify({"id_item": new_id}), 201


@app.route("/api/centros_costo", methods=["GET"])
def listar_centros_costo():
    conn = db.get_conn()
    rows = conn.execute("SELECT * FROM tbl_centros_costo ORDER BY nombre").fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/centros_costo", methods=["POST"])
def crear_centro_costo():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["nombre"])
    if missing:
        return error(missing)
    conn = db.get_conn()
    try:
        cur = conn.execute(
            "INSERT INTO tbl_centros_costo (nombre) VALUES (?)", (payload["nombre"],)
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo crear el centro de costo: {exc}")
    conn.close()
    return jsonify({"id_centro_costo": new_id}), 201


# ---------------------------------------------------------------------------
# Ventas devengadas (pestaña Excel "Ventas")
# ---------------------------------------------------------------------------

@app.route("/api/ventas", methods=["GET"])
def listar_ventas():
    conn = db.get_conn()
    rows = conn.execute(
        """SELECT v.*, t.razon_social AS cliente, c.nombre AS centro_costo
           FROM tbl_ventas_devengadas v
           JOIN tbl_terceros t ON t.id_tercero = v.id_tercero
           LEFT JOIN tbl_centros_costo c ON c.id_centro_costo = v.id_centro_costo
           ORDER BY v.fecha_emision DESC, v.id_venta_devengada DESC
           LIMIT 200"""
    ).fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/ventas", methods=["POST"])
def crear_venta():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["folio_factura", "id_tercero", "fecha_emision", "monto_neto"])
    if missing:
        return error(missing)
    monto_neto = float(payload["monto_neto"])
    monto_iva = round(monto_neto * IVA_RATE, 2)
    monto_total = round(monto_neto + monto_iva, 2)
    conn = db.get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO tbl_ventas_devengadas
               (folio_factura, id_tercero, id_centro_costo, fecha_emision,
                monto_neto, monto_iva, monto_total, estado_venta)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                payload["folio_factura"],
                payload["id_tercero"],
                payload.get("id_centro_costo"),
                payload["fecha_emision"],
                monto_neto,
                monto_iva,
                monto_total,
                payload.get("estado_venta", "DEVENGADO"),
            ),
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo registrar la venta: {exc}")
    conn.close()
    return jsonify({"id_venta_devengada": new_id, "monto_iva": monto_iva, "monto_total": monto_total}), 201


# ---------------------------------------------------------------------------
# Compras y Gastos (pestaña Excel "Compras_y_Gastos")
# ---------------------------------------------------------------------------

@app.route("/api/compras", methods=["GET"])
def listar_compras():
    conn = db.get_conn()
    rows = conn.execute(
        """SELECT c.*, t.razon_social AS proveedor, cc.nombre AS centro_costo
           FROM tbl_compras_gastos c
           JOIN tbl_terceros t ON t.id_tercero = c.id_tercero
           LEFT JOIN tbl_centros_costo cc ON cc.id_centro_costo = c.id_centro_costo
           ORDER BY c.fecha_emision DESC, c.id_compra DESC
           LIMIT 200"""
    ).fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/compras", methods=["POST"])
def crear_compra():
    payload = request.get_json(force=True)
    missing = require_fields(
        payload, ["folio_documento", "id_tercero", "fecha_emision", "descripcion", "monto_neto"]
    )
    if missing:
        return error(missing)
    monto_neto = float(payload["monto_neto"])
    monto_iva = round(monto_neto * IVA_RATE, 2)
    monto_total = round(monto_neto + monto_iva, 2)
    conn = db.get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO tbl_compras_gastos
               (folio_documento, id_tercero, id_centro_costo, fecha_emision,
                descripcion, monto_neto, monto_iva, monto_total, estado_compra)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                payload["folio_documento"],
                payload["id_tercero"],
                payload.get("id_centro_costo"),
                payload["fecha_emision"],
                payload["descripcion"],
                monto_neto,
                monto_iva,
                monto_total,
                payload.get("estado_compra", "RECIBIDA"),
            ),
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo registrar la compra: {exc}")
    conn.close()
    return jsonify({"id_compra": new_id, "monto_iva": monto_iva, "monto_total": monto_total}), 201


# ---------------------------------------------------------------------------
# Movimientos de Caja (pestaña Excel "Movimientos_Caja")
# ---------------------------------------------------------------------------

@app.route("/api/caja", methods=["GET"])
def listar_caja():
    conn = db.get_conn()
    rows = conn.execute(
        """SELECT m.*, t.razon_social AS tercero, c.nombre AS centro_costo
           FROM tbl_movimientos_caja m
           LEFT JOIN tbl_terceros t ON t.id_tercero = m.id_tercero
           LEFT JOIN tbl_centros_costo c ON c.id_centro_costo = m.id_centro_costo
           ORDER BY m.fecha_movimiento DESC, m.id_movimiento DESC
           LIMIT 200"""
    ).fetchall()
    conn.close()
    return jsonify(rows_to_dicts(rows))


@app.route("/api/caja", methods=["POST"])
def crear_movimiento_caja():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["fecha_movimiento", "tipo_flujo", "monto_absoluto", "glosa_movimiento"])
    if missing:
        return error(missing)
    if payload["tipo_flujo"] not in ("INGRESO", "EGRESO", "TRASPASO_HASTA", "TRASPASO_DESDE"):
        return error("tipo_flujo inválido")
    conn = db.get_conn()
    try:
        cur = conn.execute(
            """INSERT INTO tbl_movimientos_caja
               (fecha_movimiento, tipo_flujo, monto_absoluto, glosa_movimiento, id_tercero, id_centro_costo)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                payload["fecha_movimiento"],
                payload["tipo_flujo"],
                float(payload["monto_absoluto"]),
                payload["glosa_movimiento"],
                payload.get("id_tercero"),
                payload.get("id_centro_costo"),
            ),
        )
        conn.commit()
        new_id = cur.lastrowid
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo registrar el movimiento: {exc}")
    conn.close()
    return jsonify({"id_movimiento": new_id}), 201


# ---------------------------------------------------------------------------
# Dashboard: agregados (equivalente simplificado de vw_balance_general /
# vw_estado_resultados, calculado directo sobre las tablas operativas en
# vez de sobre dw.fact_* — ver nota de alcance en schema_sqlite.sql)
# ---------------------------------------------------------------------------

@app.route("/api/dashboard", methods=["GET"])
def dashboard():
    conn = db.get_conn()

    ventas = conn.execute(
        "SELECT COALESCE(SUM(monto_neto),0) AS neto, COUNT(*) AS n "
        "FROM tbl_ventas_devengadas WHERE estado_venta != 'ANULADO'"
    ).fetchone()
    compras = conn.execute(
        "SELECT COALESCE(SUM(monto_neto),0) AS neto, COUNT(*) AS n "
        "FROM tbl_compras_gastos WHERE estado_compra != 'ANULADA'"
    ).fetchone()

    caja_rows = conn.execute(
        "SELECT tipo_flujo, COALESCE(SUM(monto_absoluto),0) AS total "
        "FROM tbl_movimientos_caja GROUP BY tipo_flujo"
    ).fetchall()
    caja_por_tipo = {r["tipo_flujo"]: r["total"] for r in caja_rows}
    saldo_caja = (
        caja_por_tipo.get("INGRESO", 0)
        + caja_por_tipo.get("TRASPASO_HASTA", 0)
        - caja_por_tipo.get("EGRESO", 0)
        - caja_por_tipo.get("TRASPASO_DESDE", 0)
    )

    ventas_por_mes = conn.execute(
        """SELECT substr(fecha_emision,1,7) AS mes, COALESCE(SUM(monto_neto),0) AS neto
           FROM tbl_ventas_devengadas WHERE estado_venta != 'ANULADO'
           GROUP BY mes ORDER BY mes"""
    ).fetchall()
    compras_por_mes = conn.execute(
        """SELECT substr(fecha_emision,1,7) AS mes, COALESCE(SUM(monto_neto),0) AS neto
           FROM tbl_compras_gastos WHERE estado_compra != 'ANULADA'
           GROUP BY mes ORDER BY mes"""
    ).fetchall()

    conn.close()

    margen_bruto = ventas["neto"] - compras["neto"]

    return jsonify(
        {
            "ventas_neto": ventas["neto"],
            "ventas_count": ventas["n"],
            "compras_neto": compras["neto"],
            "compras_count": compras["n"],
            "margen_bruto": margen_bruto,
            "saldo_caja": saldo_caja,
            "ventas_por_mes": rows_to_dicts(ventas_por_mes),
            "compras_por_mes": rows_to_dicts(compras_por_mes),
        }
    )


if __name__ == "__main__":
    db.init_db()
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=True)
