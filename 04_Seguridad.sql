-- =====================================================================
-- 04_Seguridad.sql  |  Roles, usuarios, vistas seguras y políticas (MySQL 8.0.19+)
-- EJECUTAR AL FINAL (después de 01, 03, 05, 06 y 07): otorga permisos sobre
-- objetos creados por esos scripts. Ejecutar con un usuario administrador.
-- Cambie las contraseñas de ejemplo antes de usar en producción.
-- =====================================================================
USE ecommerce_db;
SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- REQ 1. Limpieza idempotente de usuarios y roles del proyecto
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'admin_user'@'localhost', 'marketing_user'@'localhost', 'inventory_user'@'localhost',
                    'support_user'@'localhost', 'analista_user'@'localhost', 'auditor_user'@'localhost', 'visitante_user'@'localhost';
DROP ROLE IF EXISTS 'Administrador_Sistema', 'Gerente_Marketing', 'Analista_Datos', 'Empleado_Inventario',
                    'Atencion_Cliente', 'Auditor_Financiero', 'Visitante';

-- ---------------------------------------------------------------------
-- REQ 2. Creación de los 7 roles
-- ---------------------------------------------------------------------
CREATE ROLE 'Administrador_Sistema', 'Gerente_Marketing', 'Analista_Datos', 'Empleado_Inventario',
            'Atencion_Cliente', 'Auditor_Financiero', 'Visitante';

-- ---------------------------------------------------------------------
-- REQ 3. Vistas seguras (ocultan contraseña, costos y datos sensibles)
-- ---------------------------------------------------------------------
-- 3.1 v_info_clientes_basica: datos mínimos para atención al cliente (sin contraseña, sin gasto ni fecha de nacimiento)
CREATE OR REPLACE VIEW v_info_clientes_basica AS
SELECT id_cliente, nombre, apellido, email, direccion_envio, ciudad, estado_cuenta, fecha_registro
FROM clientes;

-- 3.2 v_productos_publicos: catálogo visible para visitantes (sin costo, proveedor ni stock exacto)
CREATE OR REPLACE VIEW v_productos_publicos AS
SELECT p.id_producto, p.nombre, p.descripcion, p.precio, p.sku, c.nombre AS categoria,
       (p.stock > 0) AS disponible
FROM productos p LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
WHERE p.activo = 1 AND p.eliminado = 0;

-- ---------------------------------------------------------------------
-- REQ 4. Aislamiento de ventas por sucursal (id_sucursal + mapeo usuario-sucursal)
--        NULL en id_sucursal = acceso a todas las sucursales.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuario_sucursal (
  usuario     VARCHAR(64) NOT NULL,
  id_sucursal INT NULL,
  UNIQUE KEY uq_usuario_sucursal (usuario, id_sucursal),
  CONSTRAINT fk_us_suc FOREIGN KEY (id_sucursal) REFERENCES sucursales(id_sucursal) ON DELETE CASCADE
) ENGINE=InnoDB;

DELETE FROM usuario_sucursal;
INSERT INTO usuario_sucursal (usuario, id_sucursal) VALUES
('root', NULL), ('admin_user', NULL), ('marketing_user', NULL), ('auditor_user', NULL), ('analista_user', NULL),
('support_user', 1);

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_ventas_sucursal AS
SELECT v.id_venta, v.fecha_venta, v.estado, v.total, v.id_cliente, v.id_sucursal, v.fecha_envio, v.fecha_entrega
FROM ventas v
WHERE EXISTS (
  SELECT 1 FROM usuario_sucursal us
  WHERE us.usuario = SUBSTRING_INDEX(USER(), '@', 1) AND (us.id_sucursal IS NULL OR us.id_sucursal = v.id_sucursal)
);

-- ---------------------------------------------------------------------
-- REQ 5. Administrador_Sistema: control total del esquema + administración de cuentas
-- ---------------------------------------------------------------------
GRANT ALL PRIVILEGES ON ecommerce_db.* TO 'Administrador_Sistema';
GRANT CREATE USER, CREATE ROLE, DROP ROLE, RELOAD, PROCESS ON *.* TO 'Administrador_Sistema';

-- ---------------------------------------------------------------------
-- REQ 6. Gerente_Marketing: lectura de ventas y clientes (sin contraseña ni datos de acceso)
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.ventas TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.detalle_ventas TO 'Gerente_Marketing';
GRANT SELECT (id_cliente, nombre, apellido, email, ciudad, fecha_nacimiento, fecha_registro, total_gastado,
              fecha_ultima_compra, nivel_lealtad, estado_cuenta) ON ecommerce_db.clientes TO 'Gerente_Marketing';

-- ---------------------------------------------------------------------
-- REQ 7. Analista_Datos: solo lectura (sin log_*), sin DELETE/TRUNCATE/DROP, sin PII (columnas restringidas)
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.productos TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.categorias TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.proveedores TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.ventas TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.detalle_ventas TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carritos TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carrito_items TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.vistas_producto TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.promociones TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.resenas TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.devoluciones TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.pagos TO 'Analista_Datos';
GRANT SELECT (id_cliente, ciudad, fecha_registro, total_gastado, fecha_ultima_compra, nivel_lealtad, estado_cuenta)
  ON ecommerce_db.clientes TO 'Analista_Datos';
GRANT CREATE TEMPORARY TABLES ON ecommerce_db.* TO 'Analista_Datos';
GRANT EXECUTE ON PROCEDURE ecommerce_db.GenerarReporteMensual TO 'Analista_Datos';
-- (No se concede ObtenerDashboardAdmin: su último resultado lee log_alertas_stock y el analista no debe ver auditoría)

-- ---------------------------------------------------------------------
-- REQ 8. Empleado_Inventario: modifica productos EXCEPTO el precio (privilegio UPDATE por columna)
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.productos TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.categorias TO 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.proveedores TO 'Empleado_Inventario';
GRANT UPDATE (nombre, descripcion, costo, stock, stock_minimo, peso_kg, activo, id_categoria, id_proveedor)
  ON ecommerce_db.productos TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce_db.AjustarNivelStock TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce_db.AsignarProductoProveedor TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce_db.MoverProductosEntreCategorias TO 'Empleado_Inventario';
GRANT EXECUTE ON PROCEDURE ecommerce_db.BuscarProductos TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- REQ 9. Atencion_Cliente: consulta clientes/ventas únicamente mediante vistas
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_ventas_sucursal TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.ObtenerHistorialCompras TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.ActualizarDireccionCliente TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.CambiarEstadoPedido TO 'Atencion_Cliente';

-- ---------------------------------------------------------------------
-- REQ 10. Auditor_Financiero: lectura de ventas, productos, pagos y todos los logs
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.ventas TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.detalle_ventas TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.productos TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.pagos TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.devoluciones TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_auditoria_precio TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_clientes TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_estado_pedido TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_alertas_stock TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_ajustes_stock TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_permisos TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_consistencia TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_tamano_bd TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.alertas_fraude TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.ventas_archivo TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.detalle_ventas_archivo TO 'Auditor_Financiero';

-- ---------------------------------------------------------------------
-- REQ 11. Visitante: solo lectura del catálogo público
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.v_productos_publicos TO 'Visitante';
GRANT SELECT ON ecommerce_db.categorias TO 'Visitante';

-- ---------------------------------------------------------------------
-- REQ 12. Política de contraseñas y bloqueo por intentos fallidos (por usuario):
--         caducidad 90 días, historial de 5, sin reutilizar por 365 días,
--         bloqueo de 1 día tras 5 intentos fallidos consecutivos.
-- REQ 13. Creación de usuarios (host localhost). Cambie las contraseñas.
-- ---------------------------------------------------------------------
CREATE USER 'admin_user'@'localhost' IDENTIFIED BY 'Adm1n#Segura2026!'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1
  COMMENT 'Administrador del sistema';
-- Opcional en servidores con TLS configurado: ALTER USER 'admin_user'@'localhost' REQUIRE SSL;

CREATE USER 'marketing_user'@'localhost' IDENTIFIED BY 'Mkt#Segura2026!'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Gerente de marketing';

CREATE USER 'inventory_user'@'localhost' IDENTIFIED BY 'Inv#Segura2026!'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Empleado de inventario';

CREATE USER 'support_user'@'localhost' IDENTIFIED BY 'Sup#Segura2026!'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Atencion al cliente (sucursal 1)';

-- REQ 14. Usuarios adicionales para los roles restantes. analista_user con límites de consultas por hora.
CREATE USER 'analista_user'@'localhost' IDENTIFIED BY 'Ana#Segura2026!'
  WITH MAX_QUERIES_PER_HOUR 500 MAX_UPDATES_PER_HOUR 20 MAX_CONNECTIONS_PER_HOUR 100 MAX_USER_CONNECTIONS 3
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Analista de datos (limitado)';

CREATE USER 'auditor_user'@'localhost' IDENTIFIED BY 'Aud#Segura2026!'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Auditor financiero';

CREATE USER 'visitante_user'@'localhost' IDENTIFIED BY 'Vis#Segura2026!'
  WITH MAX_QUERIES_PER_HOUR 200 MAX_USER_CONNECTIONS 5
  PASSWORD EXPIRE INTERVAL 180 DAY FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 COMMENT 'Visitante del catalogo';

-- ---------------------------------------------------------------------
-- REQ 15. Asignación de roles y activación por defecto al iniciar sesión
-- ---------------------------------------------------------------------
GRANT 'Administrador_Sistema' TO 'admin_user'@'localhost';
GRANT 'Gerente_Marketing'     TO 'marketing_user'@'localhost';
GRANT 'Empleado_Inventario'   TO 'inventory_user'@'localhost';
GRANT 'Atencion_Cliente'      TO 'support_user'@'localhost';
GRANT 'Analista_Datos'        TO 'analista_user'@'localhost';
GRANT 'Auditor_Financiero'    TO 'auditor_user'@'localhost';
GRANT 'Visitante'             TO 'visitante_user'@'localhost';

-- Se limpian primero los roles por defecto que pudieran haber quedado de ejecuciones anteriores
-- y luego se activan, para cada usuario, exactamente los roles que se le concedieron arriba.
SET DEFAULT ROLE NONE TO 'admin_user'@'localhost', 'marketing_user'@'localhost', 'inventory_user'@'localhost',
                         'support_user'@'localhost', 'analista_user'@'localhost', 'auditor_user'@'localhost',
                         'visitante_user'@'localhost';
SET DEFAULT ROLE ALL TO 'admin_user'@'localhost', 'marketing_user'@'localhost', 'inventory_user'@'localhost',
                        'support_user'@'localhost', 'analista_user'@'localhost', 'auditor_user'@'localhost',
                        'visitante_user'@'localhost';
-- Alternativa a nivel de servidor: SET PERSIST activate_all_roles_on_login = ON;

-- ---------------------------------------------------------------------
-- REQ 16. Política global de contraseñas (ejecutar MANUALMENTE una sola vez si el componente no está instalado)
--         INSTALL COMPONENT 'file://component_validate_password';
--         SET PERSIST validate_password.policy = 'STRONG';
--         SET PERSIST validate_password.length = 12;
--         SET PERSIST validate_password.mixed_case_count = 1;
--         SET PERSIST validate_password.number_count = 1;
--         SET PERSIST validate_password.special_char_count = 1;
--         SET PERSIST default_password_lifetime = 90;
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- REQ 17. Auditoría de logins fallidos
--   (a) Tabla + procedimiento para que la capa de aplicación/proxy registre cada intento fallido.
--   (b) Vista sobre performance_schema con el contador real de errores "Access denied" del servidor.
--   (c) Recomendado: SET PERSIST log_error_verbosity = 3;  (registra "Access denied" en el error log)
--   (d) Recomendado (frena fuerza bruta): INSTALL PLUGIN CONNECTION_CONTROL SONAME 'connection_control.so';
--       SET PERSIST connection_control_failed_connections_threshold = 5;
--       SET PERSIST connection_control_min_connection_delay = 2000;
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS log_logins_fallidos (
  id_log  BIGINT AUTO_INCREMENT PRIMARY KEY,
  usuario VARCHAR(64) NOT NULL,
  host    VARCHAR(255),
  motivo  VARCHAR(255),
  fecha   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_llf_usuario_fecha (usuario, fecha)
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS sp_registrar_login_fallido;
DELIMITER $$
-- Registra un intento de login fallido y devuelve cuántos lleva ese usuario en la última hora
CREATE PROCEDURE sp_registrar_login_fallido(IN p_usuario VARCHAR(64), IN p_host VARCHAR(255), IN p_motivo VARCHAR(255))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  INSERT INTO log_logins_fallidos (usuario, host, motivo) VALUES (p_usuario, p_host, COALESCE(p_motivo, 'Credenciales inválidas'));
  COMMIT;
  SELECT COUNT(*) AS intentos_ultima_hora FROM log_logins_fallidos
  WHERE usuario = p_usuario AND fecha >= NOW() - INTERVAL 1 HOUR;
END$$
DELIMITER ;

CREATE OR REPLACE VIEW v_logins_fallidos_servidor AS
SELECT error_name, sum_error_raised AS veces, first_seen, last_seen
FROM performance_schema.events_errors_summary_global_by_error
WHERE error_name = 'ER_ACCESS_DENIED_ERROR';

GRANT SELECT ON ecommerce_db.log_logins_fallidos TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.v_logins_fallidos_servidor TO 'Auditor_Financiero';
GRANT SELECT, INSERT ON ecommerce_db.log_logins_fallidos TO 'Administrador_Sistema';

-- ---------------------------------------------------------------------
-- REQ 18. Bloquear acceso remoto de root (solo root@localhost) y eliminar cuentas anónimas
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'root'@'%';
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
-- Verificación: solo debe aparecer root@localhost (y root@127.0.0.1/::1 si aplica)
SELECT user, host FROM mysql.user WHERE user = 'root';
-- Refuerzo a nivel de servidor (my.cnf): bind-address = 127.0.0.1  (o skip-networking si solo se usa socket)

-- ---------------------------------------------------------------------
-- REQ 19. Permisos por procedimiento para el resto de roles operativos
-- ---------------------------------------------------------------------
GRANT EXECUTE ON PROCEDURE ecommerce_db.RealizarNuevaVenta TO 'Administrador_Sistema';
GRANT EXECUTE ON PROCEDURE ecommerce_db.ObtenerDetallesProductoCompleto TO 'Atencion_Cliente';
GRANT EXECUTE ON PROCEDURE ecommerce_db.ObtenerDetallesProductoCompleto TO 'Visitante';
GRANT EXECUTE ON PROCEDURE ecommerce_db.BuscarProductos TO 'Visitante';
GRANT EXECUTE ON PROCEDURE ecommerce_db.ObtenerProductosRelacionados TO 'Visitante';

-- ---------------------------------------------------------------------
-- REQ 20. Aplicar cambios y verificar la configuración final
-- ---------------------------------------------------------------------
FLUSH PRIVILEGES;
SHOW GRANTS FOR 'analista_user'@'localhost' USING 'Analista_Datos';
SHOW GRANTS FOR 'inventory_user'@'localhost' USING 'Empleado_Inventario';
SHOW GRANTS FOR 'support_user'@'localhost' USING 'Atencion_Cliente';
SELECT user, host, password_expired, password_lifetime, account_locked, max_questions
FROM mysql.user
WHERE user IN ('admin_user','marketing_user','inventory_user','support_user','analista_user','auditor_user','visitante_user');
