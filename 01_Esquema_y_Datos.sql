-- =====================================================================
-- 01_Esquema_y_Datos.sql  |  MySQL 8.0.19+
-- DDL completo + datos de prueba estandarizados
-- =====================================================================
DROP DATABASE IF EXISTS ecommerce_db;
CREATE DATABASE ecommerce_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE ecommerce_db;
SET NAMES utf8mb4;

-- ============================ DDL ====================================

-- Sucursales (aislamiento de ventas por sucursal)
CREATE TABLE sucursales (
  id_sucursal INT AUTO_INCREMENT PRIMARY KEY,
  nombre      VARCHAR(100) NOT NULL UNIQUE,
  ciudad      VARCHAR(60)  NOT NULL
) ENGINE=InnoDB;

-- Categorías (total_productos lo mantiene el trigger update_producto_count)
CREATE TABLE categorias (
  id_categoria    INT AUTO_INCREMENT PRIMARY KEY,
  nombre          VARCHAR(100) NOT NULL UNIQUE,
  descripcion     TEXT,
  total_productos INT NOT NULL DEFAULT 0
) ENGINE=InnoDB;

-- Proveedores
CREATE TABLE proveedores (
  id_proveedor      INT AUTO_INCREMENT PRIMARY KEY,
  nombre            VARCHAR(150) NOT NULL,
  email_contacto    VARCHAR(150) UNIQUE,
  telefono_contacto VARCHAR(30)
) ENGINE=InnoDB;

-- Productos
CREATE TABLE productos (
  id_producto        INT AUTO_INCREMENT PRIMARY KEY,
  nombre             VARCHAR(150)  NOT NULL UNIQUE,
  descripcion        TEXT,
  precio             DECIMAL(12,2) NOT NULL,
  costo              DECIMAL(12,2) NOT NULL,
  stock              INT           NOT NULL DEFAULT 0,
  stock_minimo       INT           NOT NULL DEFAULT 5,
  sku                VARCHAR(30)   NOT NULL UNIQUE,
  peso_kg            DECIMAL(8,2)  NOT NULL DEFAULT 1.00,   -- simulado para envíos
  fecha_creacion     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_modificacion DATETIME      NULL,
  activo             TINYINT(1)    NOT NULL DEFAULT 1,
  eliminado          TINYINT(1)    NOT NULL DEFAULT 0,      -- borrado lógico
  fecha_eliminacion  DATETIME      NULL,
  id_categoria       INT NULL,                              -- el trigger assign_default_category rellena NULL
  id_proveedor       INT NOT NULL,
  CONSTRAINT chk_prod_precio CHECK (precio > 0),
  CONSTRAINT chk_prod_costo  CHECK (costo >= 0),
  CONSTRAINT chk_prod_stock  CHECK (stock >= 0),
  CONSTRAINT fk_prod_cat  FOREIGN KEY (id_categoria) REFERENCES categorias(id_categoria) ON DELETE RESTRICT,
  CONSTRAINT fk_prod_prov FOREIGN KEY (id_proveedor) REFERENCES proveedores(id_proveedor) ON DELETE RESTRICT,
  INDEX idx_prod_cat (id_categoria),
  INDEX idx_prod_prov (id_proveedor)
) ENGINE=InnoDB;

-- Clientes
CREATE TABLE clientes (
  id_cliente          INT AUTO_INCREMENT PRIMARY KEY,
  nombre              VARCHAR(80)  NOT NULL,
  apellido            VARCHAR(80)  NOT NULL,
  email               VARCHAR(150) NOT NULL UNIQUE,
  `contraseña`        VARCHAR(255) NOT NULL,                -- hash
  direccion_envio     VARCHAR(255),
  ciudad              VARCHAR(60),                          -- simulado (análisis geográfico)
  fecha_nacimiento    DATE NULL,                            -- simulado (edad / cumpleaños)
  fecha_registro      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  total_gastado       DECIMAL(14,2) NOT NULL DEFAULT 0,
  fecha_ultima_compra DATETIME NULL,
  nivel_lealtad       VARCHAR(20) NOT NULL DEFAULT 'Bronce',
  estado_cuenta       ENUM('Activa','Suspendida','Anonimizada') NOT NULL DEFAULT 'Activa',
  id_referido         INT NULL,
  CONSTRAINT fk_cli_ref FOREIGN KEY (id_referido) REFERENCES clientes(id_cliente) ON DELETE SET NULL,
  INDEX idx_cli_ciudad (ciudad)
) ENGINE=InnoDB;

-- Ventas
CREATE TABLE ventas (
  id_venta      INT AUTO_INCREMENT PRIMARY KEY,
  fecha_venta   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado        ENUM('Pendiente de Pago','Procesando','Enviado','Entregado','Cancelado') NOT NULL DEFAULT 'Pendiente de Pago',
  total         DECIMAL(14,2) NOT NULL DEFAULT 0,
  id_cliente    INT NOT NULL,
  id_sucursal   INT NOT NULL,
  fecha_envio   DATETIME NULL,
  fecha_entrega DATETIME NULL,
  CONSTRAINT fk_ven_cli FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente),
  CONSTRAINT fk_ven_suc FOREIGN KEY (id_sucursal) REFERENCES sucursales(id_sucursal),
  INDEX idx_ven_fecha (fecha_venta),
  INDEX idx_ven_estado (estado),
  INDEX idx_ven_cli (id_cliente),
  INDEX idx_ven_suc (id_sucursal)
) ENGINE=InnoDB;

-- Detalle de ventas (tabla puente N:M ventas-productos)
CREATE TABLE detalle_ventas (
  id_detalle                INT AUTO_INCREMENT PRIMARY KEY,
  id_venta                  INT NOT NULL,
  id_producto               INT NOT NULL,
  cantidad                  INT NOT NULL,
  precio_unitario_congelado DECIMAL(12,2) NOT NULL,
  CONSTRAINT chk_det_cant CHECK (cantidad > 0),
  CONSTRAINT fk_det_ven  FOREIGN KEY (id_venta)    REFERENCES ventas(id_venta) ON DELETE CASCADE,
  CONSTRAINT fk_det_prod FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE RESTRICT,
  INDEX idx_det_ven (id_venta),
  INDEX idx_det_prod (id_producto)
) ENGINE=InnoDB;

-- Carritos (simulación de carrito abandonado)
CREATE TABLE carritos (
  id_carrito          INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente          INT NOT NULL,
  fecha_creacion      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  fecha_actualizacion DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  estado              ENUM('Activo','Abandonado','Convertido') NOT NULL DEFAULT 'Activo',
  CONSTRAINT fk_car_cli FOREIGN KEY (id_cliente) REFERENCES clientes(id_cliente) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE carrito_items (
  id_carrito  INT NOT NULL,
  id_producto INT NOT NULL,
  cantidad    INT NOT NULL DEFAULT 1,
  PRIMARY KEY (id_carrito, id_producto),
  CONSTRAINT chk_ci_cant CHECK (cantidad > 0),
  CONSTRAINT fk_ci_car  FOREIGN KEY (id_carrito)  REFERENCES carritos(id_carrito) ON DELETE CASCADE,
  CONSTRAINT fk_ci_prod FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Vistas de producto (simulación de tráfico)
CREATE TABLE vistas_producto (
  id_vista    BIGINT AUTO_INCREMENT PRIMARY KEY,
  id_producto INT NOT NULL,
  id_cliente  INT NULL,
  fecha_vista DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_vp_prod FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE,
  CONSTRAINT fk_vp_cli  FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente) ON DELETE SET NULL,
  INDEX idx_vp_prod (id_producto)
) ENGINE=InnoDB;

-- Promociones (simulación con fechas)
CREATE TABLE promociones (
  id_promocion         INT AUTO_INCREMENT PRIMARY KEY,
  nombre               VARCHAR(100) NOT NULL,
  id_categoria         INT NOT NULL,
  porcentaje_descuento DECIMAL(5,2) NOT NULL,
  fecha_inicio         DATE NOT NULL,
  fecha_fin            DATE NOT NULL,
  activa               TINYINT(1) NOT NULL DEFAULT 1,
  CONSTRAINT chk_promo_pct   CHECK (porcentaje_descuento BETWEEN 0 AND 100),
  CONSTRAINT chk_promo_fecha CHECK (fecha_fin >= fecha_inicio),
  CONSTRAINT fk_promo_cat FOREIGN KEY (id_categoria) REFERENCES categorias(id_categoria) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Reseñas de producto
CREATE TABLE resenas (
  id_resena        INT AUTO_INCREMENT PRIMARY KEY,
  id_producto      INT NOT NULL,
  id_cliente       INT NOT NULL,
  calificacion     TINYINT NOT NULL,
  comentario       TEXT,
  compra_verificada TINYINT(1) NOT NULL DEFAULT 0,
  fecha            DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_res_cal CHECK (calificacion BETWEEN 1 AND 5),
  CONSTRAINT fk_res_prod FOREIGN KEY (id_producto) REFERENCES productos(id_producto) ON DELETE CASCADE,
  CONSTRAINT fk_res_cli  FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Devoluciones
CREATE TABLE devoluciones (
  id_devolucion INT AUTO_INCREMENT PRIMARY KEY,
  id_venta      INT NOT NULL,
  id_producto   INT NOT NULL,
  cantidad      INT NOT NULL,
  motivo        VARCHAR(255),
  monto         DECIMAL(12,2) NOT NULL,
  fecha         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_dev_cant CHECK (cantidad > 0),
  CONSTRAINT fk_dev_ven  FOREIGN KEY (id_venta)    REFERENCES ventas(id_venta),
  CONSTRAINT fk_dev_prod FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
) ENGINE=InnoDB;

-- Pagos
CREATE TABLE pagos (
  id_pago  INT AUTO_INCREMENT PRIMARY KEY,
  id_venta INT NOT NULL,
  monto    DECIMAL(14,2) NOT NULL,
  metodo   ENUM('Tarjeta','PSE','Transferencia','Efectivo') NOT NULL,
  estado   ENUM('Aprobado','Rechazado') NOT NULL,
  fecha    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_pag_ven FOREIGN KEY (id_venta) REFERENCES ventas(id_venta)
) ENGINE=InnoDB;

-- ============================ DML ====================================

INSERT INTO sucursales (nombre, ciudad) VALUES
('Sucursal Bucaramanga Centro','Bucaramanga'),
('Sucursal Bogotá Norte','Bogotá'),
('Sucursal Medellín Poblado','Medellín');

INSERT INTO categorias (nombre, descripcion) VALUES
('Electrónica','Computadores, teléfonos y accesorios'),
('Hogar','Artículos de cocina y hogar'),
('Deportes','Equipamiento deportivo'),
('Libros','Libros físicos y literatura'),
('Ropa','Prendas de vestir'),
('Sin Categoría','Categoría por defecto para productos sin clasificar');

INSERT INTO proveedores (nombre, email_contacto, telefono_contacto) VALUES
('TechDistribuciones SAS','ventas@techdist.com','+57 601 555 0101'),
('HogarPlus Ltda','contacto@hogarplus.com','+57 604 555 0202'),
('DeporMax','pedidos@depormax.com','+57 602 555 0303'),
('Editorial Andina','comercial@editorialandina.com','+57 607 555 0404'),
('Textiles del Norte','info@textilesnorte.com','+57 605 555 0505');

INSERT INTO productos (nombre, descripcion, precio, costo, stock, stock_minimo, sku, peso_kg, id_categoria, id_proveedor) VALUES
('Laptop Pro 15','Portátil 15 pulgadas 16GB RAM',1200.00,900.00,25,5,'ELE-LAP-0001',2.10,1,1),
('Smartphone X10','Teléfono 128GB',800.00,550.00,40,10,'ELE-SMA-0002',0.20,1,1),
('Auriculares Bluetooth','Auriculares inalámbricos',60.00,30.00,100,20,'ELE-AUR-0003',0.30,1,1),
('Licuadora 1000W','Licuadora de alta potencia',75.00,40.00,30,8,'HOG-LIC-0004',3.00,2,2),
('Juego de Sartenes','Set 3 sartenes antiadherentes',90.00,50.00,20,5,'HOG-JUE-0005',4.50,2,2),
('Balón de Fútbol','Balón profesional No. 5',25.00,12.00,60,15,'DEP-BAL-0006',0.45,3,3),
('Bicicleta MTB','Bicicleta de montaña rin 29',450.00,300.00,2,3,'DEP-BIC-0007',14.00,3,3),
('Novela El Viaje','Novela de aventuras',18.00,7.00,80,20,'LIB-NOV-0008',0.50,4,4),
('Camiseta Deportiva','Camiseta transpirable',22.00,9.00,4,10,'ROP-CAM-0009',0.25,5,5),
('Chaqueta Impermeable','Chaqueta ligera impermeable',85.00,45.00,15,5,'ROP-CHA-0010',0.90,5,5);

INSERT INTO clientes (nombre, apellido, email, `contraseña`, direccion_envio, ciudad, fecha_nacimiento, fecha_registro, id_referido) VALUES
('Laura','Gómez','laura.gomez@mail.com',SHA2('Cliente#2025',256),'Cra 27 #45-10','Bucaramanga','1990-05-14',DATE_SUB(NOW(),INTERVAL 420 DAY),NULL),
('Carlos','Pérez','carlos.perez@mail.com',SHA2('Cliente#2025',256),'Calle 100 #15-20','Bogotá','1985-11-02',DATE_SUB(NOW(),INTERVAL 380 DAY),1),
('María','Rodríguez','maria.rodriguez@mail.com',SHA2('Cliente#2025',256),'Cra 43A #7-50','Medellín','1993-03-27',DATE_SUB(NOW(),INTERVAL 310 DAY),NULL),
('Andrés','Martínez','andres.martinez@mail.com',SHA2('Cliente#2025',256),'Av 6N #23-15','Cali','1988-09-30',DATE_SUB(NOW(),INTERVAL 250 DAY),NULL),
('Sofía','Herrera','sofia.herrera@mail.com',SHA2('Cliente#2025',256),'Calle 84 #50-12','Barranquilla','1996-01-19',DATE_SUB(NOW(),INTERVAL 200 DAY),3),
('Juan','Castro','juan.castro@mail.com',SHA2('Cliente#2025',256),'Cra 15 #93-40','Bogotá','1979-07-08',DATE_SUB(NOW(),INTERVAL 100 DAY),NULL),
('Valentina','Ríos','valentina.rios@mail.com',SHA2('Cliente#2025',256),'Calle 36 #28-05','Bucaramanga','2000-12-25',DATE_SUB(NOW(),INTERVAL 60 DAY),NULL),
('Diego','Torres','diego.torres@mail.com',SHA2('Cliente#2025',256),'Cra 35 #10-22','Medellín','1995-06-06',DATE_SUB(NOW(),INTERVAL 10 DAY),NULL);

INSERT INTO ventas (fecha_venta, estado, id_cliente, id_sucursal) VALUES
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 400 DAY),'10:15:00'),'Entregado',1,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 370 DAY),'14:30:00'),'Entregado',2,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 300 DAY),'20:05:00'),'Entregado',1,2),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 280 DAY),'09:45:00'),'Entregado',3,2),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 200 DAY),'21:10:00'),'Entregado',4,3),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 150 DAY),'13:00:00'),'Entregado',2,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 120 DAY),'19:30:00'),'Entregado',5,3),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 90 DAY),'11:20:00'),'Entregado',1,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 60 DAY),'15:45:00'),'Entregado',6,2),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 45 DAY),'20:50:00'),'Entregado',3,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 20 DAY),'12:10:00'),'Enviado',1,2),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 10 DAY),'16:25:00'),'Procesando',7,3),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 5 DAY),'22:15:00'),'Pendiente de Pago',2,1),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 30 DAY),'10:40:00'),'Cancelado',5,2),
(TIMESTAMP(DATE_SUB(CURDATE(),INTERVAL 3 DAY),'20:20:00'),'Entregado',4,3);

-- Detalle: el precio congelado toma el precio actual del producto
INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado)
SELECT t.v, t.p, t.q, pr.precio
FROM (VALUES
  ROW(1,1,1), ROW(1,3,2),
  ROW(2,2,1), ROW(2,3,1),
  ROW(3,4,1), ROW(3,5,1),
  ROW(4,6,3), ROW(4,8,2),
  ROW(5,7,1), ROW(5,6,2),
  ROW(6,3,2), ROW(6,2,1),
  ROW(7,9,2), ROW(7,10,1),
  ROW(8,1,1), ROW(8,3,1),
  ROW(9,8,3), ROW(9,4,1),
  ROW(10,10,1), ROW(10,9,1), ROW(10,6,1),
  ROW(11,2,1), ROW(11,3,1),
  ROW(12,5,1), ROW(12,4,1),
  ROW(13,8,2),
  ROW(14,7,1),
  ROW(15,3,1), ROW(15,8,1), ROW(15,6,2)
) AS t(v,p,q)
JOIN productos pr ON pr.id_producto = t.p;

-- Totales, fechas de envío/entrega y métricas derivadas
UPDATE ventas v SET v.total = (SELECT SUM(d.cantidad*d.precio_unitario_congelado) FROM detalle_ventas d WHERE d.id_venta = v.id_venta);
UPDATE ventas SET fecha_envio = fecha_venta + INTERVAL 1 DAY WHERE estado IN ('Enviado','Entregado');
UPDATE ventas SET fecha_entrega = fecha_venta + INTERVAL 4 DAY WHERE estado = 'Entregado';

UPDATE clientes c SET
  c.total_gastado = COALESCE((SELECT SUM(v.total) FROM ventas v WHERE v.id_cliente = c.id_cliente AND v.estado = 'Entregado'),0),
  c.fecha_ultima_compra = (SELECT MAX(v.fecha_venta) FROM ventas v WHERE v.id_cliente = c.id_cliente AND v.estado <> 'Cancelado');

UPDATE categorias c SET c.total_productos = (SELECT COUNT(*) FROM productos p WHERE p.id_categoria = c.id_categoria);

-- Pagos de las ventas ya pagadas
INSERT INTO pagos (id_venta, monto, metodo, estado, fecha)
SELECT id_venta, total, 'Tarjeta', 'Aprobado', fecha_venta + INTERVAL 5 MINUTE
FROM ventas WHERE estado IN ('Procesando','Enviado','Entregado');

-- Carritos (uno reciente, dos abandonados, uno convertido)
INSERT INTO carritos (id_cliente, fecha_creacion, fecha_actualizacion, estado) VALUES
(8,DATE_SUB(NOW(),INTERVAL 3 DAY),DATE_SUB(NOW(),INTERVAL 3 DAY),'Activo'),
(6,DATE_SUB(NOW(),INTERVAL 3 HOUR),DATE_SUB(NOW(),INTERVAL 2 HOUR),'Activo'),
(4,DATE_SUB(NOW(),INTERVAL 6 DAY),DATE_SUB(NOW(),INTERVAL 5 DAY),'Activo'),
(7,DATE_SUB(NOW(),INTERVAL 11 DAY),DATE_SUB(NOW(),INTERVAL 10 DAY),'Convertido');
INSERT INTO carrito_items (id_carrito, id_producto, cantidad) VALUES
(1,1,1),(1,3,1),(2,2,1),(3,7,1),(3,9,2),(4,5,1);

-- Vistas de producto simuladas
INSERT INTO vistas_producto (id_producto, id_cliente, fecha_vista)
SELECT t.p, t.c, DATE_SUB(NOW(), INTERVAL t.d DAY)
FROM (VALUES
  ROW(1,1,30),ROW(1,2,28),ROW(1,NULL,25),ROW(1,3,20),ROW(1,6,15),ROW(1,NULL,7),
  ROW(2,2,40),ROW(2,NULL,35),ROW(2,5,22),ROW(2,1,12),ROW(2,NULL,3),
  ROW(3,1,50),ROW(3,4,30),ROW(3,NULL,10),ROW(3,8,2),
  ROW(4,3,40),ROW(4,NULL,9),ROW(5,7,20),
  ROW(6,4,60),ROW(6,NULL,14),ROW(6,5,6),
  ROW(7,4,90),ROW(7,NULL,60),ROW(7,6,33),ROW(7,NULL,11),
  ROW(8,6,5),ROW(8,NULL,4),
  ROW(9,3,45),ROW(9,NULL,44),ROW(9,2,20),ROW(9,NULL,8),
  ROW(10,5,18),ROW(10,NULL,1)
) AS t(p,c,d);

-- Promociones (una vencida pero aún marcada activa, para probar el evento)
INSERT INTO promociones (nombre, id_categoria, porcentaje_descuento, fecha_inicio, fecha_fin, activa) VALUES
('Cyber Electro',1,15.00,DATE_SUB(CURDATE(),INTERVAL 100 DAY),DATE_SUB(CURDATE(),INTERVAL 80 DAY),1),
('Temporada Deportes',3,10.00,DATE_SUB(CURDATE(),INTERVAL 210 DAY),DATE_SUB(CURDATE(),INTERVAL 190 DAY),0),
('Moda Fin de Mes',5,20.00,DATE_SUB(CURDATE(),INTERVAL 10 DAY),DATE_ADD(CURDATE(),INTERVAL 20 DAY),1);

INSERT INTO resenas (id_producto, id_cliente, calificacion, comentario, compra_verificada) VALUES
(1,1,5,'Excelente rendimiento',1),
(3,2,4,'Buen sonido, batería mejorable',1),
(6,3,5,'Muy buena calidad',1),
(8,3,4,'Historia entretenida',1),
(7,4,3,'Llegó con detalles de empaque',1),
(10,5,5,'Perfecta para la lluvia',1);

INSERT INTO devoluciones (id_venta, id_producto, cantidad, motivo, monto) VALUES
(4,8,1,'Producto dañado en el envío',18.00);

-- Verificación rápida
SELECT 'categorias' tabla, COUNT(*) filas FROM categorias UNION ALL
SELECT 'proveedores', COUNT(*) FROM proveedores UNION ALL
SELECT 'productos', COUNT(*) FROM productos UNION ALL
SELECT 'clientes', COUNT(*) FROM clientes UNION ALL
SELECT 'ventas', COUNT(*) FROM ventas UNION ALL
SELECT 'detalle_ventas', COUNT(*) FROM detalle_ventas;
