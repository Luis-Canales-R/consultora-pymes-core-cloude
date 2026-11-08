# Módulo: Plan de Cuentas, Partida Doble y Transacciones (Modelo BI / ERP Chile)

## Objetivo
Establecer el núcleo contable relacional que garantiza la partida doble ($Debe = Haber$), la jerarquización del Plan de Cuentas estándar en Chile (1. Activo, 2. Pasivo, 3. Patrimonio, 4. Ingresos, 5. Costos, 6. Gastos) y el desacople metodológico entre el **Devengado** (Reconocimiento del hecho económico) y la **Liquidación** (Flujo de Caja / Cobro / Pago).[cite: 8]

## Arquitectura de Tablas
1. **`cat_plan_cuentas`**: Árbol jerárquico recursivo de cuentas contables. Define el nivel, la naturaleza (Deudora/Acreedora) y si la cuenta es imputable a asientos.[cite: 8]
2. **`tbl_transacciones_cabecera`**: Registro de documentos comerciales tributarios (Facturas de venta/compra, boletas) que respaldas los hechos económicos.
3. **`tbl_asientos_cabecera` & `tbl_asientos_detalle`**: Motor de Partida Doble. Garantiza que todo movimiento registre sus débitos y créditos cuadrados a nivel atómico.

## Ciclo Contable Operativo
- **Devengado:** Registro de la factura de venta/compra reconociendo el Ingreso/Gasto contra la Cuenta por Cobrar/Pagar (1.1.02 / 2.1.01) e IVA (1.1.05 / 2.1.04).[cite: 8]
- **Liquidación (Pago):** Extinción de la cuenta por cobrar/pagar afectando el disponible bancario (1.1.01.002).[cite: 8]