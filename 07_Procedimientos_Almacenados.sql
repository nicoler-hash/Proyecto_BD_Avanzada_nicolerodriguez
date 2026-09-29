-- =====================================================================
-- 07_Procedimientos_Almacenados.sql  |  20 procedimientos (MySQL 8.0.19+)
-- Requiere 01, 03, 05 y 06. Los procedimientos que modifican datos usan
-- transacciones y EXIT HANDLER con ROLLBACK + RESIGNAL; los de consulta
-- devuelven el mensaje de error como resultado.
-- =====================================================================
USE ecommerce_db;
SET NAMES utf8mb4;
DELIMITER $$

-- 1. RealizarNuevaVenta: crea venta + detalle desde un JSON [{"id_producto":1,"cantidad":2}], valida stock y calcula total
DROP PROCEDURE IF EXISTS RealizarNuevaVenta$$
CREATE PROCEDURE RealizarNuevaVenta(IN p_id_cliente INT, IN p_id_sucursal INT, IN p_items JSON, OUT p_id_venta INT)
BEGIN
  DECLARE v_esperados INT DEFAULT 0;
  DECLARE v_validos INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    DROP TEMPORARY TABLE IF EXISTS tmp_items_venta;
    SET p_id_venta = NULL;
    RESIGNAL;
  END;

  IF p_items IS NULL OR JSON_LENGTH(p_items) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta debe incluir al menos un producto';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND estado_cuenta = 'Activa') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM sucursales WHERE id_sucursal = p_id_sucursal) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sucursal inexistente';
  END IF;

  SET v_esperados = JSON_LENGTH(p_items);
  DROP TEMPORARY TABLE IF EXISTS tmp_items_venta;
  CREATE TEMPORARY TABLE tmp_items_venta (id_producto INT NOT NULL, cantidad INT NOT NULL, precio DECIMAL(12,2) NOT NULL);

  START TRANSACTION;
  -- Se captura el precio vigente en una tabla temporal (evita leer productos en el mismo INSERT que dispara los triggers)
  INSERT INTO tmp_items_venta (id_producto, cantidad, precio)
  SELECT jt.id_producto, jt.cantidad, p.precio
  FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_producto INT PATH '$.id_producto', cantidad INT PATH '$.cantidad')) AS jt
  JOIN productos p ON p.id_producto = jt.id_producto AND p.activo = 1 AND p.eliminado = 0;
  SET v_validos = ROW_COUNT();
  IF v_validos <> v_esperados THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Uno o más productos no existen o no están disponibles';
  END IF;

  INSERT INTO ventas (estado, id_cliente, id_sucursal) VALUES ('Pendiente de Pago', p_id_cliente, p_id_sucursal);
  SET p_id_venta = LAST_INSERT_ID();

  -- Los triggers check_stock_venta / update_stock_venta validan y descuentan el inventario
  INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado)
  SELECT p_id_venta, id_producto, cantidad, precio FROM tmp_items_venta;

  UPDATE ventas SET total = fn_CalcularTotalVenta(p_id_venta) WHERE id_venta = p_id_venta;
  COMMIT;
  DROP TEMPORARY TABLE IF EXISTS tmp_items_venta;
END$$

-- 2. AgregarNuevoProducto: alta de producto con SKU autogenerado y validaciones
DROP PROCEDURE IF EXISTS AgregarNuevoProducto$$
CREATE PROCEDURE AgregarNuevoProducto(
  IN p_nombre VARCHAR(150), IN p_descripcion TEXT, IN p_precio DECIMAL(12,2), IN p_costo DECIMAL(12,2),
  IN p_stock INT, IN p_stock_minimo INT, IN p_peso_kg DECIMAL(8,2), IN p_id_categoria INT, IN p_id_proveedor INT,
  OUT p_id_producto INT)
BEGIN
  DECLARE v_sku VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_id_producto = NULL; RESIGNAL; END;

  IF p_precio IS NULL OR p_precio <= 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Precio inválido'; END IF;
  IF p_costo IS NULL OR p_costo < 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Costo inválido'; END IF;
  IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proveedor inexistente';
  END IF;
  IF p_id_categoria IS NOT NULL AND NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría inexistente';
  END IF;

  START TRANSACTION;
  SET v_sku = fn_GenerarSKU(COALESCE(p_id_categoria, 0), p_nombre);
  INSERT INTO productos (nombre, descripcion, precio, costo, stock, stock_minimo, sku, peso_kg, id_categoria, id_proveedor)
  VALUES (p_nombre, p_descripcion, p_precio, p_costo, COALESCE(p_stock, 0), COALESCE(p_stock_minimo, 5), v_sku, COALESCE(p_peso_kg, 1), p_id_categoria, p_id_proveedor);
  SET p_id_producto = LAST_INSERT_ID();
  COMMIT;
END$$

-- 3. ActualizarDireccionCliente: cambia dirección y ciudad de envío de un cliente activo
DROP PROCEDURE IF EXISTS ActualizarDireccionCliente$$
CREATE PROCEDURE ActualizarDireccionCliente(IN p_id_cliente INT, IN p_direccion VARCHAR(255), IN p_ciudad VARCHAR(60))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_direccion IS NULL OR TRIM(p_direccion) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La dirección no puede estar vacía';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND estado_cuenta = 'Activa') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
  END IF;
  START TRANSACTION;
  UPDATE clientes SET direccion_envio = TRIM(p_direccion), ciudad = COALESCE(p_ciudad, ciudad) WHERE id_cliente = p_id_cliente;
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (p_id_cliente, 'CAMBIO_DIRECCION', CONCAT('Nueva dirección: ', TRIM(p_direccion)), CURRENT_USER());
  COMMIT;
END$$

-- 4. ProcesarDevolucion: valida cantidades, registra la devolución, repone stock y ajusta el gasto del cliente
DROP PROCEDURE IF EXISTS ProcesarDevolucion$$
CREATE PROCEDURE ProcesarDevolucion(IN p_id_venta INT, IN p_id_producto INT, IN p_cantidad INT, IN p_motivo VARCHAR(255))
BEGIN
  DECLARE v_estado VARCHAR(30);
  DECLARE v_id_cliente INT;
  DECLARE v_vendida INT DEFAULT 0;
  DECLARE v_devuelta INT DEFAULT 0;
  DECLARE v_precio DECIMAL(12,2) DEFAULT 0;
  DECLARE v_monto DECIMAL(12,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cantidad inválida'; END IF;
  START TRANSACTION;
  SELECT estado, id_cliente INTO v_estado, v_id_cliente FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inexistente'; END IF;
  IF v_estado <> 'Entregado' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden devolver ventas entregadas'; END IF;

  SELECT COALESCE(SUM(cantidad), 0), COALESCE(MAX(precio_unitario_congelado), 0) INTO v_vendida, v_precio
  FROM detalle_ventas WHERE id_venta = p_id_venta AND id_producto = p_id_producto;
  SELECT COALESCE(SUM(cantidad), 0) INTO v_devuelta FROM devoluciones WHERE id_venta = p_id_venta AND id_producto = p_id_producto;
  IF v_vendida = 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a la venta'; END IF;
  IF p_cantidad > v_vendida - v_devuelta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad supera lo disponible para devolución';
  END IF;

  SET v_monto = p_cantidad * v_precio;
  INSERT INTO devoluciones (id_venta, id_producto, cantidad, motivo, monto) VALUES (p_id_venta, p_id_producto, p_cantidad, p_motivo, v_monto);
  UPDATE productos SET stock = stock + p_cantidad WHERE id_producto = p_id_producto;
  UPDATE clientes SET total_gastado = GREATEST(total_gastado - v_monto, 0) WHERE id_cliente = v_id_cliente;
  COMMIT;
  SELECT v_monto AS monto_reembolsado;
END$$

-- 5. ObtenerHistorialCompras: ventas y líneas de detalle de un cliente, de la más reciente a la más antigua
DROP PROCEDURE IF EXISTS ObtenerHistorialCompras$$
CREATE PROCEDURE ObtenerHistorialCompras(IN p_id_cliente INT)
BEGIN
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  SELECT v.id_venta, v.fecha_venta, v.estado, p.nombre AS producto, d.cantidad, d.precio_unitario_congelado,
         (d.cantidad * d.precio_unitario_congelado) AS subtotal, v.total AS total_venta
  FROM ventas v
  JOIN detalle_ventas d ON d.id_venta = v.id_venta
  JOIN productos p ON p.id_producto = d.id_producto
  WHERE v.id_cliente = p_id_cliente
  ORDER BY v.fecha_venta DESC, v.id_venta DESC, p.nombre;
END$$

-- 6. AjustarNivelStock: suma o resta unidades (inventario físico) y registra el ajuste
DROP PROCEDURE IF EXISTS AjustarNivelStock$$
CREATE PROCEDURE AjustarNivelStock(IN p_id_producto INT, IN p_ajuste INT, IN p_motivo VARCHAR(255))
BEGIN
  DECLARE v_stock INT DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_ajuste IS NULL OR p_ajuste = 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El ajuste debe ser distinto de cero'; END IF;
  START TRANSACTION;
  SELECT stock INTO v_stock FROM productos WHERE id_producto = p_id_producto FOR UPDATE;
  IF v_stock IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente'; END IF;
  IF v_stock + p_ajuste < 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El ajuste dejaría el stock en negativo'; END IF;
  UPDATE productos SET stock = stock + p_ajuste WHERE id_producto = p_id_producto;
  INSERT INTO log_ajustes_stock (id_producto, ajuste, stock_anterior, stock_nuevo, motivo, usuario)
  VALUES (p_id_producto, p_ajuste, v_stock, v_stock + p_ajuste, p_motivo, CURRENT_USER());
  COMMIT;
END$$

-- 7. EliminarClienteSeguro: anonimiza los datos personales conservando el historial de ventas
DROP PROCEDURE IF EXISTS EliminarClienteSeguro$$
CREATE PROCEDURE EliminarClienteSeguro(IN p_id_cliente INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND estado_cuenta <> 'Anonimizada') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o ya anonimizado';
  END IF;
  START TRANSACTION;
  UPDATE clientes SET
    nombre = 'Anónimo', apellido = 'Eliminado',
    email = CONCAT('anonimo_', p_id_cliente, '@eliminado.local'),
    `contraseña` = SHA2(CONCAT(UUID(), RAND()), 256),
    direccion_envio = NULL, ciudad = NULL, fecha_nacimiento = NULL, id_referido = NULL,
    estado_cuenta = 'Anonimizada'
  WHERE id_cliente = p_id_cliente;
  UPDATE resenas SET comentario = NULL WHERE id_cliente = p_id_cliente;
  DELETE FROM carritos WHERE id_cliente = p_id_cliente;
  UPDATE vistas_producto SET id_cliente = NULL WHERE id_cliente = p_id_cliente;
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (p_id_cliente, 'ANONIMIZACION', 'Datos personales anonimizados', CURRENT_USER());
  COMMIT;
END$$

-- 8. AplicarDescuentoCategoria: rebaja el precio de una categoría sin bajar del costo; devuelve filas afectadas
DROP PROCEDURE IF EXISTS AplicarDescuentoCategoria$$
CREATE PROCEDURE AplicarDescuentoCategoria(IN p_id_categoria INT, IN p_porcentaje DECIMAL(5,2))
BEGIN
  DECLARE v_afectados INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_porcentaje IS NULL OR p_porcentaje <= 0 OR p_porcentaje > 90 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El porcentaje debe estar entre 0 y 90';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría inexistente';
  END IF;
  START TRANSACTION;
  UPDATE productos SET precio = fn_AplicarDescuento(precio, p_porcentaje)
  WHERE id_categoria = p_id_categoria AND eliminado = 0 AND fn_AplicarDescuento(precio, p_porcentaje) >= costo
    AND fn_AplicarDescuento(precio, p_porcentaje) > 0;
  SET v_afectados = ROW_COUNT();
  COMMIT;
  SELECT v_afectados AS productos_actualizados;
END$$

-- 9. GenerarReporteMensual: resumen, top productos y ventas por categoría del mes indicado
DROP PROCEDURE IF EXISTS GenerarReporteMensual$$
CREATE PROCEDURE GenerarReporteMensual(IN p_anio INT, IN p_mes INT)
BEGIN
  DECLARE v_ini DATE;
  DECLARE v_fin DATE;
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  IF p_mes NOT BETWEEN 1 AND 12 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mes inválido'; END IF;
  SET v_ini = MAKEDATE(p_anio, 1) + INTERVAL (p_mes - 1) MONTH;
  SET v_fin = v_ini + INTERVAL 1 MONTH;

  SELECT COUNT(*) AS num_ventas, COALESCE(SUM(total), 0) AS ingresos, COALESCE(ROUND(AVG(total), 2), 0) AS ticket_promedio,
         COUNT(DISTINCT id_cliente) AS clientes_activos
  FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin;

  SELECT p.nombre, SUM(d.cantidad) AS unidades, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta JOIN productos p ON p.id_producto = d.id_producto
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < v_fin
  GROUP BY p.nombre ORDER BY unidades DESC LIMIT 5;

  SELECT c.nombre AS categoria, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
  JOIN productos p ON p.id_producto = d.id_producto JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < v_fin
  GROUP BY c.nombre ORDER BY ingresos DESC;
END$$

-- 10. CambiarEstadoPedido: aplica transiciones válidas de estado; al cancelar repone el stock
DROP PROCEDURE IF EXISTS CambiarEstadoPedido$$
CREATE PROCEDURE CambiarEstadoPedido(IN p_id_venta INT, IN p_nuevo_estado VARCHAR(30))
BEGIN
  DECLARE v_estado VARCHAR(30) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
  SELECT estado INTO v_estado FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inexistente'; END IF;
  IF NOT (
       (v_estado = 'Pendiente de Pago' AND p_nuevo_estado IN ('Procesando','Cancelado'))
    OR (v_estado = 'Procesando'        AND p_nuevo_estado IN ('Enviado','Cancelado'))
    OR (v_estado = 'Enviado'           AND p_nuevo_estado = 'Entregado')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de estado no permitida';
  END IF;

  IF p_nuevo_estado = 'Cancelado' THEN
    UPDATE productos p
    JOIN (SELECT id_producto, SUM(cantidad) AS q FROM detalle_ventas WHERE id_venta = p_id_venta GROUP BY id_producto) d
      ON d.id_producto = p.id_producto
    SET p.stock = p.stock + d.q;
  END IF;

  UPDATE ventas SET estado = p_nuevo_estado,
    fecha_envio   = IF(p_nuevo_estado = 'Enviado', NOW(), fecha_envio),
    fecha_entrega = IF(p_nuevo_estado = 'Entregado', NOW(), fecha_entrega)
  WHERE id_venta = p_id_venta;
  COMMIT;
END$$

-- 11. RegistrarNuevoCliente: valida email y contraseña, almacena hash con sal y devuelve el id
DROP PROCEDURE IF EXISTS RegistrarNuevoCliente$$
CREATE PROCEDURE RegistrarNuevoCliente(
  IN p_nombre VARCHAR(80), IN p_apellido VARCHAR(80), IN p_email VARCHAR(150), IN p_password VARCHAR(255),
  IN p_direccion VARCHAR(255), IN p_ciudad VARCHAR(60), IN p_fecha_nacimiento DATE, IN p_id_referido INT,
  OUT p_id_cliente INT)
BEGIN
  DECLARE v_sal CHAR(16);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_id_cliente = NULL; RESIGNAL; END;
  IF fn_ValidarFormatoEmail(p_email) = 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Email inválido'; END IF;
  IF `fn_ValidarComplejidadContraseña`(p_password) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La contraseña debe tener 8+ caracteres, mayúscula, minúscula, número y símbolo';
  END IF;
  IF EXISTS (SELECT 1 FROM clientes WHERE email = p_email) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El email ya está registrado';
  END IF;
  IF p_id_referido IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_referido) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El cliente referido no existe';
  END IF;
  START TRANSACTION;
  SET v_sal = LEFT(SHA2(UUID(), 256), 16);
  INSERT INTO clientes (nombre, apellido, email, `contraseña`, direccion_envio, ciudad, fecha_nacimiento, id_referido)
  VALUES (p_nombre, p_apellido, p_email, CONCAT('sha256$', v_sal, '$', SHA2(CONCAT(v_sal, p_password), 256)),
          p_direccion, p_ciudad, p_fecha_nacimiento, p_id_referido);
  SET p_id_cliente = LAST_INSERT_ID();
  COMMIT;
END$$

-- 12. ObtenerDetallesProductoCompleto: ficha completa (categoría, proveedor, ventas, calificación) y últimas reseñas
DROP PROCEDURE IF EXISTS ObtenerDetallesProductoCompleto$$
CREATE PROCEDURE ObtenerDetallesProductoCompleto(IN p_id_producto INT)
BEGIN
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  IF NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente';
  END IF;
  SELECT p.id_producto, p.nombre, p.descripcion, p.sku, p.precio, p.costo, p.stock, p.stock_minimo, p.peso_kg, p.activo,
         c.nombre AS categoria, pr.nombre AS proveedor, pr.email_contacto,
         COALESCE((SELECT SUM(d.cantidad) FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
                   WHERE d.id_producto = p.id_producto AND v.estado <> 'Cancelado'), 0) AS unidades_vendidas,
         (SELECT ROUND(AVG(calificacion), 2) FROM resenas r WHERE r.id_producto = p.id_producto) AS calificacion_promedio,
         (SELECT COUNT(*) FROM resenas r WHERE r.id_producto = p.id_producto) AS total_resenas
  FROM productos p
  LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
  JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
  WHERE p.id_producto = p_id_producto;

  SELECT r.calificacion, r.comentario, r.compra_verificada, r.fecha, CONCAT(cl.nombre, ' ', LEFT(cl.apellido, 1), '.') AS autor
  FROM resenas r JOIN clientes cl ON cl.id_cliente = r.id_cliente
  WHERE r.id_producto = p_id_producto ORDER BY r.fecha DESC LIMIT 5;
END$$

-- 13. FusionarCuentasCliente: traslada ventas, carritos, reseñas y vistas de un duplicado a la cuenta principal y elimina el duplicado
DROP PROCEDURE IF EXISTS FusionarCuentasCliente$$
CREATE PROCEDURE FusionarCuentasCliente(IN p_id_principal INT, IN p_id_duplicado INT)
BEGIN
  DECLARE v_gastado DECIMAL(14,2) DEFAULT 0;
  DECLARE v_ultima DATETIME DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_id_principal = p_id_duplicado THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las cuentas deben ser distintas'; END IF;
  IF (SELECT COUNT(*) FROM clientes WHERE id_cliente IN (p_id_principal, p_id_duplicado)) <> 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alguna de las cuentas no existe';
  END IF;
  START TRANSACTION;
  SELECT total_gastado, fecha_ultima_compra INTO v_gastado, v_ultima FROM clientes WHERE id_cliente = p_id_duplicado FOR UPDATE;

  UPDATE ventas SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
  UPDATE carritos SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
  UPDATE resenas SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
  UPDATE vistas_producto SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;

  UPDATE clientes SET id_referido = NULL WHERE id_cliente = p_id_principal AND id_referido = p_id_duplicado;
  UPDATE clientes SET id_referido = p_id_principal WHERE id_referido = p_id_duplicado AND id_cliente <> p_id_principal;

  UPDATE clientes SET total_gastado = total_gastado + v_gastado,
    fecha_ultima_compra = CASE WHEN v_ultima IS NULL THEN fecha_ultima_compra
                               WHEN fecha_ultima_compra IS NULL THEN v_ultima
                               ELSE GREATEST(fecha_ultima_compra, v_ultima) END
  WHERE id_cliente = p_id_principal;

  DELETE FROM clientes WHERE id_cliente = p_id_duplicado;
  INSERT INTO log_clientes (id_cliente, accion, detalle, usuario)
  VALUES (p_id_principal, 'FUSION', CONCAT('Fusionada la cuenta ', p_id_duplicado), CURRENT_USER());
  COMMIT;
END$$

-- 14. AsignarProductoProveedor: cambia el proveedor de un producto tras validar ambos
DROP PROCEDURE IF EXISTS AsignarProductoProveedor$$
CREATE PROCEDURE AsignarProductoProveedor(IN p_id_producto INT, IN p_id_proveedor INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proveedor inexistente';
  END IF;
  START TRANSACTION;
  UPDATE productos SET id_proveedor = p_id_proveedor WHERE id_producto = p_id_producto;
  COMMIT;
END$$

-- 15. BuscarProductos: búsqueda con filtros opcionales (texto, categoría, rango de precio, disponibilidad) y paginación
DROP PROCEDURE IF EXISTS BuscarProductos$$
CREATE PROCEDURE BuscarProductos(
  IN p_texto VARCHAR(100), IN p_id_categoria INT, IN p_precio_min DECIMAL(12,2), IN p_precio_max DECIMAL(12,2),
  IN p_solo_disponibles TINYINT, IN p_limite INT, IN p_offset INT)
BEGIN
  DECLARE v_limite INT DEFAULT 20;
  DECLARE v_offset INT DEFAULT 0;
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  SET v_limite = LEAST(GREATEST(COALESCE(p_limite, 20), 1), 100);
  SET v_offset = GREATEST(COALESCE(p_offset, 0), 0);
  SELECT p.id_producto, p.nombre, p.sku, p.precio, p.stock, c.nombre AS categoria
  FROM productos p LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE p.activo = 1 AND p.eliminado = 0
    AND (p_texto IS NULL OR p.nombre LIKE CONCAT('%', p_texto, '%') OR p.descripcion LIKE CONCAT('%', p_texto, '%') OR p.sku LIKE CONCAT('%', p_texto, '%'))
    AND (p_id_categoria IS NULL OR p.id_categoria = p_id_categoria)
    AND (p_precio_min IS NULL OR p.precio >= p_precio_min)
    AND (p_precio_max IS NULL OR p.precio <= p_precio_max)
    AND (COALESCE(p_solo_disponibles, 0) = 0 OR p.stock > 0)
  ORDER BY p.nombre
  LIMIT v_limite OFFSET v_offset;
END$$

-- 16. ObtenerDashboardAdmin: indicadores clave, pedidos pendientes, alertas y tendencia de 7 días
DROP PROCEDURE IF EXISTS ObtenerDashboardAdmin$$
CREATE PROCEDURE ObtenerDashboardAdmin()
BEGIN
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  SELECT
    (SELECT COUNT(*) FROM ventas WHERE estado <> 'Cancelado' AND DATE(fecha_venta) = CURDATE()) AS ventas_hoy,
    (SELECT COALESCE(SUM(total), 0) FROM ventas WHERE estado <> 'Cancelado' AND DATE(fecha_venta) = CURDATE()) AS ingresos_hoy,
    (SELECT COALESCE(SUM(total), 0) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= DATE_SUB(CURDATE(), INTERVAL DAYOFMONTH(CURDATE()) - 1 DAY)) AS ingresos_mes,
    (SELECT COUNT(*) FROM ventas WHERE estado IN ('Pendiente de Pago','Procesando')) AS pedidos_pendientes,
    (SELECT COUNT(*) FROM productos WHERE stock <= stock_minimo AND activo = 1 AND eliminado = 0) AS productos_bajo_stock,
    (SELECT COUNT(*) FROM clientes WHERE fecha_registro >= NOW() - INTERVAL 30 DAY) AS clientes_nuevos_30d,
    (SELECT COUNT(*) FROM carritos WHERE estado = 'Activo' AND fecha_actualizacion < NOW() - INTERVAL 24 HOUR) AS carritos_abandonados;

  SELECT p.nombre, SUM(d.cantidad) AS unidades
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  JOIN productos p ON p.id_producto = d.id_producto
  GROUP BY p.nombre ORDER BY unidades DESC LIMIT 5;

  SELECT DATE(fecha_venta) AS dia, COUNT(*) AS ventas, SUM(total) AS ingresos
  FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= DATE_SUB(CURDATE(), INTERVAL 7 DAY)
  GROUP BY DATE(fecha_venta) ORDER BY dia;

  SELECT a.id_alerta, p.nombre, a.stock_actual, a.stock_minimo, a.fecha
  FROM log_alertas_stock a JOIN productos p ON p.id_producto = a.id_producto
  WHERE a.atendida = 0 ORDER BY a.fecha DESC LIMIT 10;
END$$

-- 17. ProcesarPago: registra un pago simulado; si el monto cubre el total aprueba y pasa la venta a 'Procesando'
DROP PROCEDURE IF EXISTS ProcesarPago$$
CREATE PROCEDURE ProcesarPago(IN p_id_venta INT, IN p_monto DECIMAL(14,2), IN p_metodo VARCHAR(20), OUT p_estado_pago VARCHAR(20))
BEGIN
  DECLARE v_estado VARCHAR(30) DEFAULT NULL;
  DECLARE v_total DECIMAL(14,2) DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_estado_pago = 'Error'; RESIGNAL; END;
  IF p_metodo NOT IN ('Tarjeta','PSE','Transferencia','Efectivo') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Método de pago no soportado';
  END IF;
  START TRANSACTION;
  SELECT estado, total INTO v_estado, v_total FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inexistente'; END IF;
  IF v_estado <> 'Pendiente de Pago' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no está pendiente de pago'; END IF;

  IF p_monto IS NOT NULL AND p_monto >= v_total THEN
    INSERT INTO pagos (id_venta, monto, metodo, estado) VALUES (p_id_venta, v_total, p_metodo, 'Aprobado');
    UPDATE ventas SET estado = 'Procesando' WHERE id_venta = p_id_venta;
    SET p_estado_pago = 'Aprobado';
  ELSE
    INSERT INTO pagos (id_venta, monto, metodo, estado) VALUES (p_id_venta, COALESCE(p_monto, 0), p_metodo, 'Rechazado');
    SET p_estado_pago = 'Rechazado';
  END IF;
  COMMIT;
END$$

-- 18. AñadirReseñaProducto: crea o actualiza la reseña del cliente y marca si la compra fue verificada
DROP PROCEDURE IF EXISTS `AñadirReseñaProducto`$$
CREATE PROCEDURE `AñadirReseñaProducto`(IN p_id_cliente INT, IN p_id_producto INT, IN p_calificacion TINYINT, IN p_comentario TEXT)
BEGIN
  DECLARE v_verificada TINYINT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_calificacion IS NULL OR p_calificacion NOT BETWEEN 1 AND 5 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La calificación debe estar entre 1 y 5';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND estado_cuenta = 'Activa') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente';
  END IF;
  START TRANSACTION;
  SELECT EXISTS (SELECT 1 FROM ventas v JOIN detalle_ventas d ON d.id_venta = v.id_venta
                 WHERE v.id_cliente = p_id_cliente AND d.id_producto = p_id_producto AND v.estado = 'Entregado') INTO v_verificada;
  IF EXISTS (SELECT 1 FROM resenas WHERE id_cliente = p_id_cliente AND id_producto = p_id_producto) THEN
    UPDATE resenas SET calificacion = p_calificacion, comentario = p_comentario, compra_verificada = v_verificada, fecha = NOW()
    WHERE id_cliente = p_id_cliente AND id_producto = p_id_producto;
  ELSE
    INSERT INTO resenas (id_producto, id_cliente, calificacion, comentario, compra_verificada)
    VALUES (p_id_producto, p_id_cliente, p_calificacion, p_comentario, v_verificada);
  END IF;
  COMMIT;
END$$

-- 19. ObtenerProductosRelacionados: productos comprados junto al indicado y de su misma categoría
DROP PROCEDURE IF EXISTS ObtenerProductosRelacionados$$
CREATE PROCEDURE ObtenerProductosRelacionados(IN p_id_producto INT, IN p_limite INT)
BEGIN
  DECLARE v_limite INT DEFAULT 5;
  DECLARE v_msg TEXT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT; SELECT v_msg AS error; END;
  SET v_limite = LEAST(GREATEST(COALESCE(p_limite, 5), 1), 50);
  SELECT p.id_producto, p.nombre, p.precio,
         COALESCE(co.veces, 0) AS veces_comprado_junto,
         (p.id_categoria = base.id_categoria) AS misma_categoria
  FROM productos p
  JOIN (SELECT id_categoria FROM productos WHERE id_producto = p_id_producto) base
  LEFT JOIN (
    SELECT d2.id_producto, COUNT(DISTINCT d2.id_venta) AS veces
    FROM detalle_ventas d1
    JOIN detalle_ventas d2 ON d2.id_venta = d1.id_venta AND d2.id_producto <> d1.id_producto
    WHERE d1.id_producto = p_id_producto
    GROUP BY d2.id_producto
  ) co ON co.id_producto = p.id_producto
  WHERE p.id_producto <> p_id_producto AND p.activo = 1 AND p.eliminado = 0
    AND (co.veces IS NOT NULL OR p.id_categoria = base.id_categoria)
  ORDER BY veces_comprado_junto DESC, misma_categoria DESC, p.nombre
  LIMIT v_limite;
END$$

-- 20. MoverProductosEntreCategorias: mueve todos (o una lista JSON de ids) los productos de una categoría a otra y recalcula contadores
DROP PROCEDURE IF EXISTS MoverProductosEntreCategorias$$
CREATE PROCEDURE MoverProductosEntreCategorias(IN p_id_origen INT, IN p_id_destino INT, IN p_ids JSON)
BEGIN
  DECLARE v_movidos INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  IF p_id_origen = p_id_destino THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Origen y destino deben ser distintos'; END IF;
  IF (SELECT COUNT(*) FROM categorias WHERE id_categoria IN (p_id_origen, p_id_destino)) <> 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alguna de las categorías no existe';
  END IF;
  START TRANSACTION;
  UPDATE productos SET id_categoria = p_id_destino
  WHERE id_categoria = p_id_origen AND (p_ids IS NULL OR JSON_CONTAINS(p_ids, CAST(id_producto AS JSON)));
  SET v_movidos = ROW_COUNT();
  UPDATE categorias c SET c.total_productos = (SELECT COUNT(*) FROM productos p WHERE p.id_categoria = c.id_categoria)
  WHERE c.id_categoria IN (p_id_origen, p_id_destino);
  COMMIT;
  SELECT v_movidos AS productos_movidos;
END$$

DELIMITER ;

-- Ejemplos de uso
-- CALL RealizarNuevaVenta(8, 3, '[{"id_producto":3,"cantidad":1},{"id_producto":8,"cantidad":2}]', @id_venta); SELECT @id_venta;
-- CALL ProcesarPago(@id_venta, 78.00, 'Tarjeta', @estado); SELECT @estado;
-- CALL CambiarEstadoPedido(@id_venta, 'Enviado');
-- CALL BuscarProductos('la', NULL, NULL, 100, 1, 10, 0);
-- CALL ObtenerProductosRelacionados(3, 5);
