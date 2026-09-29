-- =====================================================================
-- 03_Funciones.sql  |  20 funciones definidas por el usuario (MySQL 8.0+)
-- =====================================================================
USE ecommerce_db;
SET NAMES utf8mb4;
DELIMITER $$

-- 1. fn_CalcularTotalVenta: suma cantidad * precio congelado de una venta
DROP FUNCTION IF EXISTS fn_CalcularTotalVenta$$
CREATE FUNCTION fn_CalcularTotalVenta(p_id_venta INT) RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(14,2) DEFAULT 0;
  SELECT COALESCE(SUM(cantidad * precio_unitario_congelado), 0) INTO v_total
  FROM detalle_ventas WHERE id_venta = p_id_venta;
  RETURN v_total;
END$$

-- 2. fn_VerificarDisponibilidadStock: 1 si el producto está activo y tiene stock suficiente
DROP FUNCTION IF EXISTS fn_VerificarDisponibilidadStock$$
CREATE FUNCTION fn_VerificarDisponibilidadStock(p_id_producto INT, p_cantidad INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
  DECLARE v_stock INT DEFAULT NULL;
  DECLARE v_activo TINYINT DEFAULT 0;
  SELECT stock, (activo = 1 AND eliminado = 0) INTO v_stock, v_activo
  FROM productos WHERE id_producto = p_id_producto;
  RETURN IF(v_stock IS NOT NULL AND v_activo = 1 AND v_stock >= p_cantidad, 1, 0);
END$$

-- 3. fn_ObtenerPrecioProducto: precio vigente (NULL si no existe)
DROP FUNCTION IF EXISTS fn_ObtenerPrecioProducto$$
CREATE FUNCTION fn_ObtenerPrecioProducto(p_id_producto INT) RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
  DECLARE v_precio DECIMAL(12,2) DEFAULT NULL;
  SELECT precio INTO v_precio FROM productos WHERE id_producto = p_id_producto;
  RETURN v_precio;
END$$

-- 4. fn_CalcularEdadCliente: edad en años a partir de fecha_nacimiento (simulada)
DROP FUNCTION IF EXISTS fn_CalcularEdadCliente$$
CREATE FUNCTION fn_CalcularEdadCliente(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_nac DATE DEFAULT NULL;
  SELECT fecha_nacimiento INTO v_nac FROM clientes WHERE id_cliente = p_id_cliente;
  RETURN IF(v_nac IS NULL, NULL, TIMESTAMPDIFF(YEAR, v_nac, CURDATE()));
END$$

-- 5. fn_FormatearNombreCompleto: devuelve "Apellido, Nombre" con capitalización correcta
DROP FUNCTION IF EXISTS fn_FormatearNombreCompleto$$
CREATE FUNCTION fn_FormatearNombreCompleto(p_nombre VARCHAR(80), p_apellido VARCHAR(80)) RETURNS VARCHAR(170)
DETERMINISTIC
BEGIN
  RETURN CONCAT(
    UPPER(LEFT(TRIM(p_apellido), 1)), LOWER(SUBSTRING(TRIM(p_apellido), 2)), ', ',
    UPPER(LEFT(TRIM(p_nombre), 1)),   LOWER(SUBSTRING(TRIM(p_nombre), 2)));
END$$

-- 6. fn_EsClienteNuevo: 1 si el cliente se registró en los últimos 30 días
DROP FUNCTION IF EXISTS fn_EsClienteNuevo$$
CREATE FUNCTION fn_EsClienteNuevo(p_id_cliente INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
  DECLARE v_reg DATETIME DEFAULT NULL;
  SELECT fecha_registro INTO v_reg FROM clientes WHERE id_cliente = p_id_cliente;
  RETURN IF(v_reg IS NOT NULL AND v_reg >= NOW() - INTERVAL 30 DAY, 1, 0);
END$$

-- 7. fn_CalcularCostoEnvio: tarifa base + costo por kg (peso simulado) + recargo por peso alto
DROP FUNCTION IF EXISTS fn_CalcularCostoEnvio$$
CREATE FUNCTION fn_CalcularCostoEnvio(p_peso_kg DECIMAL(8,2)) RETURNS DECIMAL(10,2)
DETERMINISTIC
BEGIN
  DECLARE v_costo DECIMAL(10,2);
  IF p_peso_kg IS NULL OR p_peso_kg <= 0 THEN RETURN 0; END IF;
  SET v_costo = 5.00 + (p_peso_kg * 1.50);
  IF p_peso_kg > 20 THEN SET v_costo = v_costo + 10.00; END IF;
  RETURN ROUND(v_costo, 2);
END$$

-- 8. fn_AplicarDescuento: precio con descuento porcentual (limitado a 0-100%)
DROP FUNCTION IF EXISTS fn_AplicarDescuento$$
CREATE FUNCTION fn_AplicarDescuento(p_precio DECIMAL(12,2), p_porcentaje DECIMAL(5,2)) RETURNS DECIMAL(12,2)
DETERMINISTIC
BEGIN
  DECLARE v_pct DECIMAL(5,2);
  SET v_pct = LEAST(GREATEST(COALESCE(p_porcentaje, 0), 0), 100);
  RETURN ROUND(p_precio * (1 - v_pct / 100), 2);
END$$

-- 9. fn_ObtenerUltimaFechaCompra: fecha de la última compra válida (no cancelada)
DROP FUNCTION IF EXISTS fn_ObtenerUltimaFechaCompra$$
CREATE FUNCTION fn_ObtenerUltimaFechaCompra(p_id_cliente INT) RETURNS DATETIME
READS SQL DATA
BEGIN
  DECLARE v_fecha DATETIME DEFAULT NULL;
  SELECT MAX(fecha_venta) INTO v_fecha FROM ventas
  WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN v_fecha;
END$$

-- 10. fn_ValidarFormatoEmail: 1 si el correo tiene un formato válido
DROP FUNCTION IF EXISTS fn_ValidarFormatoEmail$$
CREATE FUNCTION fn_ValidarFormatoEmail(p_email VARCHAR(150)) RETURNS TINYINT(1)
DETERMINISTIC
BEGIN
  IF p_email IS NULL THEN RETURN 0; END IF;
  RETURN IF(p_email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$', 1, 0);
END$$

-- 11. fn_ObtenerNombreCategoria: nombre de la categoría de un producto
DROP FUNCTION IF EXISTS fn_ObtenerNombreCategoria$$
CREATE FUNCTION fn_ObtenerNombreCategoria(p_id_producto INT) RETURNS VARCHAR(100)
READS SQL DATA
BEGIN
  DECLARE v_nombre VARCHAR(100) DEFAULT NULL;
  SELECT c.nombre INTO v_nombre
  FROM productos p JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE p.id_producto = p_id_producto;
  RETURN v_nombre;
END$$

-- 12. fn_ContarVentasCliente: número de ventas válidas de un cliente
DROP FUNCTION IF EXISTS fn_ContarVentasCliente$$
CREATE FUNCTION fn_ContarVentasCliente(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_n INT DEFAULT 0;
  SELECT COUNT(*) INTO v_n FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN v_n;
END$$

-- 13. fn_CalcularDiasDesdeUltimaCompra: días transcurridos desde la última compra (NULL si nunca compró)
DROP FUNCTION IF EXISTS fn_CalcularDiasDesdeUltimaCompra$$
CREATE FUNCTION fn_CalcularDiasDesdeUltimaCompra(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_ultima DATETIME;
  SET v_ultima = fn_ObtenerUltimaFechaCompra(p_id_cliente);
  RETURN IF(v_ultima IS NULL, NULL, DATEDIFF(CURDATE(), DATE(v_ultima)));
END$$

-- 14. fn_DeterminarEstadoLealtad: nivel según gasto acumulado (Bronce/Plata/Oro/Platino)
DROP FUNCTION IF EXISTS fn_DeterminarEstadoLealtad$$
CREATE FUNCTION fn_DeterminarEstadoLealtad(p_id_cliente INT) RETURNS VARCHAR(20)
READS SQL DATA
BEGIN
  DECLARE v_gasto DECIMAL(14,2) DEFAULT 0;
  DECLARE v_n INT DEFAULT 0;
  SELECT COALESCE(SUM(total), 0), COUNT(*) INTO v_gasto, v_n
  FROM ventas WHERE id_cliente = p_id_cliente AND estado IN ('Procesando','Enviado','Entregado');
  IF v_n = 0 THEN RETURN 'Sin compras';
  ELSEIF v_gasto >= 3000 THEN RETURN 'Platino';
  ELSEIF v_gasto >= 1500 THEN RETURN 'Oro';
  ELSEIF v_gasto >= 500  THEN RETURN 'Plata';
  ELSE RETURN 'Bronce';
  END IF;
END$$

-- 15. fn_GenerarSKU: SKU con formato CAT-PRO-0000 (3 letras de categoría, 3 del nombre, consecutivo)
DROP FUNCTION IF EXISTS fn_GenerarSKU$$
CREATE FUNCTION fn_GenerarSKU(p_id_categoria INT, p_nombre VARCHAR(150)) RETURNS VARCHAR(30)
READS SQL DATA
BEGIN
  DECLARE v_cat VARCHAR(3) DEFAULT 'GEN';
  DECLARE v_sig INT DEFAULT 1;
  SELECT UPPER(LEFT(nombre, 3)) INTO v_cat FROM categorias WHERE id_categoria = p_id_categoria;
  SELECT COALESCE(MAX(id_producto), 0) + 1 INTO v_sig FROM productos;
  RETURN CONCAT(v_cat, '-', UPPER(LEFT(REPLACE(TRIM(p_nombre), ' ', ''), 3)), '-', LPAD(v_sig, 4, '0'));
END$$

-- 16. fn_CalcularIVA: valor del impuesto sobre una base (tasa en %, p. ej. 19.00)
DROP FUNCTION IF EXISTS fn_CalcularIVA$$
CREATE FUNCTION fn_CalcularIVA(p_base DECIMAL(14,2), p_tasa DECIMAL(5,2)) RETURNS DECIMAL(14,2)
DETERMINISTIC
BEGIN
  RETURN ROUND(COALESCE(p_base, 0) * COALESCE(p_tasa, 0) / 100, 2);
END$$

-- 17. fn_ObtenerStockTotalPorCategoria: suma de stock de productos no eliminados de una categoría
DROP FUNCTION IF EXISTS fn_ObtenerStockTotalPorCategoria$$
CREATE FUNCTION fn_ObtenerStockTotalPorCategoria(p_id_categoria INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_stock INT DEFAULT 0;
  SELECT COALESCE(SUM(stock), 0) INTO v_stock
  FROM productos WHERE id_categoria = p_id_categoria AND eliminado = 0;
  RETURN v_stock;
END$$

-- 18. fn_EstimarFechaEntrega: fecha estimada sumando días hábiles (2 en Bucaramanga, 4 en otras ciudades)
DROP FUNCTION IF EXISTS fn_EstimarFechaEntrega$$
CREATE FUNCTION fn_EstimarFechaEntrega(p_fecha_venta DATETIME, p_ciudad VARCHAR(60)) RETURNS DATE
DETERMINISTIC
BEGIN
  DECLARE v_dias INT;
  DECLARE v_fecha DATE;
  SET v_dias = IF(p_ciudad = 'Bucaramanga', 2, 4);
  SET v_fecha = DATE(p_fecha_venta);
  WHILE v_dias > 0 DO
    SET v_fecha = DATE_ADD(v_fecha, INTERVAL 1 DAY);
    IF WEEKDAY(v_fecha) < 5 THEN SET v_dias = v_dias - 1; END IF;
  END WHILE;
  RETURN v_fecha;
END$$

-- 19. fn_ConvertirMoneda: conversión con tasas fijas de ejemplo (USD, EUR, COP, MXN); NULL si no se soporta
DROP FUNCTION IF EXISTS fn_ConvertirMoneda$$
CREATE FUNCTION fn_ConvertirMoneda(p_monto DECIMAL(16,2), p_origen CHAR(3), p_destino CHAR(3)) RETURNS DECIMAL(16,2)
DETERMINISTIC
BEGIN
  DECLARE v_o DECIMAL(14,8) DEFAULT NULL;
  DECLARE v_d DECIMAL(14,8) DEFAULT NULL;
  SET v_o = CASE UPPER(p_origen)  WHEN 'USD' THEN 1 WHEN 'EUR' THEN 1.08 WHEN 'COP' THEN 0.00025 WHEN 'MXN' THEN 0.055 END;
  SET v_d = CASE UPPER(p_destino) WHEN 'USD' THEN 1 WHEN 'EUR' THEN 1.08 WHEN 'COP' THEN 0.00025 WHEN 'MXN' THEN 0.055 END;
  IF v_o IS NULL OR v_d IS NULL OR p_monto IS NULL THEN RETURN NULL; END IF;
  RETURN ROUND(p_monto * v_o / v_d, 2);
END$$

-- 20. fn_ValidarComplejidadContraseña: 1 si tiene >= 8 caracteres, mayúscula, minúscula, número y símbolo
DROP FUNCTION IF EXISTS `fn_ValidarComplejidadContraseña`$$
CREATE FUNCTION `fn_ValidarComplejidadContraseña`(p_password VARCHAR(255)) RETURNS TINYINT(1)
DETERMINISTIC
BEGIN
  IF p_password IS NULL OR CHAR_LENGTH(p_password) < 8 THEN RETURN 0; END IF;
  RETURN IF(REGEXP_LIKE(p_password, '[A-Z]', 'c')
        AND REGEXP_LIKE(p_password, '[a-z]', 'c')
        AND REGEXP_LIKE(p_password, '[0-9]')
        AND REGEXP_LIKE(p_password, '[^A-Za-z0-9]'), 1, 0);
END$$

DELIMITER ;

-- Prueba rápida
SELECT fn_CalcularTotalVenta(1) AS total_venta_1, fn_ObtenerPrecioProducto(1) AS precio_p1,
       fn_DeterminarEstadoLealtad(1) AS lealtad_c1, fn_ValidarFormatoEmail('a@b.co') AS email_ok,
       `fn_ValidarComplejidadContraseña`('Abcdef1!') AS pwd_ok;
