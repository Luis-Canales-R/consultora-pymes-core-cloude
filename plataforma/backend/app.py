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
from uuid import uuid4

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

ROL_CLIENTE = 1
ROL_PROVEEDOR = 2


@app.route("/api/terceros", methods=["GET"])
def listar_terceros():
    conn = db.get_conn()
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT t.id_tercero, t.codigo_tercero, t.razon_social, t.rut_dni,
                      t.contacto_email, t.estado_activo,
                      CASE WHEN EXISTS (SELECT 1 FROM rel_terceros_roles r
                                        WHERE r.id_tercero = t.id_tercero AND r.id_rol = ?)
                           THEN 1 ELSE 0 END AS es_cliente,
                      CASE WHEN EXISTS (SELECT 1 FROM rel_terceros_roles r
                                        WHERE r.id_tercero = t.id_tercero AND r.id_rol = ?)
                           THEN 1 ELSE 0 END AS es_proveedor
               FROM tbl_terceros t
               WHERE t.estado_activo = 1
               ORDER BY t.razon_social""",
            (ROL_CLIENTE, ROL_PROVEEDOR),
        )
    else:
        rows = rows_to_dicts(conn.execute(
            "SELECT * FROM tbl_terceros WHERE estado_activo = 1 ORDER BY razon_social"
        ).fetchall())
    conn.close()
    return jsonify(rows)


@app.route("/api/terceros", methods=["POST"])
def crear_tercero():
    payload = request.get_json(force=True)
    # codigo_tercero es opcional: si no se informa, se genera automático
    # (T-0001, T-0002, ...) para no depender de que cada persona invente
    # un código único a mano.
    missing = require_fields(payload, ["razon_social", "rut_dni"])
    if missing:
        return error(missing)
    conn = db.get_conn()

    if db.DB_ENGINE == "mssql":
        try:
            new_id = db.next_id(conn, "tbl_terceros", "id_tercero")
            codigo_tercero = payload.get("codigo_tercero") or f"T-{new_id:04d}"
            conn.execute(
                """INSERT INTO tbl_terceros
                   (id_tercero, codigo_tercero, id_tipo_persona, razon_social, rut_dni, id_pais, contacto_email)
                   VALUES (?, ?, 1, ?, ?, 1, ?)""",
                (new_id, codigo_tercero, payload["razon_social"],
                 payload["rut_dni"], payload.get("contacto_email")),
            )
            if payload.get("es_cliente"):
                conn.execute(
                    "INSERT INTO rel_terceros_roles (id_tercero, id_rol) VALUES (?, ?)",
                    (new_id, ROL_CLIENTE),
                )
            if payload.get("es_proveedor"):
                conn.execute(
                    "INSERT INTO rel_terceros_roles (id_tercero, id_rol) VALUES (?, ?)",
                    (new_id, ROL_PROVEEDOR),
                )
            if payload.get("es_cliente") or payload.get("es_proveedor"):
                # Homologación 1:1 (nombre real -> sí mismo), UNA sola vez
                # por tercero (nombre_informal_excel es UNIQUE en map_clientes),
                # para que sp_procesar_venta_externa y sp_procesar_compra_externa
                # puedan resolverlo directo sea cliente, proveedor, o ambos.
                conn.execute(
                    "INSERT INTO map_clientes (nombre_informal_excel, id_tercero_oficial) VALUES (?, ?)",
                    (payload["razon_social"], new_id),
                )
            conn.commit()
        except Exception as exc:  # pyodbc.Error también cubierto por Exception
            conn.rollback()
            conn.close()
            return error(f"No se pudo crear el tercero: {exc}")
        conn.close()
        return jsonify({"id_tercero": new_id}), 201

    try:
        codigo_tercero = payload.get("codigo_tercero")
        cur = conn.execute(
            """INSERT INTO tbl_terceros
               (codigo_tercero, razon_social, rut_dni, es_cliente, es_proveedor, contacto_email)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                codigo_tercero or f"__pending_{uuid4().hex}",
                payload["razon_social"],
                payload["rut_dni"],
                1 if payload.get("es_cliente") else 0,
                1 if payload.get("es_proveedor") else 0,
                payload.get("contacto_email"),
            ),
        )
        new_id = cur.lastrowid
        if not codigo_tercero:
            conn.execute(
                "UPDATE tbl_terceros SET codigo_tercero = ? WHERE id_tercero = ?",
                (f"T-{new_id:04d}", new_id),
            )
        conn.commit()
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo crear el tercero: {exc}")
    conn.close()
    return jsonify({"id_tercero": new_id}), 201


@app.route("/api/productos", methods=["GET"])
def listar_productos():
    conn = db.get_conn()
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT p.id_item, p.sku_codigo, p.nombre, p.precio_venta_base,
                      p.modo_obtencion, p.aplica_iva, p.estado_activo,
                      ti.nombre AS tipo_item, ci.nombre AS categoria, um.nombre AS unidad_medida
               FROM tbl_productos_servicios p
               JOIN cat_tipos_item ti ON ti.id_tipo_item = p.id_tipo_item
               JOIN cat_categorias_item ci ON ci.id_categoria_item = p.id_categoria_item
               JOIN cat_unidades_medida um ON um.id_unidad_medida = p.id_unidad_medida
               WHERE p.estado_activo = 1
               ORDER BY p.nombre""",
        )
    else:
        rows = rows_to_dicts(conn.execute(
            "SELECT * FROM tbl_productos_servicios WHERE estado_activo = 1 ORDER BY nombre"
        ).fetchall())
    conn.close()
    return jsonify(rows)


@app.route("/api/productos", methods=["POST"])
def crear_producto():
    payload = request.get_json(force=True)
    # sku_codigo es opcional: si no se informa, se genera automático.
    missing = require_fields(payload, ["nombre", "precio_venta_base"])
    if missing:
        return error(missing)
    conn = db.get_conn()

    if db.DB_ENGINE == "mssql":
        modo = payload.get("modo_obtencion") or None
        id_tipo_item = 2 if modo == "SERVICIO" else 1  # 1=PRODUCTO, 2=SERVICIO (cat_tipos_item)
        # aplica_iva: por defecto afecto (1); se puede marcar exento desde el
        # formulario (payload["aplica_iva"] == False -> venta exenta de IVA).
        aplica_iva = 0 if payload.get("aplica_iva") is False else 1
        try:
            new_id = db.next_id(conn, "tbl_productos_servicios", "id_item")
            sku_codigo = payload.get("sku_codigo") or f"SKU-{new_id:04d}"
            conn.execute(
                """INSERT INTO tbl_productos_servicios
                   (id_item, sku_codigo, nombre, id_tipo_item, id_categoria_item,
                    id_unidad_medida, precio_venta_base, aplica_iva, modo_obtencion)
                   VALUES (?, ?, ?, ?, 1, 1, ?, ?, ?)""",
                (new_id, sku_codigo, payload["nombre"], id_tipo_item,
                 payload["precio_venta_base"], aplica_iva, modo),
            )
            # Homologación 1:1 para que sp_procesar_venta_externa lo resuelva directo.
            conn.execute(
                "INSERT INTO map_productos (descripcion_libre_excel, id_item_oficial) VALUES (?, ?)",
                (payload["nombre"], new_id),
            )
            conn.commit()
        except Exception as exc:
            conn.rollback()
            conn.close()
            return error(f"No se pudo crear el producto: {exc}")
        conn.close()
        return jsonify({"id_item": new_id}), 201

    try:
        sku_codigo = payload.get("sku_codigo")
        cur = conn.execute(
            """INSERT INTO tbl_productos_servicios
               (sku_codigo, nombre, precio_venta_base, modo_obtencion)
               VALUES (?, ?, ?, ?)""",
            (
                sku_codigo or f"__pending_{uuid4().hex}",
                payload["nombre"],
                payload["precio_venta_base"],
                payload.get("modo_obtencion"),
            ),
        )
        new_id = cur.lastrowid
        if not sku_codigo:
            conn.execute(
                "UPDATE tbl_productos_servicios SET sku_codigo = ? WHERE id_item = ?",
                (f"SKU-{new_id:04d}", new_id),
            )
        conn.commit()
    except sqlite3.IntegrityError as exc:
        conn.close()
        return error(f"No se pudo crear el producto: {exc}")
    conn.close()
    return jsonify({"id_item": new_id}), 201


@app.route("/api/centros_costo", methods=["GET"])
def listar_centros_costo():
    conn = db.get_conn()
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT id_centro_costo, codigo_cc, nombre_cc AS nombre
               FROM tbl_centros_costo WHERE es_activo = 1 ORDER BY nombre_cc""",
        )
    else:
        rows = rows_to_dicts(conn.execute("SELECT * FROM tbl_centros_costo ORDER BY nombre").fetchall())
    conn.close()
    return jsonify(rows)


@app.route("/api/centros_costo", methods=["POST"])
def crear_centro_costo():
    payload = request.get_json(force=True)
    missing = require_fields(payload, ["nombre"])
    if missing:
        return error(missing)
    conn = db.get_conn()

    if db.DB_ENGINE == "mssql":
        try:
            new_id = db.next_id(conn, "tbl_centros_costo", "id_centro_costo")
            codigo_cc = payload.get("codigo_cc") or f"CC-{new_id:03d}"
            conn.execute(
                """INSERT INTO tbl_centros_costo (id_centro_costo, codigo_cc, nombre_cc, nivel)
                   VALUES (?, ?, ?, 1)""",
                (new_id, codigo_cc, payload["nombre"]),
            )
            conn.commit()
        except Exception as exc:
            conn.rollback()
            conn.close()
            return error(f"No se pudo crear el centro de costo: {exc}")
        conn.close()
        return jsonify({"id_centro_costo": new_id}), 201

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
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT TOP 200 v.*, t.razon_social AS cliente, c.nombre_cc AS centro_costo
               FROM tbl_ventas_devengadas v
               JOIN tbl_terceros t ON t.id_tercero = v.id_tercero
               LEFT JOIN tbl_centros_costo c ON c.id_centro_costo = v.id_centro_costo
               ORDER BY v.fecha_emision DESC, v.id_venta_devengada DESC""",
        )
    else:
        rows = rows_to_dicts(conn.execute(
            """SELECT v.*, t.razon_social AS cliente, c.nombre AS centro_costo
               FROM tbl_ventas_devengadas v
               JOIN tbl_terceros t ON t.id_tercero = v.id_tercero
               LEFT JOIN tbl_centros_costo c ON c.id_centro_costo = v.id_centro_costo
               ORDER BY v.fecha_emision DESC, v.id_venta_devengada DESC
               LIMIT 200"""
        ).fetchall())
    conn.close()
    return jsonify(rows)


@app.route("/api/ventas", methods=["POST"])
def crear_venta():
    payload = request.get_json(force=True)

    if db.DB_ENGINE == "mssql":
        # En el esquema real toda venta es de un ítem/servicio concreto
        # (se la pasa a sp_procesar_venta_externa, que calcula neto/IVA/
        # total y genera el asiento contable correcto según el ítem).
        # IMPORTANTE: cantidad y precio_unitario reales (no solo el monto
        # total) son obligatorios porque el kardex de inventario (CPP y
        # stock) depende de la cantidad real vendida, no de "1 unidad".
        missing = require_fields(
            payload, ["folio_factura", "id_tercero", "id_item", "fecha_emision", "cantidad", "precio_unitario"]
        )
        if missing:
            return error(missing)
        conn = db.get_conn()
        try:
            cliente = db.fetch_one_dict(
                conn, "SELECT razon_social FROM tbl_terceros WHERE id_tercero = ?", (payload["id_tercero"],)
            )
            producto = db.fetch_one_dict(
                conn, "SELECT nombre FROM tbl_productos_servicios WHERE id_item = ?", (payload["id_item"],)
            )
            if not cliente:
                return error("Cliente no encontrado.")
            if not producto:
                return error("Producto/servicio no encontrado.")

            conn.execute(
                """EXEC dbo.sp_procesar_venta_externa
                       @folio_factura = ?, @fecha_emision = ?,
                       @nombre_informal_cliente = ?, @descripcion_libre_item = ?,
                       @cantidad = ?, @precio_unitario = ?,
                       @estado_venta = ?, @id_centro_costo = ?""",
                (
                    payload["folio_factura"], payload["fecha_emision"],
                    cliente["razon_social"], producto["nombre"],
                    float(payload["cantidad"]), float(payload["precio_unitario"]),
                    payload.get("estado_venta", "DEVENGADO"),
                    payload.get("id_centro_costo"),
                ),
            )
            conn.commit()
            resultado = db.fetch_one_dict(
                conn,
                "SELECT id_venta_devengada, monto_iva, monto_total FROM tbl_ventas_devengadas WHERE folio_factura = ?",
                (payload["folio_factura"],),
            )
        except Exception as exc:
            conn.rollback()
            conn.close()
            return error(f"No se pudo registrar la venta: {exc}")
        conn.close()
        return jsonify(resultado), 201

    missing = require_fields(payload, ["folio_factura", "id_tercero", "fecha_emision", "cantidad", "precio_unitario"])
    if missing:
        return error(missing)
    monto_neto = round(float(payload["cantidad"]) * float(payload["precio_unitario"]), 2)
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
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT TOP 200 oc.*, t.razon_social AS proveedor, cc.nombre_cc AS centro_costo
               FROM tbl_ordenes_compra oc
               JOIN tbl_terceros t ON t.id_tercero = oc.id_tercero
               LEFT JOIN tbl_centros_costo cc ON cc.id_centro_costo = oc.id_centro_costo
               ORDER BY oc.fecha_emision DESC, oc.id_orden_compra DESC""",
        )
        conn.close()
        return jsonify(rows)

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

    if db.DB_ENGINE == "mssql":
        # En el esquema real toda compra es de un ítem concreto del
        # catálogo (se le pasa a sp_procesar_compra_externa, que calcula
        # neto/IVA/total, mueve el kardex si corresponde y genera el
        # asiento contable correcto según el ítem).
        # IMPORTANTE: cantidad y precio_unitario reales son obligatorios:
        # si el ítem es de Reventa, la cantidad real determina cuánto
        # stock entra al kardex y a qué costo promedio (CPP) queda.
        missing = require_fields(
            payload, ["folio_oc", "id_tercero", "id_item", "fecha_emision", "cantidad", "precio_unitario"]
        )
        if missing:
            return error(missing)
        conn = db.get_conn()
        try:
            proveedor = db.fetch_one_dict(
                conn, "SELECT razon_social FROM tbl_terceros WHERE id_tercero = ?", (payload["id_tercero"],)
            )
            producto = db.fetch_one_dict(
                conn, "SELECT nombre FROM tbl_productos_servicios WHERE id_item = ?", (payload["id_item"],)
            )
            if not proveedor:
                return error("Proveedor no encontrado.")
            if not producto:
                return error("Producto/servicio no encontrado.")

            conn.execute(
                """EXEC dbo.sp_procesar_compra_externa
                       @folio_oc = ?, @fecha_emision = ?,
                       @nombre_informal_proveedor = ?, @descripcion_libre_item = ?,
                       @cantidad = ?, @precio_unitario = ?,
                       @estado_oc = ?, @id_centro_costo = ?""",
                (
                    payload["folio_oc"], payload["fecha_emision"],
                    proveedor["razon_social"], producto["nombre"],
                    float(payload["cantidad"]), float(payload["precio_unitario"]),
                    payload.get("estado_oc", "RECIBIDA"),
                    payload.get("id_centro_costo"),
                ),
            )
            conn.commit()
            resultado = db.fetch_one_dict(
                conn,
                "SELECT id_orden_compra, monto_iva, monto_total FROM tbl_ordenes_compra WHERE folio_oc = ?",
                (payload["folio_oc"],),
            )
        except Exception as exc:
            conn.rollback()
            conn.close()
            return error(f"No se pudo registrar la compra: {exc}")
        conn.close()
        return jsonify(resultado), 201

    missing = require_fields(
        payload, ["folio_documento", "id_tercero", "fecha_emision", "descripcion", "cantidad", "precio_unitario"]
    )
    if missing:
        return error(missing)
    monto_neto = round(float(payload["cantidad"]) * float(payload["precio_unitario"]), 2)
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
