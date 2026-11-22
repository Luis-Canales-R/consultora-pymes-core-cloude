"""
carga_masiva.py — utilidades genéricas para la carga masiva de catálogos
(Fase 4 de la meta "Exportación a Excel y Carga/Exportación Masiva",
2026-11-22; ver el documento de plan del proyecto para las 5 fases).

Principio de simetría export/import (acordado en el plan): la plantilla de
carga de un módulo usa, en lo posible, los mismos encabezados que produce
su exportación a Excel (ver excel_export.py), para que el usuario pueda
exportar, editar en Excel, y volver a cargar sin tener que adivinar un
formato distinto.

Principio de robustez de la carga (acordado en el plan, "lo que hace el
mercado en la vanguardia"): cada fila se valida y se procesa de forma
independiente. Una fila con un error NO bota el lote completo — las filas
válidas se cargan igual, y se devuelve un reporte claro de qué se cargó y
qué no (y por qué), fila por fila, con el número de fila tal como aparece
en el Excel (para que el usuario pueda ubicarla fácilmente).

No depende de Flask: recibe/devuelve estructuras de datos simples, así que
es fácil de testear sin un servidor corriendo.
"""

from openpyxl import load_workbook

import excel_export


def leer_filas(file_obj):
    """Lee un archivo .xlsx subido (file-like) y devuelve una lista de
    tuplas (numero_fila_excel, {encabezado: valor}).

    numero_fila_excel es 1-based y coincide con el número de fila que el
    usuario ve en Excel (la fila 1 es el encabezado, así que la primera
    fila de datos es la 2) — así el reporte de errores puede decir
    "fila 7" y que el usuario la encuentre de inmediato.

    Empareja por el TEXTO del encabezado (sin exigir un orden específico),
    para tolerar que el usuario reordene columnas o borre alguna columna
    opcional de la plantilla. Las filas completamente vacías (frecuentes al
    final de un archivo exportado y luego editado) se ignoran.
    """
    wb = load_workbook(file_obj, data_only=True)
    ws = wb.active
    filas_crudas = list(ws.iter_rows(values_only=True))
    if not filas_crudas:
        return []

    encabezados = [str(c).strip() if c is not None else "" for c in filas_crudas[0]]
    filas = []
    for idx, fila in enumerate(filas_crudas[1:], start=2):
        if fila is None or all(v is None or str(v).strip() == "" for v in fila):
            continue
        valores = {}
        for col_idx, encabezado in enumerate(encabezados):
            if encabezado and col_idx < len(fila):
                valores[encabezado] = fila[col_idx]
        filas.append((idx, valores))
    return filas


def generar_plantilla(nombre_hoja, columnas, fila_ejemplo=None):
    """Genera el archivo .xlsx de la plantilla de carga, reutilizando el
    mismo estilo que excel_export usa para las exportaciones (mismos
    encabezados con fondo azul, mismo ancho de columna aproximado).

    columnas: [(encabezado, clave, formato|None), ...] — igual formato que
    excel_export.agregar_hoja_tabla.
    fila_ejemplo: dict opcional con una fila de ejemplo (mismas claves) para
    mostrar el formato esperado de cada columna.
    """
    wb = excel_export.libro_nuevo()
    filas = [fila_ejemplo] if fila_ejemplo else []
    excel_export.agregar_hoja_tabla(wb, nombre_hoja, columnas, filas)
    return excel_export.a_bytes(wb)


def valor_texto(valores, encabezado):
    """Lee un valor de texto desde la fila parseada; None/"" quedan como
    None (no como la cadena vacía), para que las validaciones de 'requerido'
    sean consistentes con las del alta individual (ver require_fields)."""
    v = valores.get(encabezado)
    if v is None:
        return None
    s = str(v).strip()
    return s or None


def valor_bool(valores, encabezado):
    """'Sí'/'No' (o variantes: si, yes, true, 1, x) -> True/False. Vacío o
    ausente -> False (consistente con un checkbox sin marcar)."""
    v = valores.get(encabezado)
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    return s in ("sí", "si", "yes", "true", "1", "x")


def valor_numero(valores, encabezado):
    """Número de la celda. Si Excel ya la guardó como número (lo normal
    para una columna de montos), se usa directo. Si es texto (ej. pegado
    desde otra fuente con separador de miles chileno "15.000"), se intenta
    limpiar antes de convertir. Si no se puede interpretar, devuelve None
    (y el llamador lo trata como campo faltante/invalido)."""
    v = valores.get(encabezado)
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip()
    try:
        return float(s)
    except ValueError:
        pass
    try:
        # separador de miles "." + coma decimal, formato chileno
        return float(s.replace(".", "").replace(",", "."))
    except ValueError:
        return None


def procesar_carga(file_obj, columnas_lectura, requeridos, fila_a_datos, registrar_fn, conn):
    """Motor genérico de carga masiva, reutilizado por los tres catálogos.

    columnas_lectura: lista de encabezados de Excel esperados (solo
        informativo para quien lea el código; la lectura real es tolerante,
        ver leer_filas).
    requeridos: lista de claves (del dict que devuelve fila_a_datos) que no
        pueden quedar vacías.
    fila_a_datos(valores_excel) -> dict de datos para registrar_fn, ya
        convertido a los tipos correctos (ver valor_texto/valor_bool/valor_numero).
    registrar_fn(conn, datos) -> hace el INSERT (y lo que corresponda, ej.
        homologaciones) SIN hacer commit — el motor hace commit/rollback por
        fila para no perder las filas válidas si otra falla.
    conn: conexión ya abierta (db.get_conn()) — el motor no la abre ni la
        cierra, para que el llamador controle su ciclo de vida.

    Devuelve un dict con el reporte: total_filas, cargados, rechazados,
    errores (lista de {fila, motivo}).
    """
    filas = leer_filas(file_obj)
    cargados = 0
    errores = []
    for fila_excel, valores in filas:
        datos = fila_a_datos(valores)
        faltantes = [c for c in requeridos if datos.get(c) in (None, "")]
        if faltantes:
            errores.append({"fila": fila_excel, "motivo": f"Campos requeridos faltantes: {', '.join(faltantes)}"})
            continue
        try:
            registrar_fn(conn, datos)
            conn.commit()
            cargados += 1
        except Exception as exc:  # noqa: BLE001 — se reporta tal cual al usuario
            conn.rollback()
            errores.append({"fila": fila_excel, "motivo": str(exc)})
    return {
        "total_filas": len(filas),
        "cargados": cargados,
        "rechazados": len(errores),
        "errores": errores,
    }
