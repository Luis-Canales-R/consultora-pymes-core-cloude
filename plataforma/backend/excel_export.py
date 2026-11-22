"""
excel_export.py — generación de archivos .xlsx para los Informes de la
plataforma (Fase 1 de la meta "Exportación a Excel y Carga/Exportación
Masiva", 2026-11-22).

Usa openpyxl. La idea es centralizar aquí el estilo (encabezados, formato
de números/porcentajes, fila de totales, ancho de columna) para que cada
endpoint de exportación en app.py solo tenga que describir SUS datos
(columnas + filas), no reinventar el formateo cada vez.

No depende de Flask ni de la base de datos: recibe listas de dicts ya
armadas por el endpoint (los mismos dicts que hoy se devuelven como JSON),
así que es fácil de testear sin DB.
"""

import io
from datetime import datetime

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

FORMATO_MONEDA = "#,##0"
FORMATO_RATIO = "0.00"
FORMATO_PORCENTAJE = '0.0"%"'

_HEADER_FILL = PatternFill(start_color="1F4E78", end_color="1F4E78", fill_type="solid")
_HEADER_FONT = Font(color="FFFFFF", bold=True)
_TOTAL_FONT = Font(bold=True)


def _escribir_encabezados(ws, encabezados, fila=1):
    for col_idx, texto in enumerate(encabezados, start=1):
        celda = ws.cell(row=fila, column=col_idx, value=texto)
        celda.font = _HEADER_FONT
        celda.fill = _HEADER_FILL
        celda.alignment = Alignment(horizontal="center", wrap_text=True)
    ws.freeze_panes = ws.cell(row=fila + 1, column=1).coordinate


def _escribir_celda(ws, fila, col, valor, formato=None, negrita=False):
    celda = ws.cell(row=fila, column=col)
    if valor is None:
        celda.value = "N/D"
    else:
        celda.value = valor
        if formato and isinstance(valor, (int, float)) and not isinstance(valor, bool):
            celda.number_format = formato
    if negrita:
        celda.font = _TOTAL_FONT
    return celda


def _ajustar_anchos(ws, columnas, filas):
    """Ancho aproximado por columna (openpyxl no mide texto renderizado)."""
    for col_idx, (encabezado, clave, _formato) in enumerate(columnas, start=1):
        max_len = len(str(encabezado))
        for fila in filas:
            valor = fila.get(clave)
            texto = "N/D" if valor is None else str(valor)
            max_len = max(max_len, len(texto))
        ws.column_dimensions[get_column_letter(col_idx)].width = min(max(max_len + 2, 10), 42)


def agregar_hoja_tabla(wb, nombre, columnas, filas, totales=None):
    """Hoja genérica para una tabla homogénea (todas las filas tienen la
    misma forma). columnas: list of (encabezado, clave, formato|None).
    filas: list of dict. totales: dict opcional (mismas claves), se agrega
    como última fila en negrita."""
    ws = wb.create_sheet(title=nombre[:31])
    _escribir_encabezados(ws, [c[0] for c in columnas])

    fila_excel = 2
    for fila in filas:
        for col_idx, (_encabezado, clave, formato) in enumerate(columnas, start=1):
            _escribir_celda(ws, fila_excel, col_idx, fila.get(clave), formato)
        fila_excel += 1

    if totales is not None:
        for col_idx, (_encabezado, clave, formato) in enumerate(columnas, start=1):
            _escribir_celda(ws, fila_excel, col_idx, totales.get(clave), formato, negrita=True)

    _ajustar_anchos(ws, columnas, filas)
    return ws


def agregar_hoja_kpis(wb, kpis):
    """Hoja a medida para /api/informes/kpis: cada indicador tiene su
    propio tipo de formato (monto, razón o porcentaje), así que no encaja
    en el modelo de columnas homogéneas de agregar_hoja_tabla."""
    ws = wb.create_sheet(title="KPIs")
    _escribir_encabezados(ws, ["Categoría", "Indicador", "Valor"])

    liq = kpis["liquidez"]
    apa = kpis["apalancamiento"]
    ren = kpis["rentabilidad"]
    filas = [
        ("Liquidez", "Activo Corriente", liq["activo_corriente"], FORMATO_MONEDA),
        ("Liquidez", "Pasivo Corriente", liq["pasivo_corriente"], FORMATO_MONEDA),
        ("Liquidez", "Inventario", liq["inventario"], FORMATO_MONEDA),
        ("Liquidez", "Capital de Trabajo", liq["capital_trabajo"], FORMATO_MONEDA),
        ("Liquidez", "Razón Corriente", liq["razon_corriente"], FORMATO_RATIO),
        ("Liquidez", "Prueba Ácida", liq["prueba_acida"], FORMATO_RATIO),
        ("Apalancamiento", "Activo Total", apa["activo_total"], FORMATO_MONEDA),
        ("Apalancamiento", "Pasivo Total", apa["pasivo_total"], FORMATO_MONEDA),
        ("Apalancamiento", "Patrimonio Total", apa["patrimonio_total"], FORMATO_MONEDA),
        ("Apalancamiento", "Endeudamiento (Pasivo/Activo)", apa["endeudamiento"], FORMATO_RATIO),
        ("Apalancamiento", "Deuda/Patrimonio", apa["deuda_patrimonio"], FORMATO_RATIO),
        ("Rentabilidad", "Ingresos", ren["ingresos"], FORMATO_MONEDA),
        ("Rentabilidad", "Costo", ren["costo"], FORMATO_MONEDA),
        ("Rentabilidad", "Gasto", ren["gasto"], FORMATO_MONEDA),
        ("Rentabilidad", "Resultado Neto", ren["resultado_neto"], FORMATO_MONEDA),
        ("Rentabilidad", "Margen Bruto %", ren["margen_bruto_pct"], FORMATO_PORCENTAJE),
        ("Rentabilidad", "Margen Neto %", ren["margen_neto_pct"], FORMATO_PORCENTAJE),
        ("Rentabilidad", "ROE (Rentabilidad del Patrimonio) %", ren["roe_pct"], FORMATO_PORCENTAJE),
        ("Rentabilidad", "ROA (Rentabilidad del Activo) %", ren["roa_pct"], FORMATO_PORCENTAJE),
    ]
    for fila_idx, (categoria, indicador, valor, formato) in enumerate(filas, start=2):
        ws.cell(row=fila_idx, column=1, value=categoria)
        ws.cell(row=fila_idx, column=2, value=indicador)
        _escribir_celda(ws, fila_idx, 3, valor, formato)

    ws.column_dimensions["A"].width = 18
    ws.column_dimensions["B"].width = 36
    ws.column_dimensions["C"].width = 18
    return ws


def _aplanar_variacion(prefijo, variacion):
    """{'absoluta':.., 'porcentual':..} -> {'prefijo_abs':.., 'prefijo_pct':..}
    para poder meterlo como columnas planas en agregar_hoja_tabla."""
    return {f"{prefijo}_abs": variacion.get("absoluta"), f"{prefijo}_pct": variacion.get("porcentual")}


def agregar_hojas_comparacion_periodos(wb, periodos, ytd):
    """Dos hojas a partir de lo que devuelve calcular_comparacion_periodos:
    'Comparación Mensual' (MoM y YoY por mes) y 'Comparación YTD' (acumulado
    año a la fecha vs. mismo rango del año anterior)."""
    filas_mensual = []
    for p in periodos:
        fila = {
            "mes": p["mes"],
            "ingresos": p["ingresos"],
            "costos_gastos": p["costos_gastos"],
            "resultado": p["resultado"],
        }
        fila.update(_aplanar_variacion("mom", p["var_mom"]["resultado"]))
        fila.update(_aplanar_variacion("yoy", p["var_yoy"]["resultado"]))
        filas_mensual.append(fila)

    columnas_mensual = [
        ("Mes", "mes", None),
        ("Ingresos", "ingresos", FORMATO_MONEDA),
        ("Costos y Gastos", "costos_gastos", FORMATO_MONEDA),
        ("Resultado", "resultado", FORMATO_MONEDA),
        ("Var. Mes Anterior ($)", "mom_abs", FORMATO_MONEDA),
        ("Var. Mes Anterior (%)", "mom_pct", FORMATO_PORCENTAJE),
        ("Var. Mismo Mes Año Anterior ($)", "yoy_abs", FORMATO_MONEDA),
        ("Var. Mismo Mes Año Anterior (%)", "yoy_pct", FORMATO_PORCENTAJE),
    ]
    agregar_hoja_tabla(wb, "Comparación Mensual", columnas_mensual, filas_mensual)

    filas_ytd = []
    for y in ytd:
        fila = {
            "anio": y["anio"],
            "hasta_mes": y["hasta_mes"],
            "ingresos_ytd": y["ingresos_ytd"],
            "costos_gastos_ytd": y["costos_gastos_ytd"],
            "resultado_ytd": y["resultado_ytd"],
        }
        fila.update(_aplanar_variacion("yoy_ytd", y["var_yoy_ytd"]["resultado"]))
        filas_ytd.append(fila)

    columnas_ytd = [
        ("Año", "anio", None),
        ("Hasta Mes", "hasta_mes", None),
        ("Ingresos YTD", "ingresos_ytd", FORMATO_MONEDA),
        ("Costos y Gastos YTD", "costos_gastos_ytd", FORMATO_MONEDA),
        ("Resultado YTD", "resultado_ytd", FORMATO_MONEDA),
        ("Var. YoY YTD ($)", "yoy_ytd_abs", FORMATO_MONEDA),
        ("Var. YoY YTD (%)", "yoy_ytd_pct", FORMATO_PORCENTAJE),
    ]
    agregar_hoja_tabla(wb, "Comparación YTD", columnas_ytd, filas_ytd)


def agregar_hoja_balance_ocho_columnas(wb, cuentas, totales):
    columnas = [
        ("Código", "codigo_cuenta", None),
        ("Cuenta", "nombre_cuenta", None),
        ("Tipo", "tipo_cuenta", None),
        ("Naturaleza", "naturaleza", None),
        ("Sumas Debe", "suma_debe", FORMATO_MONEDA),
        ("Sumas Haber", "suma_haber", FORMATO_MONEDA),
        ("Saldo Deudor", "saldo_deudor", FORMATO_MONEDA),
        ("Saldo Acreedor", "saldo_acreedor", FORMATO_MONEDA),
        ("Inventario Activo", "inventario_activo", FORMATO_MONEDA),
        ("Inventario Pasivo", "inventario_pasivo", FORMATO_MONEDA),
        ("Inventario Patrimonio", "inventario_patrimonio", FORMATO_MONEDA),
        ("Pérdida", "perdida", FORMATO_MONEDA),
        ("Ganancia", "ganancia", FORMATO_MONEDA),
    ]
    fila_totales = dict(totales)
    fila_totales["nombre_cuenta"] = "TOTALES"
    agregar_hoja_tabla(wb, "Balance 8 Columnas", columnas, cuentas, totales=fila_totales)


def libro_nuevo():
    """Workbook sin la hoja por defecto que crea openpyxl (se agregan las
    hojas reales con las funciones agregar_hoja_*)."""
    wb = Workbook()
    wb.remove(wb.active)
    return wb


def a_bytes(wb):
    buffer = io.BytesIO()
    wb.save(buffer)
    buffer.seek(0)
    return buffer


def nombre_archivo(prefijo):
    return f"{prefijo}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.xlsx"
