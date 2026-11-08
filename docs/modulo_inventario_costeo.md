# Módulo: Inventario y Costeo (Kardex CPP) — v4 / v7

## Objetivo
Dar soporte al **Costeo Directo por Flujo de Venta**: para los productos `COMPRADO_REVENTA` (ver `tbl_productos_servicios.modo_obtencion`), el costo real de venta se determina por un kardex perpetuo de **Costo Promedio Ponderado (CPP)**, en vez de usar un costo estándar o el gasto puntual de la compra. Desde v7, el mismo kardex también rige el costo real de los **insumos** consumidos por ítems `FABRICADO`/`SERVICIO`.

## Tabla `tbl_movimientos_inventario`
Cada fila representa un movimiento (`ENTRADA` o `SALIDA`) y guarda el **saldo resultante** (`saldo_cantidad`, `saldo_valor`, `costo_promedio_resultante`) *después* de aplicarse ese movimiento. Esto hace que el historial sea auditable fila por fila, sin necesidad de recalcular todo el histórico cada vez que se consulta el saldo vigente de un ítem.

La FK es polimórfica pero tipada: exactamente una de `id_item` (→ `tbl_productos_servicios`) o `id_insumo` (→ `cat_insumos_recursos`) debe estar poblada (`CHECK ck_mov_inv_una_entidad`). Hasta v6 solo se usaba la rama `id_item`; desde **v7** la rama `id_insumo` está activa de punta a punta: toda compra de insumo (homologada vía `map_insumos` y registrada en `tbl_compras_detalle.id_insumo`) genera una ENTRADA, y todo consumo de insumo por un BOM de `FABRICADO`/`SERVICIO` vendido genera una SALIDA.

## SP `sp_registrar_movimiento_inventario`
Punto único de entrada para registrar un movimiento, para `id_item` o `id_insumo` indistintamente:

- **`ENTRADA`** (desde una compra, de un ítem `COMPRADO_REVENTA` o de un insumo): requiere `@costo_unitario_entrada`. El nuevo saldo de valor es `saldo_valor_anterior + (cantidad * costo_unitario_entrada)`, y el nuevo CPP es `nuevo_saldo_valor / nuevo_saldo_cantidad`.
- **`SALIDA`** (desde una venta de un ítem `COMPRADO_REVENTA`, o desde el consumo de un insumo del BOM de un `FABRICADO`/`SERVICIO` vendido): se costea al CPP vigente (`saldo_valor_anterior / saldo_cantidad_anterior`). Valida que haya stock suficiente antes de permitir la salida; si no, lanza error ("stock insuficiente") y no modifica el kardex.

Quién lo llama:
- `sp_procesar_etl_fase3`: `ENTRADA` al cargar cada línea de compra de un ítem `COMPRADO_REVENTA` o de un insumo (v7); `SALIDA` al cargar cada línea de venta `COMPRADO_REVENTA`, y (v7) una `SALIDA` por cada componente de insumo del BOM de cada línea de venta `FABRICADO`/`SERVICIO`.
- `sp_procesar_venta_externa`: `SALIDA` al procesar una venta puntual de un ítem `COMPRADO_REVENTA`, y (v7) una `SALIDA` por cada componente de insumo del BOM si la venta es de un ítem `FABRICADO`/`SERVICIO`.

## Relación con la contabilización automática
- Una compra de un ítem `COMPRADO_REVENTA` se activa a **Inventario de Mercaderías (`1141`)**; una compra de un insumo (v7) se activa a **Inventario de Insumos y Materias Primas (`1143`)** — ambas en el asiento automático, en vez de cargarse directo a Costo/Gasto.
- Una venta de un ítem `COMPRADO_REVENTA` genera, además del asiento de ingreso, un leg de costo: Debe la cuenta de Costo/Gasto del ítem, Haber `1141 Inventario`, por el monto `CPP × cantidad` vendida.
- Una venta de un ítem `FABRICADO`/`SERVICIO` (v7) genera, para la porción de insumos de su BOM, un leg de costo real: Debe la cuenta de Costo/Gasto del ítem, Haber `2123` (FABRICADO) o `2124` (SERVICIO), por el monto `CPP × cantidad consumida` de cada insumo (sumado entre todos los componentes del BOM).

## Operación: comprar insumos antes de vender/producir (v7)
Como la MPD/Insumos de `FABRICADO`/`SERVICIO` ahora se consume desde el kardex real, **una venta de un ítem `FABRICADO`/`SERVICIO` fallará con "stock insuficiente" si los insumos de su BOM no fueron comprados (ENTRADA a kardex) en cantidad suficiente antes de la venta**. Esto es distinto del comportamiento hasta v6, donde el costo estándar de referencia no requería que existiera stock físico.

## Prerrequisito de despliegue
`sql/crear_modulo_inventario_costeo.sql` requiere que `sql/crear_modulo_productos_servicios.sql` ya esté ejecutado (depende de `tbl_productos_servicios` y `cat_insumos_recursos`). Ver el orden de despliegue en `README.md`.
