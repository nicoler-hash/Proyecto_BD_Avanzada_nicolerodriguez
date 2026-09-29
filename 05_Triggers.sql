-- =====================================================================
-- 05_Triggers.sql  |  Tablas de auditoría + 20 triggers (MySQL 8.0+)
-- Requiere 01 y 03 (usa fn_ValidarFormatoEmail y fn_CalcularTotalVenta).
-- =====================================================================
USE ecommerce_db;
SET NAMES utf8mb4;

-- ------------------------- Tablas de auditoría -----------------------
CREATE TABLE IF NOT EXISTS log_auditoria_precio (
  id_log INT AUTO_INCREMENT PRIMARY KEY, id_producto INT NOT NULL,
  precio_anterior DECIMAL(12,2), precio_nuevo DECIMAL(12,2),
  usuario VARCHAR(100), fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_clientes (
  id_log INT AUTO_INCREMENT PRIMARY KEY, id_cliente INT NOT NULL,
  accion VARCHAR(50) NOT NULL, detalle VARCHAR(255),
  usuario VARCHAR(100), fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_estado_pedido (
  id_log INT AUTO_INCREMENT PRIMARY KEY, id_venta INT NOT NULL,
  estado_anterior VARCHAR(30), estado_nuevo VARCHAR(30),
  usuario VARCHAR(100), fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_alertas_stock (
  id_alerta INT AUTO_INCREMENT PRIMARY KEY, id_producto INT NOT NULL,
  stock_actual INT NOT NULL, stock_minimo INT NOT NULL,
  atendida TINYINT(1) NOT NULL DEFAULT 0, fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_ajustes_stock (
  id_log INT AUTO_INCREMENT PRIMARY KEY, id_producto INT NOT NULL, ajuste INT NOT NULL,
  stock_anterior INT NOT NULL, stock_nuevo INT NOT NULL, motivo VARCHAR(255),
  usuario VARCHAR(100), fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ventas_archivo (
  id_venta INT PRIMARY KEY, fecha_venta DATETIME, estado VARCHAR(30), total DECIMAL(14,2),
  id_cliente INT, id_sucursal INT, fecha_envio DATETIME, fecha_entrega DATETIME,
  usuario_elimino VARCHAR(100), fecha_archivado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS detalle_ventas_archivo (
  id_detalle INT PRIMARY KEY, id_venta INT NOT NULL, id_producto INT NOT NULL,
  cantidad INT NOT NULL, precio_unitario_congelado DECIMAL(12,2) NOT NULL
) ENGINE=InnoDB;

-- Permisos de aplicación (simulación para auditar cambios de permisos)
CREATE TABLE IF NOT EXISTS permisos_usuario (
  id INT AUTO_INCREMENT PRIMARY KEY, usuario VARCHAR(64) NOT NULL, rol VARCHAR(64) NOT NULL,
  activo TINYINT(1) NOT NULL DEFAULT 1, fecha_modificacion DATETIME NULL,
  UNIQUE KEY uq_usuario_rol (usuario, rol)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_permisos (
  id_log INT AUTO_INCREMENT PRIMARY KEY, usuario VARCHAR(64), rol_anterior VARCHAR(64), rol_nuevo VARCHAR(64),
  activo_anterior TINYINT(1), activo_nuevo TINYINT(1), modificado_por VARCHAR(100),
  fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT IGNORE INTO permisos_usuario (usuario, rol, activo) VALUES
('admin_user','Administrador_Sistema',1), ('marketing_user','Gerente_Marketing',1),
('inventory_user','Empleado_Inventario',1), ('support_user','Atencion_Cliente',1),
('analista_user','Analista_Datos',1);

DELIMITER $$

-- 1. audit_precio_producto: registra cada cambio de precio con usuario y fecha
DROP TRIGGER IF EXISTS audit_precio_producto$$
CREATE TRIGGER audit_precio_producto AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NOT (OLD.precio <=> NEW.precio) THEN
    INSERT INTO log_auditoria_precio (id_producto, precio_anterior, precio_nuevo, usuario)
    VALUES (NEW.id_producto, OLD.precio, NEW.precio, CURRENT_USER());
  END IF;
END$$

-- 2. check_stock_venta: impide insertar un detalle si no hay stock suficiente (bloquea la fila)
DROP TRIGGER IF EXISTS check_stock_venta$$
CREATE TRIGGER check_stock_venta BEFORE INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  DECLARE v_stock INT DEFAULT NULL;
  SELECT stock INTO v_stock FROM productos WHERE id_producto = NEW.id_producto FOR UPDATE;
  IF v_stock IS NULL OR v_stock < NEW.cantidad THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para el producto solicitado';
  END IF;
END$$

-- 3. update_stock_venta: descuenta del inventario la cantidad vendida
DROP TRIGGER IF EXISTS update_stock_venta$$
CREATE TRIGGER update_stock_venta AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
END$$

-- 4. prevent_delete_categoria: bloquea borrar categorías con productos o la categoría por defecto
DROP TRIGGER IF EXISTS prevent_delete_categoria$$
CREATE TRIGGER prevent_delete_categoria BEFORE DELETE ON categorias FOR EACH ROW
BEGIN
  IF OLD.nombre = 'Sin Categoría' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede eliminar la categoría por defecto';
  END IF;
  IF EXISTS (SELECT 1 FROM productos WHERE id_categoria = OLD.id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede eliminar una categoría que tiene productos asociados';
  END IF;
END$$

-- 5. log_new_customer: deja constancia del alta de cada cliente
DROP TRIGGER IF EXISTS log_new_customer$$
CREATE TRIGGER log_new_customer AFTER INSERT ON clientes FOR EACH ROW
BEGIN
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (NEW.id_cliente, 'ALTA', CONCAT('Nuevo cliente: ', NEW.email), CURRENT_USER());
END$$

-- 6. update_total_gastado: suma/resta el total de la venta al gasto del cliente al entrar/salir de 'Entregado'
DROP TRIGGER IF EXISTS update_total_gastado$$
CREATE TRIGGER update_total_gastado AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF NEW.estado = 'Entregado' AND OLD.estado <> 'Entregado' THEN
    UPDATE clientes SET total_gastado = total_gastado + NEW.total WHERE id_cliente = NEW.id_cliente;
  ELSEIF OLD.estado = 'Entregado' AND NEW.estado <> 'Entregado' THEN
    UPDATE clientes SET total_gastado = GREATEST(total_gastado - OLD.total, 0) WHERE id_cliente = NEW.id_cliente;
  END IF;
END$$

-- 7. set_fecha_modificacion_producto: sella la fecha de última modificación del producto
DROP TRIGGER IF EXISTS set_fecha_modificacion_producto$$
CREATE TRIGGER set_fecha_modificacion_producto BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  SET NEW.fecha_modificacion = NOW();
END$$

-- 8. prevent_negative_stock: rechaza actualizaciones que dejen el stock en negativo
DROP TRIGGER IF EXISTS prevent_negative_stock$$
CREATE TRIGGER prevent_negative_stock BEFORE UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
  END IF;
END$$

-- 9. capitalize_nombre_cliente: normaliza nombre y apellido (primera letra en mayúscula)
DROP TRIGGER IF EXISTS capitalize_nombre_cliente$$
CREATE TRIGGER capitalize_nombre_cliente BEFORE INSERT ON clientes FOR EACH ROW
BEGIN
  SET NEW.nombre   = CONCAT(UPPER(LEFT(TRIM(NEW.nombre), 1)),   LOWER(SUBSTRING(TRIM(NEW.nombre), 2)));
  SET NEW.apellido = CONCAT(UPPER(LEFT(TRIM(NEW.apellido), 1)), LOWER(SUBSTRING(TRIM(NEW.apellido), 2)));
END$$

-- 10. recalculate_total_venta: recalcula el total de la venta al agregar líneas de detalle
DROP TRIGGER IF EXISTS recalculate_total_venta$$
CREATE TRIGGER recalculate_total_venta AFTER INSERT ON detalle_ventas FOR EACH ROW
BEGIN
  UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
END$$

-- 11. log_order_status_change: historial de cambios de estado de pedidos
DROP TRIGGER IF EXISTS log_order_status_change$$
CREATE TRIGGER log_order_status_change AFTER UPDATE ON ventas FOR EACH ROW
BEGIN
  IF OLD.estado <> NEW.estado THEN
    INSERT INTO log_estado_pedido (id_venta, estado_anterior, estado_nuevo, usuario)
    VALUES (NEW.id_venta, OLD.estado, NEW.estado, CURRENT_USER());
  END IF;
END$$

-- 12. prevent_price_zero: no permite crear productos con precio nulo o menor/igual a cero
DROP TRIGGER IF EXISTS prevent_price_zero$$
CREATE TRIGGER prevent_price_zero BEFORE INSERT ON productos FOR EACH ROW
BEGIN
  IF NEW.precio IS NULL OR NEW.precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio del producto debe ser mayor que cero';
  END IF;
END$$

-- 13. send_stock_alert: genera una alerta cuando el stock cruza el umbral mínimo
DROP TRIGGER IF EXISTS send_stock_alert$$
CREATE TRIGGER send_stock_alert AFTER UPDATE ON productos FOR EACH ROW
BEGIN
  IF NEW.stock <= NEW.stock_minimo AND OLD.stock > OLD.stock_minimo THEN
    INSERT INTO log_alertas_stock (id_producto, stock_actual, stock_minimo)
    VALUES (NEW.id_producto, NEW.stock, NEW.stock_minimo);
  END IF;
END$$

-- 14. archive_deleted_venta: archiva cabecera y detalle antes de borrar una venta
DROP TRIGGER IF EXISTS archive_deleted_venta$$
CREATE TRIGGER archive_deleted_venta BEFORE DELETE ON ventas FOR EACH ROW
BEGIN
  INSERT INTO ventas_archivo (id_venta, fecha_venta, estado, total, id_cliente, id_sucursal, fecha_envio, fecha_entrega, usuario_elimino)
  VALUES (OLD.id_venta, OLD.fecha_venta, OLD.estado, OLD.total, OLD.id_cliente, OLD.id_sucursal, OLD.fecha_envio, OLD.fecha_entrega, CURRENT_USER());
  INSERT INTO detalle_ventas_archivo (id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado)
  SELECT id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado
  FROM detalle_ventas WHERE id_venta = OLD.id_venta;
END$$

-- 15. validate_email_format: valida el formato del email antes de registrar un cliente
DROP TRIGGER IF EXISTS validate_email_format$$
CREATE TRIGGER validate_email_format BEFORE INSERT ON clientes FOR EACH ROW
BEGIN
  IF fn_ValidarFormatoEmail(NEW.email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de correo electrónico inválido';
  END IF;
END$$

-- 16. update_last_order_date: actualiza la fecha de última compra del cliente al crear una venta
DROP TRIGGER IF EXISTS update_last_order_date$$
CREATE TRIGGER update_last_order_date AFTER INSERT ON ventas FOR EACH ROW
BEGIN
  UPDATE clientes SET fecha_ultima_compra = NEW.fecha_venta WHERE id_cliente = NEW.id_cliente;
END$$

-- 17. prevent_self_referral: un cliente no puede ser su propio referido
DROP TRIGGER IF EXISTS prevent_self_referral$$
CREATE TRIGGER prevent_self_referral BEFORE UPDATE ON clientes FOR EACH ROW
BEGIN
  IF NEW.id_referido IS NOT NULL AND NEW.id_referido = NEW.id_cliente THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un cliente no puede referirse a sí mismo';
  END IF;
END$$

-- 18. log_permission_changes: audita cambios en roles/estado de permisos de aplicación
DROP TRIGGER IF EXISTS log_permission_changes$$
CREATE TRIGGER log_permission_changes AFTER UPDATE ON permisos_usuario FOR EACH ROW
BEGIN
  IF NOT (OLD.rol <=> NEW.rol) OR NOT (OLD.activo <=> NEW.activo) THEN
    INSERT INTO log_permisos (usuario, rol_anterior, rol_nuevo, activo_anterior, activo_nuevo, modificado_por)
    VALUES (NEW.usuario, OLD.rol, NEW.rol, OLD.activo, NEW.activo, CURRENT_USER());
  END IF;
END$$

-- 19. assign_default_category: asigna 'Sin Categoría' (creándola si falta) cuando el producto no trae categoría
DROP TRIGGER IF EXISTS assign_default_category$$
CREATE TRIGGER assign_default_category BEFORE INSERT ON productos FOR EACH ROW
BEGIN
  DECLARE v_cat INT DEFAULT NULL;
  IF NEW.id_categoria IS NULL THEN
    SELECT id_categoria INTO v_cat FROM categorias WHERE nombre = 'Sin Categoría' LIMIT 1;
    IF v_cat IS NULL THEN
      INSERT INTO categorias (nombre, descripcion) VALUES ('Sin Categoría', 'Categoría por defecto para productos sin clasificar');
      SET v_cat = LAST_INSERT_ID();
    END IF;
    SET NEW.id_categoria = v_cat;
  END IF;
END$$

-- 20. update_producto_count: incrementa el contador de productos de la categoría al crear un producto
DROP TRIGGER IF EXISTS update_producto_count$$
CREATE TRIGGER update_producto_count AFTER INSERT ON productos FOR EACH ROW
BEGIN
  IF NEW.id_categoria IS NOT NULL THEN
    UPDATE categorias SET total_productos = total_productos + 1 WHERE id_categoria = NEW.id_categoria;
  END IF;
END$$

DELIMITER ;

SHOW TRIGGERS FROM ecommerce_db;
