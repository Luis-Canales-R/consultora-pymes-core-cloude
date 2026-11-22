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

from flask import Flask, jsonify, request, send_file, send_from_directory

import db
import excel_export

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


def _obtener_terceros():
    """Factorizado para que lo use tanto el endpoint JSON (listar_terceros)
    como el de exportación a Excel, sin duplicar la consulta."""
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
    return rows


@app.route("/api/terceros", methods=["GET"])
def listar_terceros():
    return jsonify(_obtener_terceros())


@app.route("/api/terceros/export", methods=["GET"])
def exportar_terceros():
    filas = []
    for r in _obtener_terceros():
        fila = dict(r)
        fila["es_cliente"] = "Sí" if fila.get("es_cliente") else "No"
        fila["es_proveedor"] = "Sí" if fila.get("es_proveedor") else "No"
        filas.append(fila)

    columnas = [
        ("Código", "codigo_tercero", None),
        ("Razón Social", "razon_social", None),
        ("RUT/DNI", "rut_dni", None),
        ("Email", "contacto_email", None),
        ("Cliente", "es_cliente", None),
        ("Proveedor", "es_proveedor", None),
    ]
    wb = excel_export.libro_nuevo()
    excel_export.agregar_hoja_tabla(wb, "Terceros", columnas, filas)
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("terceros"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )


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


def _obtener_productos():
    """Factorizado para que lo use tanto el endpoint JSON (listar_productos)
    como el de exportación a Excel, sin duplicar la consulta."""
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
    return rows


@app.route("/api/productos", methods=["GET"])
def listar_productos():
    return jsonify(_obtener_productos())


@app.route("/api/productos/export", methods=["GET"])
def exportar_productos():
    filas = []
    for r in _obtener_productos():
        fila = dict(r)
        fila["aplica_iva"] = "Afecto" if fila.get("aplica_iva") else "Exento"
        filas.append(fila)

    columnas = [("SKU", "sku_codigo", None), ("Nombre", "nombre", None)]
    if db.DB_ENGINE == "mssql":
        columnas += [("Tipo", "tipo_item", None), ("Categoría", "categoria", None), ("Unidad de Medida", "unidad_medida", None)]
    columnas += [
        ("Precio Venta Base", "precio_venta_base", excel_export.FORMATO_MONEDA),
        ("IVA", "aplica_iva", None),
        ("Modo Obtención", "modo_obtencion", None),
    ]
    wb = excel_export.libro_nuevo()
    excel_export.agregar_hoja_tabla(wb, "Productos", columnas, filas)
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("productos"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )


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


def _obtener_centros_costo():
    """Factorizado para que lo use tanto el endpoint JSON (listar_centros_costo)
    como el de exportación a Excel, sin duplicar la consulta."""
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
    return rows


@app.route("/api/centros_costo", methods=["GET"])
def listar_centros_costo():
    return jsonify(_obtener_centros_costo())


@app.route("/api/centros_costo/export", methods=["GET"])
def exportar_centros_costo():
    filas = _obtener_centros_costo()
    columnas = []
    if db.DB_ENGINE == "mssql":
        columnas.append(("Código", "codigo_cc", None))
    columnas.append(("Nombre", "nombre", None))

    wb = excel_export.libro_nuevo()
    excel_export.agregar_hoja_tabla(wb, "Centros de Costo", columnas, filas)
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("centros_costo"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )


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


def _validar_lineas(payload):
    """Valida el arreglo 'lineas' (documento multi-ítem). Devuelve un
    mensaje de error (str) o None si está bien formado."""
    lineas = payload.get("lineas")
    if not isinstance(lineas, list) or len(lineas) == 0:
        return "Falta 'lineas' (debe ser una lista con al menos un ítem)."
    for i, linea in enumerate(lineas, start=1):
        for campo in ("id_item", "cantidad", "precio_unitario"):
            if linea.get(campo) in (None, ""):
                return f"Línea {i}: falta '{campo}'."
    return None


@app.route("/api/ventas", methods=["POST"])
def crear_venta():
    payload = request.get_json(force=True)

    if db.DB_ENGINE == "mssql":
        # En el esquema real una venta es un DOCUMENTO (folio) con una o
        # varias líneas, cada una de un ítem/servicio concreto (se pasa a
        # sp_procesar_venta_externa, que calcula neto/IVA/total y genera
        # el asiento contable correcto según cada ítem). Todas las líneas
        # se procesan en UNA sola conexión/transacción: o se registran
        # todas, o no se registra ninguna (atomicidad del documento
        # completo, igual que en un ERP real).
        missing = require_fields(payload, ["folio_factura", "id_tercero", "fecha_emision"])
        if missing:
            return error(missing)
        err = _validar_lineas(payload)
        if err:
            return error(err)

        conn = db.get_conn()
        try:
            cliente = db.fetch_one_dict(
                conn, "SELECT razon_social FROM tbl_terceros WHERE id_tercero = ?", (payload["id_tercero"],)
            )
            if not cliente:
                return error("Cliente no encontrado.")

            # Todas las líneas de este folio se enlazan al MISMO asiento
            # contable (patrón ERP real: un documento = un asiento, con
            # varias líneas) -- ver sp_registrar_asiento_contable. La
            # primera línea crea el asiento (id_asiento_existente = NULL);
            # cada línea siguiente reenvía el id_asiento devuelto por la
            # anterior, para que se le agreguen sus propias líneas contables
            # en vez de crear un asiento nuevo.
            id_asiento_actual = None
            for i, linea in enumerate(payload["lineas"], start=1):
                producto = db.fetch_one_dict(
                    conn, "SELECT nombre FROM tbl_productos_servicios WHERE id_item = ?", (linea["id_item"],)
                )
                if not producto:
                    raise ValueError(f"Línea {i}: producto/servicio no encontrado.")

                cur = conn.execute(
                    """EXEC dbo.sp_procesar_venta_externa
                           @folio_factura = ?, @fecha_emision = ?,
                           @nombre_informal_cliente = ?, @descripcion_libre_item = ?,
                           @cantidad = ?, @precio_unitario = ?,
                           @estado_venta = ?, @id_centro_costo = ?,
                           @id_asiento_existente = ?""",
                    (
                        payload["folio_factura"], payload["fecha_emision"],
                        cliente["razon_social"], producto["nombre"],
                        float(linea["cantidad"]), float(linea["precio_unitario"]),
                        payload.get("estado_venta", "DEVENGADO"),
                        payload.get("id_centro_costo"),
                        id_asiento_actual,
                    ),
                )
                # El SP devuelve el id_asiento como un SELECT propio (no como
                # parámetro OUTPUT -- pyodbc no lo maneja bien en un solo EXEC).
                fila_asiento = cur.fetchone()
                if fila_asiento and fila_asiento[0]:
                    id_asiento_actual = fila_asiento[0]

            conn.commit()
            resultado = db.fetch_one_dict(
                conn,
                "SELECT id_venta_devengada, monto_iva, monto_total FROM tbl_ventas_devengadas WHERE folio_factura = ?",
                (payload["folio_factura"],),
            )
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass  # el SP ya pudo haber hecho su propio ROLLBACK ante el error
            conn.close()
            return error(f"No se pudo registrar la venta: {exc}")
        conn.close()
        return jsonify(resultado), 201

    missing = require_fields(payload, ["folio_factura", "id_tercero", "fecha_emision"])
    if missing:
        return error(missing)
    err = _validar_lineas(payload)
    if err:
        return error(err)
    monto_neto = round(
        sum(float(l["cantidad"]) * float(l["precio_unitario"]) for l in payload["lineas"]), 2
    )
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
        # En el esquema real una compra es un DOCUMENTO (folio) con una o
        # varias líneas, cada una de un ítem concreto del catálogo (se pasa
        # a sp_procesar_compra_externa, que calcula neto/IVA/total, mueve
        # el kardex si corresponde y genera el asiento contable correcto
        # según cada ítem). Todas las líneas se procesan en UNA sola
        # conexión/transacción: o se registran todas, o no se registra
        # ninguna (atomicidad del documento completo, igual que en un ERP
        # real).
        missing = require_fields(payload, ["folio_oc", "id_tercero", "fecha_emision"])
        if missing:
            return error(missing)
        err = _validar_lineas(payload)
        if err:
            return error(err)

        conn = db.get_conn()
        try:
            proveedor = db.fetch_one_dict(
                conn, "SELECT razon_social FROM tbl_terceros WHERE id_tercero = ?", (payload["id_tercero"],)
            )
            if not proveedor:
                return error("Proveedor no encontrado.")

            # Todas las líneas de este folio se enlazan al MISMO asiento
            # contable (patrón ERP real: un documento = un asiento, con
            # varias líneas) -- ver sp_registrar_asiento_contable. La
            # primera línea crea el asiento (id_asiento_existente = NULL);
            # cada línea siguiente reenvía el id_asiento devuelto por la
            # anterior, para que se le agreguen sus propias líneas contables
            # en vez de crear un asiento nuevo.
            id_asiento_actual = None
            for i, linea in enumerate(payload["lineas"], start=1):
                producto = db.fetch_one_dict(
                    conn, "SELECT nombre FROM tbl_productos_servicios WHERE id_item = ?", (linea["id_item"],)
                )
                if not producto:
                    raise ValueError(f"Línea {i}: producto/servicio no encontrado.")

                cur = conn.execute(
                    """EXEC dbo.sp_procesar_compra_externa
                           @folio_oc = ?, @fecha_emision = ?,
                           @nombre_informal_proveedor = ?, @descripcion_libre_item = ?,
                           @cantidad = ?, @precio_unitario = ?,
                           @estado_oc = ?, @id_centro_costo = ?,
                           @id_asiento_existente = ?""",
                    (
                        payload["folio_oc"], payload["fecha_emision"],
                        proveedor["razon_social"], producto["nombre"],
                        float(linea["cantidad"]), float(linea["precio_unitario"]),
                        payload.get("estado_oc", "RECIBIDA"),
                        payload.get("id_centro_costo"),
                        id_asiento_actual,
                    ),
                )
                # El SP devuelve el id_asiento como un SELECT propio (no como
                # parámetro OUTPUT -- pyodbc no lo maneja bien en un solo EXEC).
                fila_asiento = cur.fetchone()
                if fila_asiento and fila_asiento[0]:
                    id_asiento_actual = fila_asiento[0]

            conn.commit()
            resultado = db.fetch_one_dict(
                conn,
                "SELECT id_orden_compra, monto_iva, monto_total FROM tbl_ordenes_compra WHERE folio_oc = ?",
                (payload["folio_oc"],),
            )
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass  # el SP ya pudo haber hecho su propio ROLLBACK ante el error
            conn.close()
            return error(f"No se pudo registrar la compra: {exc}")
        conn.close()
        return jsonify(resultado), 201

    missing = require_fields(
        payload, ["folio_documento", "id_tercero", "fecha_emision", "descripcion"]
    )
    if missing:
        return error(missing)
    err = _validar_lineas(payload)
    if err:
        return error(err)
    monto_neto = round(
        sum(float(l["cantidad"]) * float(l["precio_unitario"]) for l in payload["lineas"]), 2
    )
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

@app.route("/api/catalogos/cuentas-tesoreria", methods=["GET"])
def listar_cuentas_tesoreria():
    """Cuentas de Caja/Banco disponibles para registrar un movimiento.

    En modo real (mssql) son las cuentas imputables bajo "Disponible y
    Equivalentes de Efectivo" (Caja Chica, Banco Principal, Depósitos a
    Plazo) del plan de cuentas. En modo demo (sqlite, que no tiene plan de
    cuentas real) se devuelve una única cuenta genérica -- el campo existe
    igual para que el formulario sea consistente entre ambos modos, pero
    el backend sqlite no la usa para nada contable (ver crear_movimiento_caja).
    """
    if db.DB_ENGINE == "mssql":
        conn = db.get_conn()
        rows = db.fetch_dicts(
            conn,
            """SELECT codigo_cuenta, nombre_cuenta
               FROM cat_plan_cuentas
               WHERE id_cuenta_padre = 111 AND es_imputable = 1
               ORDER BY codigo_cuenta""",
        )
        conn.close()
        return jsonify(rows)
    return jsonify([{"codigo_cuenta": "CAJA-DEMO", "nombre_cuenta": "Caja / Banco (modo demo SQLite)"}])


@app.route("/api/caja", methods=["GET"])
def listar_caja():
    conn = db.get_conn()
    if db.DB_ENGINE == "mssql":
        rows = db.fetch_dicts(
            conn,
            """SELECT m.id_movimiento, m.fecha_movimiento, m.tipo_flujo, m.monto_absoluto, m.glosa_movimiento,
                      cp.nombre_cuenta AS cuenta_tesoreria, t.razon_social AS tercero, c.nombre_cc AS centro_costo
               FROM tbl_movimientos_caja m
               LEFT JOIN cat_plan_cuentas cp ON cp.id_cuenta = m.id_cuenta_bancaria
               LEFT JOIN tbl_terceros t ON t.id_tercero = m.id_tercero
               LEFT JOIN tbl_centros_costo c ON c.id_centro_costo = m.id_centro_costo
               ORDER BY m.fecha_movimiento DESC, m.id_movimiento DESC
               OFFSET 0 ROWS FETCH NEXT 200 ROWS ONLY""",
        )
        conn.close()
        return jsonify(rows)

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
    if payload["tipo_flujo"] not in ("INGRESO", "EGRESO", "TRASPASO"):
        return error("tipo_flujo inválido")

    if db.DB_ENGINE == "mssql":
        missing_mssql = require_fields(payload, ["codigo_cuenta_origen"])
        if missing_mssql:
            return error(missing_mssql)
        if payload["tipo_flujo"] == "TRASPASO" and not payload.get("codigo_cuenta_destino"):
            return error("Un traspaso requiere indicar la cuenta de destino.")

        conn = db.get_conn()
        try:
            nombre_tercero = None
            if payload.get("id_tercero"):
                tercero = db.fetch_one_dict(
                    conn, "SELECT razon_social FROM tbl_terceros WHERE id_tercero = ?", (payload["id_tercero"],)
                )
                if not tercero:
                    raise ValueError("Tercero no encontrado.")
                nombre_tercero = tercero["razon_social"]

            cur = conn.execute(
                """EXEC dbo.sp_procesar_movimiento_caja_externo
                       @fecha_movimiento = ?, @tipo_flujo = ?, @monto_absoluto = ?,
                       @glosa_movimiento = ?, @codigo_cuenta_origen = ?, @codigo_cuenta_destino = ?,
                       @nombre_informal_tercero = ?, @id_centro_costo = ?""",
                (
                    payload["fecha_movimiento"], payload["tipo_flujo"], float(payload["monto_absoluto"]),
                    payload["glosa_movimiento"], payload["codigo_cuenta_origen"],
                    payload.get("codigo_cuenta_destino"), nombre_tercero, payload.get("id_centro_costo"),
                ),
            )
            fila = cur.fetchone()
            conn.commit()
        except Exception as exc:
            try:
                conn.rollback()
            except Exception:
                pass
            conn.close()
            return error(f"No se pudo registrar el movimiento: {exc}")
        conn.close()
        return jsonify({"id_movimiento": fila[0] if fila else None}), 201

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

    if db.DB_ENGINE == "mssql":
        # Estado de Resultados real (acumulado, todos los periodos), calculado
        # por el motor contable a partir de los asientos (vw_estado_resultados).
        er_rows = db.fetch_dicts(
            conn,
            """SELECT tipo_cuenta, COALESCE(SUM(monto_periodo), 0) AS total
               FROM vw_estado_resultados
               GROUP BY tipo_cuenta""",
        )
        er_por_tipo = {r["tipo_cuenta"]: r["total"] for r in er_rows}
        ingresos_total = float(er_por_tipo.get("INGRESO", 0) or 0)
        costos_gastos_total = float(er_por_tipo.get("COSTO", 0) or 0) + float(er_por_tipo.get("GASTO", 0) or 0)

        # Balance General real (saldo acumulado a la fecha, vw_balance_general).
        bg_rows = db.fetch_dicts(
            conn,
            """SELECT tipo_cuenta, COALESCE(SUM(saldo), 0) AS total
               FROM vw_balance_general
               GROUP BY tipo_cuenta""",
        )
        bg_por_tipo = {r["tipo_cuenta"]: r["total"] for r in bg_rows}
        total_activo = float(bg_por_tipo.get("ACTIVO", 0) or 0)
        total_pasivo = float(bg_por_tipo.get("PASIVO", 0) or 0)
        total_patrimonio = float(bg_por_tipo.get("PATRIMONIO", 0) or 0)

        # Saldo de caja real: suma de las cuentas imputables bajo "Disponible y
        # Equivalentes de Efectivo" (mismo filtro que /catalogos/cuentas-tesoreria).
        saldo_caja_row = db.fetch_one_dict(
            conn,
            """SELECT COALESCE(SUM(vbg.saldo), 0) AS saldo
               FROM vw_balance_general vbg
               JOIN cat_plan_cuentas cp ON cp.id_cuenta = vbg.id_cuenta
               WHERE cp.id_cuenta_padre = 111""",
        )
        saldo_caja = float(saldo_caja_row["saldo"]) if saldo_caja_row and saldo_caja_row["saldo"] is not None else 0.0

        ventas_count_row = db.fetch_one_dict(
            conn,
            "SELECT COUNT(*) AS n FROM tbl_ventas_devengadas WHERE estado_venta != 'ANULADO'",
        )
        compras_count_row = db.fetch_one_dict(
            conn,
            "SELECT COUNT(*) AS n FROM tbl_ordenes_compra WHERE estado_oc != 'ANULADA'",
        )

        # Ingresos vs. Costos+Gastos por periodo contable, para el gráfico
        # mensual (mismo formato 'YYYY-MM' que usa el modo demo sqlite).
        ingresos_por_mes = db.fetch_dicts(
            conn,
            """SELECT periodo_contable AS mes, COALESCE(SUM(monto_periodo), 0) AS neto
               FROM vw_estado_resultados
               WHERE tipo_cuenta = 'INGRESO'
               GROUP BY periodo_contable
               ORDER BY periodo_contable""",
        )
        costos_gastos_por_mes = db.fetch_dicts(
            conn,
            """SELECT periodo_contable AS mes, COALESCE(SUM(monto_periodo), 0) AS neto
               FROM vw_estado_resultados
               WHERE tipo_cuenta IN ('COSTO', 'GASTO')
               GROUP BY periodo_contable
               ORDER BY periodo_contable""",
        )

        conn.close()

        return jsonify(
            {
                "ventas_neto": ingresos_total,
                "ventas_count": ventas_count_row["n"] if ventas_count_row else 0,
                "compras_neto": costos_gastos_total,
                "compras_count": compras_count_row["n"] if compras_count_row else 0,
                "margen_bruto": ingresos_total - costos_gastos_total,
                "saldo_caja": saldo_caja,
                "ventas_por_mes": ingresos_por_mes,
                "compras_por_mes": costos_gastos_por_mes,
                # Balance General real: no consumido todavía por el frontend
                # actual (solo tiene tarjetas de ventas/compras/margen/caja),
                # se expone ya en la API para la próxima iteración del Dashboard.
                "total_activo": total_activo,
                "total_pasivo": total_pasivo,
                "total_patrimonio": total_patrimonio,
            }
        )

    # ---- Modo demo (sqlite): sin motor contable real, se aproxima el
    # Dashboard sumando directo sobre las tablas operativas. ----
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



# ---------------------------------------------------------------------------
# Informes Financieros Avanzados (Controller): Balance de 8 Columnas y
# Comparación entre Periodos. Solo tienen sentido en modo mssql, porque
# dependen de un plan de cuentas real (cat_plan_cuentas) que el prototipo
# SQLite no modela.
# ---------------------------------------------------------------------------

def _obtener_balance_ocho_columnas():
    """Devuelve (cuentas, totales) desde vw_balance_ocho_columnas. Factorizado
    para que lo use tanto el endpoint JSON como el de exportación a Excel,
    sin duplicar la consulta ni la suma de totales."""
    conn = db.get_conn()
    cuentas = db.fetch_dicts(
        conn,
        """SELECT codigo_cuenta, nombre_cuenta, tipo_cuenta, naturaleza,
                  suma_debe, suma_haber, saldo_deudor, saldo_acreedor,
                  inventario_activo, inventario_pasivo, inventario_patrimonio,
                  perdida, ganancia
           FROM vw_balance_ocho_columnas
           ORDER BY codigo_cuenta""",
    )
    conn.close()

    totales = {
        "suma_debe": 0.0, "suma_haber": 0.0,
        "saldo_deudor": 0.0, "saldo_acreedor": 0.0,
        "inventario_activo": 0.0, "inventario_pasivo": 0.0, "inventario_patrimonio": 0.0,
        "perdida": 0.0, "ganancia": 0.0,
    }
    for c in cuentas:
        for clave in totales:
            totales[clave] += float(c[clave] or 0)
    return cuentas, totales


@app.route("/api/informes/balance-8-columnas", methods=["GET"])
def informe_balance_ocho_columnas():
    if db.DB_ENGINE != "mssql":
        return jsonify({"modo_demo": True, "cuentas": []})

    cuentas, totales = _obtener_balance_ocho_columnas()
    return jsonify({"modo_demo": False, "cuentas": cuentas, "totales": totales})


@app.route("/api/informes/balance-8-columnas/export", methods=["GET"])
def exportar_balance_ocho_columnas():
    if db.DB_ENGINE != "mssql":
        return error("La exportación a Excel requiere el motor contable real (DB_ENGINE=mssql).", 400)

    cuentas, totales = _obtener_balance_ocho_columnas()
    wb = excel_export.libro_nuevo()
    excel_export.agregar_hoja_balance_ocho_columnas(wb, cuentas, totales)
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("balance_8_columnas"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )


def _mes_anterior(periodo):
    """'YYYY-MM' -> 'YYYY-MM' del mes calendario inmediatamente anterior."""
    anio, mes = int(periodo[:4]), int(periodo[5:7])
    if mes == 1:
        anio, mes = anio - 1, 12
    else:
        mes -= 1
    return f"{anio:04d}-{mes:02d}"


def _mismo_mes_anio_anterior(periodo):
    """'YYYY-MM' -> mismo mes, un año antes."""
    anio, mes = int(periodo[:4]), int(periodo[5:7])
    return f"{anio - 1:04d}-{mes:02d}"


def _variacion(actual, base):
    """Variación absoluta y porcentual de 'actual' respecto a 'base'.
    Devuelve None en ambos campos si no hay dato base con que comparar
    (periodo inexistente), y porcentual None si la base es 0 (evita
    división por cero cuando se parte de cero)."""
    if base is None:
        return {"absoluta": None, "porcentual": None}
    absoluta = actual - base
    porcentual = (absoluta / base * 100.0) if base != 0 else None
    return {"absoluta": absoluta, "porcentual": porcentual}


def calcular_comparacion_periodos(filas):
    """Recibe una lista de dicts {mes, ingresos, costos_gastos, resultado}
    (uno por periodo 'YYYY-MM', ya agregados) y agrega, a cada uno, sus
    variaciones mes-a-mes (MoM) y respecto al mismo mes del año anterior
    (YoY). También arma el acumulado año-a-la-fecha (YTD) por año,
    comparado contra el mismo rango del año anterior. Es una función pura
    (sin acceso a BD) para poder testearla directo con datos de ejemplo.
    """
    por_mes = {f["mes"]: f for f in filas}

    periodos = []
    for fila in sorted(filas, key=lambda f: f["mes"]):
        mes = fila["mes"]
        anterior = por_mes.get(_mes_anterior(mes))
        mismo_anio_anterior = por_mes.get(_mismo_mes_anio_anterior(mes))

        entrada = dict(fila)
        entrada["var_mom"] = {
            "ingresos": _variacion(fila["ingresos"], anterior["ingresos"] if anterior else None),
            "costos_gastos": _variacion(fila["costos_gastos"], anterior["costos_gastos"] if anterior else None),
            "resultado": _variacion(fila["resultado"], anterior["resultado"] if anterior else None),
        }
        entrada["var_yoy"] = {
            "ingresos": _variacion(fila["ingresos"], mismo_anio_anterior["ingresos"] if mismo_anio_anterior else None),
            "costos_gastos": _variacion(fila["costos_gastos"], mismo_anio_anterior["costos_gastos"] if mismo_anio_anterior else None),
            "resultado": _variacion(fila["resultado"], mismo_anio_anterior["resultado"] if mismo_anio_anterior else None),
        }
        periodos.append(entrada)

    # Acumulado Año a la Fecha (YTD): para cada año presente, se acumula
    # Enero..mes_X y se compara contra el mismo rango (Enero..mes_X) del
    # año anterior, mes a mes (no contra el año completo anterior).
    anios = sorted({int(f["mes"][:4]) for f in filas})
    ytd = []
    for anio in anios:
        meses_anio = sorted(m for m in por_mes if m.startswith(f"{anio:04d}-"))
        acumulado = {"ingresos": 0.0, "costos_gastos": 0.0, "resultado": 0.0}
        acumulado_anio_anterior = {"ingresos": 0.0, "costos_gastos": 0.0, "resultado": 0.0}
        hay_anio_anterior = True
        for m in meses_anio:
            for clave in acumulado:
                acumulado[clave] += por_mes[m][clave]
            previo = por_mes.get(_mismo_mes_anio_anterior(m))
            if previo is None:
                hay_anio_anterior = False
                continue
            for clave in acumulado_anio_anterior:
                acumulado_anio_anterior[clave] += previo[clave]

        ultimo_mes = meses_anio[-1][5:7] if meses_anio else None
        entrada_ytd = {
            "anio": anio,
            "hasta_mes": ultimo_mes,
            "ingresos_ytd": acumulado["ingresos"],
            "costos_gastos_ytd": acumulado["costos_gastos"],
            "resultado_ytd": acumulado["resultado"],
        }
        if hay_anio_anterior and meses_anio:
            entrada_ytd["var_yoy_ytd"] = {
                "ingresos": _variacion(acumulado["ingresos"], acumulado_anio_anterior["ingresos"]),
                "costos_gastos": _variacion(acumulado["costos_gastos"], acumulado_anio_anterior["costos_gastos"]),
                "resultado": _variacion(acumulado["resultado"], acumulado_anio_anterior["resultado"]),
            }
        else:
            entrada_ytd["var_yoy_ytd"] = {
                "ingresos": {"absoluta": None, "porcentual": None},
                "costos_gastos": {"absoluta": None, "porcentual": None},
                "resultado": {"absoluta": None, "porcentual": None},
            }
        ytd.append(entrada_ytd)

    return {"periodos": periodos, "ytd": ytd}


def _obtener_comparacion_periodos():
    """Devuelve {'periodos':.., 'ytd':..} desde vw_estado_resultados. Factorizado
    para que lo use tanto el endpoint JSON como el de exportación a Excel."""
    conn = db.get_conn()
    filas_er = db.fetch_dicts(
        conn,
        """SELECT periodo_contable AS mes, tipo_cuenta, COALESCE(SUM(monto_periodo), 0) AS total
           FROM vw_estado_resultados
           GROUP BY periodo_contable, tipo_cuenta""",
    )
    conn.close()

    por_mes = {}
    for f in filas_er:
        fila = por_mes.setdefault(f["mes"], {"mes": f["mes"], "ingresos": 0.0, "costos_gastos": 0.0})
        if f["tipo_cuenta"] == "INGRESO":
            fila["ingresos"] += float(f["total"] or 0)
        elif f["tipo_cuenta"] in ("COSTO", "GASTO"):
            fila["costos_gastos"] += float(f["total"] or 0)
    for fila in por_mes.values():
        fila["resultado"] = fila["ingresos"] - fila["costos_gastos"]

    return calcular_comparacion_periodos(list(por_mes.values()))


@app.route("/api/informes/comparacion-periodos", methods=["GET"])
def informe_comparacion_periodos():
    if db.DB_ENGINE != "mssql":
        return jsonify({"modo_demo": True, "periodos": [], "ytd": []})

    resultado = _obtener_comparacion_periodos()
    return jsonify({"modo_demo": False, **resultado})


@app.route("/api/informes/comparacion-periodos/export", methods=["GET"])
def exportar_comparacion_periodos():
    if db.DB_ENGINE != "mssql":
        return error("La exportación a Excel requiere el motor contable real (DB_ENGINE=mssql).", 400)

    resultado = _obtener_comparacion_periodos()
    wb = excel_export.libro_nuevo()
    excel_export.agregar_hojas_comparacion_periodos(wb, resultado["periodos"], resultado["ytd"])
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("comparacion_periodos"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )



# ---------------------------------------------------------------------------
# Informes Financieros Avanzados: KPIs de Liquidez, Apalancamiento y
# Rentabilidad. Requiere cat_plan_cuentas.clasificacion_corriente
# (sql/agregar_clasificacion_corriente.sql) para la parte de Liquidez.
# ---------------------------------------------------------------------------

def _razon(numerador, denominador):
    """Division segura: None si el denominador es 0 (ratio no definido),
    en vez de reventar o devolver infinito."""
    if not denominador:
        return None
    return numerador / denominador


def _pct(numerador, denominador):
    r = _razon(numerador, denominador)
    return None if r is None else r * 100.0


def calcular_kpis(cuentas_balance, totales_resultado):
    """KPIs estandar de controller (formulas de finanzas corporativas, no
    criterios propios). cuentas_balance: lista de dicts {codigo_cuenta,
    tipo_cuenta, clasificacion_corriente, saldo} (una fila por cuenta
    imputable de Balance, ej. desde vw_balance_general). totales_resultado:
    dict {'INGRESO':..,'COSTO':..,'GASTO':..} ya agregados (ej. desde
    vw_estado_resultados). Funcion pura, testeable sin DB.

    'Inventario', para la Prueba Acida, se identifica por el codigo_cuenta
    del grupo 'Existencias e Inventarios' (1.1.04.*) del plan de cuentas
    estandar cargado -- una convencion de ESTE plan de cuentas, no un
    estandar universal, documentada aqui por si el plan de cuentas cambia.
    """
    activo_total = sum(c["saldo"] for c in cuentas_balance if c["tipo_cuenta"] == "ACTIVO")
    pasivo_total = sum(c["saldo"] for c in cuentas_balance if c["tipo_cuenta"] == "PASIVO")
    patrimonio_total = sum(c["saldo"] for c in cuentas_balance if c["tipo_cuenta"] == "PATRIMONIO")
    activo_corriente = sum(
        c["saldo"] for c in cuentas_balance
        if c["tipo_cuenta"] == "ACTIVO" and c.get("clasificacion_corriente") is True
    )
    pasivo_corriente = sum(
        c["saldo"] for c in cuentas_balance
        if c["tipo_cuenta"] == "PASIVO" and c.get("clasificacion_corriente") is True
    )
    inventario = sum(
        c["saldo"] for c in cuentas_balance
        if str(c.get("codigo_cuenta") or "").startswith("1.1.04.")
    )

    ingresos = totales_resultado.get("INGRESO", 0.0)
    costo = totales_resultado.get("COSTO", 0.0)
    gasto = totales_resultado.get("GASTO", 0.0)
    resultado_neto = ingresos - costo - gasto

    return {
        "liquidez": {
            "activo_corriente": activo_corriente,
            "pasivo_corriente": pasivo_corriente,
            "inventario": inventario,
            "capital_trabajo": activo_corriente - pasivo_corriente,
            "razon_corriente": _razon(activo_corriente, pasivo_corriente),
            "prueba_acida": _razon(activo_corriente - inventario, pasivo_corriente),
        },
        "apalancamiento": {
            "activo_total": activo_total,
            "pasivo_total": pasivo_total,
            "patrimonio_total": patrimonio_total,
            "endeudamiento": _razon(pasivo_total, activo_total),
            "deuda_patrimonio": _razon(pasivo_total, patrimonio_total),
        },
        "rentabilidad": {
            "ingresos": ingresos,
            "costo": costo,
            "gasto": gasto,
            "resultado_neto": resultado_neto,
            "margen_bruto_pct": _pct(ingresos - costo, ingresos),
            "margen_neto_pct": _pct(resultado_neto, ingresos),
            "roe_pct": _pct(resultado_neto, patrimonio_total),
            "roa_pct": _pct(resultado_neto, activo_total),
        },
    }


def _obtener_kpis():
    """Devuelve el dict de KPIs (liquidez/apalancamiento/rentabilidad).
    Factorizado para que lo use tanto el endpoint JSON como el de
    exportación a Excel."""
    conn = db.get_conn()
    cuentas_balance = db.fetch_dicts(
        conn,
        """SELECT codigo_cuenta, tipo_cuenta, clasificacion_corriente, saldo
           FROM vw_balance_general""",
    )
    filas_resultado = db.fetch_dicts(
        conn,
        """SELECT tipo_cuenta, COALESCE(SUM(monto_periodo), 0) AS total
           FROM vw_estado_resultados
           GROUP BY tipo_cuenta""",
    )
    conn.close()

    for c in cuentas_balance:
        valor = c.get("clasificacion_corriente")
        c["clasificacion_corriente"] = None if valor is None else bool(valor)
        c["saldo"] = float(c["saldo"] or 0)

    totales_resultado = {f["tipo_cuenta"]: float(f["total"] or 0) for f in filas_resultado}

    return calcular_kpis(cuentas_balance, totales_resultado)


@app.route("/api/informes/kpis", methods=["GET"])
def informe_kpis():
    if db.DB_ENGINE != "mssql":
        return jsonify({"modo_demo": True})

    kpis = _obtener_kpis()
    return jsonify({"modo_demo": False, **kpis})


@app.route("/api/informes/kpis/export", methods=["GET"])
def exportar_kpis():
    if db.DB_ENGINE != "mssql":
        return error("La exportación a Excel requiere el motor contable real (DB_ENGINE=mssql).", 400)

    kpis = _obtener_kpis()
    wb = excel_export.libro_nuevo()
    excel_export.agregar_hoja_kpis(wb, kpis)
    return send_file(
        excel_export.a_bytes(wb),
        as_attachment=True,
        download_name=excel_export.nombre_archivo("kpis"),
        mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )


if __name__ == "__main__":
    db.init_db()
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port, debug=True)
