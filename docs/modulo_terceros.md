# Módulo de Terceros (Business Partner / Stakeholders)

## 1. Objetivo
Centralizar la identidad de todas las personas naturales y jurídicas que interactúan con la consultora o la PyME (clientes, proveedores y empleados), evitando la duplicidad de datos y permitiendo una gestión multi-rol bajo el estándar de arquitectura ERP (patrón Business Partner).

## 2. Estructura del Modelo 3FN

El módulo se compone de un núcleo de identidad, un catálogo de roles y tablas de extensión específicas:

- **`cat_paises`**: Catálogo de países (código ISO y nombre).
- **`cat_condiciones_pago`**: Condiciones comerciales y plazos en días.
- **`cat_tipos_persona`**: Clasificación fiscal (Jurídica o Natural).
- **`cat_roles`**: Roles operativos permitidos en el sistema (`CLIENTE`, `PROVEEDOR`, `EMPLEADO`).
- **`cat_tipos_cliente_negocio`**: Segmentación comercial para clientes (Corporativo, Retail, etc.).
- **`cat_tipos_proveedor`**: Clasificación operativa para proveedores (Servicios, Insumos, Logística).
- **`tbl_terceros`**: Tabla maestra que almacena los datos fiscales y de contacto únicos (RUT/DNI, Razón Social, Dirección).
- **`rel_terceros_roles`**: Tabla puente (N:M) que permite asignar múltiples roles a un mismo tercero.
- **`tbl_terceros_extension_cliente`**: Atributos específicos comerciales de venta (Límite de crédito, condiciones de pago).
- **`tbl_terceros_extension_proveedor`**: Atributos específicos de compra y tesorería (Datos bancarios, tipo de proveedor).