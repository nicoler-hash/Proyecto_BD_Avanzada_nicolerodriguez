-- =====================================================================
-- 06_Eventos.sql  |  Scheduler, tablas de reportes y 20 eventos (MySQL 8.0+)
-- Requiere 01, 03 y 05.
-- =====================================================================
USE ecommerce_db;
SET NAMES utf8mb4;

-- Activa el planificador de eventos (requiere privilegio SYSTEM_VARIABLES_ADMIN o SUPER)
SET GLOBAL event_scheduler = ON;

-- --------------------- Tablas de soporte de eventos -------------------
CREATE TABLE IF NOT EXISTS reporte_ventas_semanal (
  id INT AUTO_INCREMENT PRIMARY KEY, semana_inicio DATE NOT NULL, semana_fin DATE NOT NULL,
  num_ventas INT NOT NULL, total_ventas DECIMAL(14,2) NOT NULL, ticket_promedio DECIMAL(12,2) NOT NULL,
  generado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE KEY uq_semana (semana_inicio)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS temp_importaciones (
  id INT AUTO_INCREMENT PRIMARY KEY, datos JSON NULL, fecha_creacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_estado_pedido_archivo LIKE log_estado_pedido;

CREATE TABLE IF NOT EXISTS lista_reabastecimiento (
  id INT AUTO_INCREMENT PRIMARY KEY, id_producto INT NOT NULL, id_proveedor INT NOT NULL,
  stock_actual INT NOT NULL, cantidad_sugerida INT NOT NULL,
  estado ENUM('Pendiente','Ordenado') NOT NULL DEFAULT 'Pendiente', generado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ventas_diarias (
  fecha DATE PRIMARY KEY, num_ventas INT NOT NULL, unidades INT NOT NULL, total DECIMAL(14,2) NOT NULL,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_consistencia (
  id INT AUTO_INCREMENT PRIMARY KEY, tipo VARCHAR(50) NOT NULL, referencia INT NOT NULL, detalle VARCHAR(255),
  fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS felicitaciones_cumpleanos (
  id INT AUTO_INCREMENT PRIMARY KEY, id_cliente INT NOT NULL, anio SMALLINT NOT NULL, mensaje VARCHAR(255) NOT NULL,
  enviado TINYINT(1) NOT NULL DEFAULT 0, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_cli_anio (id_cliente, anio)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ranking_productos (
  id_producto INT PRIMARY KEY, ranking INT NOT NULL, unidades_90d INT NOT NULL, ingresos_90d DECIMAL(14,2) NOT NULL,
  fecha_calculo DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS kpis_mensuales (
  mes CHAR(7) PRIMARY KEY, num_ventas INT NOT NULL, ingresos DECIMAL(14,2) NOT NULL, ticket_promedio DECIMAL(12,2) NOT NULL,
  clientes_nuevos INT NOT NULL, clientes_activos INT NOT NULL, margen_bruto DECIMAL(14,2) NOT NULL,
  calculado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mv_ventas_por_producto (
  id_producto INT PRIMARY KEY, nombre VARCHAR(150) NOT NULL, unidades INT NOT NULL, ingresos DECIMAL(14,2) NOT NULL,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_tamano_bd (
  id INT AUTO_INCREMENT PRIMARY KEY, esquema VARCHAR(64) NOT NULL, tamano_mb DECIMAL(12,2) NOT NULL,
  fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS alertas_fraude (
  id INT AUTO_INCREMENT PRIMARY KEY, id_cliente INT NOT NULL, motivo VARCHAR(100) NOT NULL, detalle VARCHAR(255),
  revisada TINYINT(1) NOT NULL DEFAULT 0, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS reporte_proveedores (
  id INT AUTO_INCREMENT PRIMARY KEY, mes CHAR(7) NOT NULL, id_proveedor INT NOT NULL, unidades INT NOT NULL,
  ingresos DECIMAL(14,2) NOT NULL, margen DECIMAL(14,2) NOT NULL, productos_bajo_stock INT NOT NULL,
  generado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, UNIQUE KEY uq_mes_prov (mes, id_proveedor)
) ENGINE=InnoDB;

DELIMITER $$

-- 1. weekly_sales_report: cada lunes consolida las ventas de la semana anterior
DROP EVENT IF EXISTS weekly_sales_report$$
CREATE EVENT weekly_sales_report
ON SCHEDULE EVERY 1 WEEK STARTS TIMESTAMP(DATE_ADD(CURRENT_DATE, INTERVAL (7 - WEEKDAY(CURRENT_DATE)) DAY), '06:00:00')
COMMENT 'Reporte semanal de ventas'
DO
BEGIN
  INSERT INTO reporte_ventas_semanal (semana_inicio, semana_fin, num_ventas, total_ventas, ticket_promedio)
  SELECT DATE_SUB(CURDATE(), INTERVAL 7 DAY), DATE_SUB(CURDATE(), INTERVAL 1 DAY),
         COUNT(*), COALESCE(SUM(total), 0), COALESCE(AVG(total), 0)
  FROM ventas
  WHERE estado <> 'Cancelado' AND fecha_venta >= DATE_SUB(CURDATE(), INTERVAL 7 DAY) AND fecha_venta < CURDATE()
  ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), total_ventas = VALUES(total_ventas), ticket_promedio = VALUES(ticket_promedio);
END$$

-- 2. cleanup_temp_tables: elimina registros temporales de importación con más de 1 día
DROP EVENT IF EXISTS cleanup_temp_tables$$
CREATE EVENT cleanup_temp_tables
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '01:00:00') + INTERVAL 1 DAY
COMMENT 'Limpieza de tablas temporales'
DO
BEGIN
  DELETE FROM temp_importaciones WHERE fecha_creacion < NOW() - INTERVAL 1 DAY;
END$$

-- 3. archive_old_logs: mueve logs de estado de pedido con más de 180 días a la tabla de archivo
DROP EVENT IF EXISTS archive_old_logs$$
CREATE EVENT archive_old_logs
ON SCHEDULE EVERY 1 MONTH STARTS TIMESTAMP(CURRENT_DATE, '02:00:00') + INTERVAL 1 DAY
COMMENT 'Archivado de logs antiguos'
DO
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; END;
  START TRANSACTION;
  INSERT INTO log_estado_pedido_archivo SELECT * FROM log_estado_pedido WHERE fecha < NOW() - INTERVAL 180 DAY;
  DELETE FROM log_estado_pedido WHERE fecha < NOW() - INTERVAL 180 DAY;
  COMMIT;
END$$

-- 4. deactivate_expired_promotions: desactiva promociones cuya fecha de fin ya pasó
DROP EVENT IF EXISTS deactivate_expired_promotions$$
CREATE EVENT deactivate_expired_promotions
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '00:05:00') + INTERVAL 1 DAY
COMMENT 'Desactivar promociones vencidas'
DO
BEGIN
  UPDATE promociones SET activa = 0 WHERE activa = 1 AND fecha_fin < CURDATE();
END$$

-- 5. recalculate_loyalty: recalcula el nivel de lealtad de todos los clientes activos
DROP EVENT IF EXISTS recalculate_loyalty$$
CREATE EVENT recalculate_loyalty
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '03:00:00') + INTERVAL 1 DAY
COMMENT 'Recalculo de niveles de lealtad'
DO
BEGIN
  UPDATE clientes SET nivel_lealtad = fn_DeterminarEstadoLealtad(id_cliente) WHERE estado_cuenta = 'Activa';
END$$

-- 6. generate_reorder_list: reconstruye la lista de productos a reabastecer
DROP EVENT IF EXISTS generate_reorder_list$$
CREATE EVENT generate_reorder_list
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '06:30:00') + INTERVAL 1 DAY
COMMENT 'Lista de reabastecimiento'
DO
BEGIN
  DELETE FROM lista_reabastecimiento WHERE estado = 'Pendiente';
  INSERT INTO lista_reabastecimiento (id_producto, id_proveedor, stock_actual, cantidad_sugerida)
  SELECT id_producto, id_proveedor, stock, (stock_minimo * 3 - stock)
  FROM productos WHERE stock <= stock_minimo AND activo = 1 AND eliminado = 0;
END$$

-- 7. rebuild_indexes: reorganiza tablas e índices y actualiza estadísticas cada domingo
DROP EVENT IF EXISTS rebuild_indexes$$
CREATE EVENT rebuild_indexes
ON SCHEDULE EVERY 1 WEEK STARTS TIMESTAMP(DATE_ADD(CURRENT_DATE, INTERVAL (6 - WEEKDAY(CURRENT_DATE) + IF(WEEKDAY(CURRENT_DATE) = 6, 7, 0)) DAY), '03:30:00')
COMMENT 'Reconstruccion de indices'
DO
BEGIN
  OPTIMIZE TABLE productos, ventas, detalle_ventas, clientes;
  ANALYZE TABLE productos, ventas, detalle_ventas, clientes;
END$$

-- 8. suspend_inactive_accounts: suspende cuentas sin compras ni actividad en los últimos 24 meses
DROP EVENT IF EXISTS suspend_inactive_accounts$$
CREATE EVENT suspend_inactive_accounts
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '04:00:00') + INTERVAL 1 DAY
COMMENT 'Suspension de cuentas inactivas'
DO
BEGIN
  UPDATE clientes SET estado_cuenta = 'Suspendida'
  WHERE estado_cuenta = 'Activa' AND COALESCE(fecha_ultima_compra, fecha_registro) < NOW() - INTERVAL 24 MONTH;
END$$

-- 9. aggregate_daily_sales: agrega las ventas del día anterior en ventas_diarias
DROP EVENT IF EXISTS aggregate_daily_sales$$
CREATE EVENT aggregate_daily_sales
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '00:30:00') + INTERVAL 1 DAY
COMMENT 'Agregacion diaria de ventas'
DO
BEGIN
  INSERT INTO ventas_diarias (fecha, num_ventas, unidades, total)
  SELECT DATE_SUB(CURDATE(), INTERVAL 1 DAY), COUNT(DISTINCT v.id_venta), COALESCE(SUM(d.cantidad), 0), COALESCE(SUM(DISTINCT v.total), 0)
  FROM ventas v LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
  WHERE v.estado <> 'Cancelado' AND DATE(v.fecha_venta) = DATE_SUB(CURDATE(), INTERVAL 1 DAY)
  ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), unidades = VALUES(unidades), total = VALUES(total), actualizado_en = NOW();
END$$

-- 10. check_data_consistency: detecta ventas con total distinto a su detalle y productos con stock negativo
DROP EVENT IF EXISTS check_data_consistency$$
CREATE EVENT check_data_consistency
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '05:00:00') + INTERVAL 1 DAY
COMMENT 'Verificacion de consistencia'
DO
BEGIN
  INSERT INTO log_consistencia (tipo, referencia, detalle)
  SELECT 'TOTAL_VENTA_INCONSISTENTE', v.id_venta, CONCAT('total=', v.total, ' detalle=', COALESCE(x.suma, 0))
  FROM ventas v
  LEFT JOIN (SELECT id_venta, SUM(cantidad * precio_unitario_congelado) AS suma FROM detalle_ventas GROUP BY id_venta) x ON x.id_venta = v.id_venta
  WHERE ABS(v.total - COALESCE(x.suma, 0)) > 0.01;
  INSERT INTO log_consistencia (tipo, referencia, detalle)
  SELECT 'STOCK_NEGATIVO', id_producto, CONCAT('stock=', stock) FROM productos WHERE stock < 0;
END$$

-- 11. send_birthday_greetings: encola saludos de cumpleaños del día (simula el envío de correo)
DROP EVENT IF EXISTS send_birthday_greetings$$
CREATE EVENT send_birthday_greetings
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '08:00:00') + INTERVAL 1 DAY
COMMENT 'Saludos de cumpleanos'
DO
BEGIN
  INSERT IGNORE INTO felicitaciones_cumpleanos (id_cliente, anio, mensaje)
  SELECT id_cliente, YEAR(CURDATE()), CONCAT('¡Feliz cumpleaños, ', nombre, '! Tienes un cupón de regalo.')
  FROM clientes
  WHERE estado_cuenta = 'Activa' AND fecha_nacimiento IS NOT NULL
    AND MONTH(fecha_nacimiento) = MONTH(CURDATE()) AND DAY(fecha_nacimiento) = DAY(CURDATE());
END$$

-- 12. update_product_rankings: ranking de productos por unidades vendidas en los últimos 90 días
DROP EVENT IF EXISTS update_product_rankings$$
CREATE EVENT update_product_rankings
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '03:15:00') + INTERVAL 1 DAY
COMMENT 'Ranking de productos'
DO
BEGIN
  DELETE FROM ranking_productos;
  INSERT INTO ranking_productos (id_producto, ranking, unidades_90d, ingresos_90d)
  SELECT id_producto, RANK() OVER (ORDER BY unidades DESC, ingresos DESC), unidades, ingresos
  FROM (
    SELECT p.id_producto,
           COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad END), 0) AS unidades,
           COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * d.precio_unitario_congelado END), 0) AS ingresos
    FROM productos p
    LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
    LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado' AND v.fecha_venta >= NOW() - INTERVAL 90 DAY
    GROUP BY p.id_producto
  ) t;
END$$

-- 13. backup_critical_tables: copia de seguridad simulada de tablas críticas (sin hashes de contraseña)
DROP EVENT IF EXISTS backup_critical_tables$$
CREATE EVENT backup_critical_tables
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '23:00:00') + INTERVAL 1 DAY
COMMENT 'Backup simulado a tablas bkp_'
DO
BEGIN
  DROP TABLE IF EXISTS bkp_productos;
  CREATE TABLE bkp_productos AS SELECT * FROM productos;
  DROP TABLE IF EXISTS bkp_ventas;
  CREATE TABLE bkp_ventas AS SELECT * FROM ventas;
  DROP TABLE IF EXISTS bkp_detalle_ventas;
  CREATE TABLE bkp_detalle_ventas AS SELECT * FROM detalle_ventas;
  DROP TABLE IF EXISTS bkp_clientes;
  CREATE TABLE bkp_clientes AS
    SELECT id_cliente, nombre, apellido, email, direccion_envio, ciudad, fecha_nacimiento, fecha_registro,
           total_gastado, fecha_ultima_compra, nivel_lealtad, estado_cuenta, id_referido
    FROM clientes;
END$$

-- 14. clear_abandoned_carts: marca como abandonados los carritos sin actividad en 7 días y borra los abandonados de más de 30
DROP EVENT IF EXISTS clear_abandoned_carts$$
CREATE EVENT clear_abandoned_carts
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '04:30:00') + INTERVAL 1 DAY
COMMENT 'Limpieza de carritos'
DO
BEGIN
  UPDATE carritos SET estado = 'Abandonado' WHERE estado = 'Activo' AND fecha_actualizacion < NOW() - INTERVAL 7 DAY;
  DELETE FROM carritos WHERE estado = 'Abandonado' AND fecha_actualizacion < NOW() - INTERVAL 30 DAY;
END$$

-- 15. calculate_monthly_kpis: KPIs del mes anterior (ventas, ingresos, ticket, clientes, margen)
DROP EVENT IF EXISTS calculate_monthly_kpis$$
CREATE EVENT calculate_monthly_kpis
ON SCHEDULE EVERY 1 MONTH STARTS TIMESTAMP(DATE_ADD(DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY), INTERVAL 1 MONTH), '01:30:00')
COMMENT 'KPIs mensuales'
DO
BEGIN
  DECLARE v_ini DATE;
  DECLARE v_fin DATE;
  SET v_fin = DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY);
  SET v_ini = DATE_SUB(v_fin, INTERVAL 1 MONTH);
  INSERT INTO kpis_mensuales (mes, num_ventas, ingresos, ticket_promedio, clientes_nuevos, clientes_activos, margen_bruto)
  SELECT DATE_FORMAT(v_ini, '%Y-%m'),
    (SELECT COUNT(*) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
    (SELECT COALESCE(SUM(total), 0) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
    (SELECT COALESCE(AVG(total), 0) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
    (SELECT COUNT(*) FROM clientes WHERE fecha_registro >= v_ini AND fecha_registro < v_fin),
    (SELECT COUNT(DISTINCT id_cliente) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
    (SELECT COALESCE(SUM(d.cantidad * (d.precio_unitario_congelado - p.costo)), 0)
       FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta JOIN productos p ON p.id_producto = d.id_producto
      WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < v_fin)
  ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), ingresos = VALUES(ingresos), ticket_promedio = VALUES(ticket_promedio),
    clientes_nuevos = VALUES(clientes_nuevos), clientes_activos = VALUES(clientes_activos), margen_bruto = VALUES(margen_bruto), calculado_en = NOW();
END$$

-- 16. refresh_materialized_views: refresca la "vista materializada" de ventas por producto
DROP EVENT IF EXISTS refresh_materialized_views$$
CREATE EVENT refresh_materialized_views
ON SCHEDULE EVERY 1 HOUR STARTS NOW() + INTERVAL 1 HOUR
COMMENT 'Refresco de vista materializada'
DO
BEGIN
  DELETE FROM mv_ventas_por_producto;
  INSERT INTO mv_ventas_por_producto (id_producto, nombre, unidades, ingresos)
  SELECT p.id_producto, p.nombre,
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad END), 0),
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * d.precio_unitario_congelado END), 0)
  FROM productos p
  LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
  LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  GROUP BY p.id_producto, p.nombre;
END$$

-- 17. log_database_size: registra el tamaño de datos + índices del esquema
DROP EVENT IF EXISTS log_database_size$$
CREATE EVENT log_database_size
ON SCHEDULE EVERY 1 DAY STARTS TIMESTAMP(CURRENT_DATE, '23:30:00') + INTERVAL 1 DAY
COMMENT 'Tamano de la base de datos'
DO
BEGIN
  INSERT INTO log_tamano_bd (esquema, tamano_mb)
  SELECT table_schema, ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)
  FROM information_schema.tables WHERE table_schema = 'ecommerce_db' GROUP BY table_schema;
END$$

-- 18. detect_fraudulent_activity: alerta por 3+ compras en 1 hora o 3+ cancelaciones en 24 horas
DROP EVENT IF EXISTS detect_fraudulent_activity$$
CREATE EVENT detect_fraudulent_activity
ON SCHEDULE EVERY 15 MINUTE STARTS NOW() + INTERVAL 15 MINUTE
COMMENT 'Deteccion de fraude'
DO
BEGIN
  INSERT INTO alertas_fraude (id_cliente, motivo, detalle)
  SELECT v.id_cliente, 'COMPRAS_RAPIDAS', CONCAT(COUNT(*), ' compras en la ultima hora')
  FROM ventas v WHERE v.fecha_venta >= NOW() - INTERVAL 1 HOUR
  GROUP BY v.id_cliente HAVING COUNT(*) >= 3
     AND NOT EXISTS (SELECT 1 FROM alertas_fraude a WHERE a.id_cliente = v.id_cliente AND a.motivo = 'COMPRAS_RAPIDAS' AND a.fecha >= NOW() - INTERVAL 1 DAY);
  INSERT INTO alertas_fraude (id_cliente, motivo, detalle)
  SELECT v.id_cliente, 'CANCELACIONES_REPETIDAS', CONCAT(COUNT(*), ' cancelaciones en 24 horas')
  FROM ventas v WHERE v.estado = 'Cancelado' AND v.fecha_venta >= NOW() - INTERVAL 24 HOUR
  GROUP BY v.id_cliente HAVING COUNT(*) >= 3
     AND NOT EXISTS (SELECT 1 FROM alertas_fraude a WHERE a.id_cliente = v.id_cliente AND a.motivo = 'CANCELACIONES_REPETIDAS' AND a.fecha >= NOW() - INTERVAL 1 DAY);
END$$

-- 19. supplier_performance_report: desempeño mensual por proveedor (mes anterior)
DROP EVENT IF EXISTS supplier_performance_report$$
CREATE EVENT supplier_performance_report
ON SCHEDULE EVERY 1 MONTH STARTS TIMESTAMP(DATE_ADD(DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY), INTERVAL 1 MONTH), '02:30:00')
COMMENT 'Reporte de desempeno de proveedores'
DO
BEGIN
  DECLARE v_fin DATE;
  DECLARE v_ini DATE;
  SET v_fin = DATE_SUB(CURRENT_DATE, INTERVAL DAYOFMONTH(CURRENT_DATE) - 1 DAY);
  SET v_ini = DATE_SUB(v_fin, INTERVAL 1 MONTH);
  INSERT INTO reporte_proveedores (mes, id_proveedor, unidades, ingresos, margen, productos_bajo_stock)
  SELECT DATE_FORMAT(v_ini, '%Y-%m'), pr.id_proveedor,
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad END), 0),
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * d.precio_unitario_congelado END), 0),
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * (d.precio_unitario_congelado - p.costo) END), 0),
         COUNT(DISTINCT CASE WHEN p.stock <= p.stock_minimo THEN p.id_producto END)
  FROM proveedores pr
  LEFT JOIN productos p ON p.id_proveedor = pr.id_proveedor
  LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
  LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < v_fin
  GROUP BY pr.id_proveedor
  ON DUPLICATE KEY UPDATE unidades = VALUES(unidades), ingresos = VALUES(ingresos), margen = VALUES(margen),
    productos_bajo_stock = VALUES(productos_bajo_stock), generado_en = NOW();
END$$

-- 20. purge_soft_deleted_records: elimina definitivamente productos borrados lógicamente hace 90+ días y sin ventas
DROP EVENT IF EXISTS purge_soft_deleted_records$$
CREATE EVENT purge_soft_deleted_records
ON SCHEDULE EVERY 1 WEEK STARTS TIMESTAMP(CURRENT_DATE, '05:30:00') + INTERVAL 1 DAY
COMMENT 'Purga de registros con borrado logico'
DO
BEGIN
  DELETE FROM productos
  WHERE eliminado = 1 AND fecha_eliminacion < NOW() - INTERVAL 90 DAY
    AND id_producto NOT IN (SELECT id_producto FROM detalle_ventas);
END$$

DELIMITER ;

SHOW EVENTS FROM ecommerce_db;
