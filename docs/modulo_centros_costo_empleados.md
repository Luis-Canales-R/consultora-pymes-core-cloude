# Módulo: Centros de Costo y Empleados / Usuarios

## Objetivo
Incorporar las dimensiones organizacionales y de control de gestión que permiten clasificar las transacciones, costos y gastos según unidades operativas o administrativas (Centros de Costo bajo taxonomía APQC), además de asegurar la trazabilidad de los colaboradores que operan el sistema (`tbl_empleados_usuarios`).

## Arquitectura de Tablas
1. **`tbl_centros_costo`**: Permite estructurar de forma jerárquica las áreas de negocio (Finanzas, Operaciones, Ventas, Administración), facilitando el cálculo de rentabilidad por línea.
2. **`tbl_empleados_usuarios`**: Catálogo de personas vinculadas al equipo o usuarios del sistema ERP, asociadas directamente a su centro de costo primario.