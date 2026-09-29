# Núcleo de Base de Datos para E-commerce (MySQL 8.0.19+)

## Descripción
Diseño e implementación del núcleo relacional de un sistema de comercio electrónico: esquema normalizado con integridad referencial, datos de prueba, 20 consultas analíticas avanzadas, 20 funciones (UDF), 20 triggers, 20 eventos programados, 20 procedimientos almacenados transaccionales y un modelo de seguridad basado en roles (RBAC) con aislamiento por sucursal.

## Integrantes
| Nombre | Rol |
|--------|-----|
| _Integrante 1_ | Diseño de esquema |
| _Integrante 2_ | Consultas y funciones |
| _Integrante 3_ | Triggers y eventos |
| _Integrante 4_ | Procedimientos y seguridad |

## Requisitos
* MySQL **8.0.19 o superior** (usa `VALUES ROW`, `JSON_TABLE`, funciones de ventana, roles y `FAILED_LOGIN_ATTEMPTS`).
* Un usuario con privilegios administrativos (p. ej. `root@localhost`) para ejecutar los scripts.
* Guardar y ejecutar los archivos en **UTF-8** (hay objetos con `ñ`: columna `contraseña`, función `fn_ValidarComplejidadContraseña`, procedimiento `AñadirReseñaProducto`).
* Para los eventos: `SET GLOBAL event_scheduler = ON;` (el script `06` lo hace).

## Orden de ejecución
> Importante: el script `04_Seguridad.sql` se ejecuta **al final**, porque otorga permisos sobre tablas, funciones y procedimientos creados por los demás scripts.

```bash
mysql -u root -p < 01_Esquema_y_Datos.sql
mysql -u root -p < 02_Consultas_Avanzadas.sql     # opcional (solo SELECT)
mysql -u root -p < 03_Funciones.sql
mysql -u root -p < 05_Triggers.sql
mysql -u root -p < 06_Eventos.sql
mysql -u root -p < 07_Procedimientos_Almacenados.sql
mysql -u root -p < 04_Seguridad.sql               # SIEMPRE al final
```

| Paso | Archivo | Contenido |
|------|---------|-----------|
| 1 | `01_Esquema_y_Datos.sql` | DDL de todas las tablas + datos de prueba |
| 2 | `02_Consultas_Avanzadas.sql` | 20 consultas analíticas |
| 3 | `03_Funciones.sql` | 20 UDFs |
| 4 | `05_Triggers.sql` | Tablas de auditoría + 20 triggers (usa funciones del paso 3) |
| 5 | `06_Eventos.sql` | Scheduler, tablas de reportes + 20 eventos |
| 6 | `07_Procedimientos_Almacenados.sql` | 20 procedimientos (usa funciones y tablas previas) |
| 7 | `04_Seguridad.sql` | Roles, usuarios, vistas seguras, políticas |

## Modelo de datos (resumen)
* **Núcleo:** `categorias` 1—N `productos` N—1 `proveedores`; `clientes` 1—N `ventas` 1—N `detalle_ventas` N—1 `productos` (relación N:M ventas–productos resuelta por `detalle_ventas`).
* **Simulaciones pedidas:** `carritos`/`carrito_items` (carrito abandonado), `vistas_producto` (vistas), `promociones`, `resenas`, `devoluciones`, `pagos`; campos simulados `ciudad`, `fecha_nacimiento`, `peso_kg`.
* **Sucursales:** `sucursales` y `ventas.id_sucursal` para aislar ventas por sucursal.

## Decisiones de diseño
* Todos los datos de prueba usan fechas relativas a `NOW()` para que las consultas y eventos devuelvan resultados en cualquier fecha.
* Los hashes de contraseña de prueba usan `SHA2`; en producción se recomienda `bcrypt/argon2` en la capa de aplicación.
* Los logins fallidos no pueden capturarse con triggers en MySQL; se implementa una tabla + procedimiento de registro, un origen real (`performance_schema`) y la configuración de `log_error_verbosity` / plugin `CONNECTION_CONTROL` (ver `04`).
* Las contraseñas de los usuarios de ejemplo en `04_Seguridad.sql` deben cambiarse antes de usar en producción.
