-- =====================================================================
-- 08_Mantenimiento_Cuentas_Inactivas.sql  |  MySQL 8.x
-- Evento Programado - Mantenimiento de Cuentas Inactivas
--
-- OBJETIVO
--   Cumplir la política de retención de datos desactivando (SIN borrar)
--   las cuentas de clientes sin compras en los últimos 2 años.
--
-- ADAPTACIÓN AL ESQUEMA REAL (01_Esquema_y_Datos.sql)
--   * Tablas reales en minúsculas: `clientes` y `ventas`
--     (ventas ya trae id_cliente y fecha_venta, por eso el trigger va en
--      `ventas` y NO en `detalle_ventas`).
--   * `clientes.fecha_ultima_compra` YA EXISTE (DATETIME NULL): no se duplica.
--   * `clientes.activo` NO existe: se crea. Convive con `estado_cuenta`
--     (ENUM Activa/Suspendida/Anonimizada), que usan los procedimientos
--     almacenados; ambos se mantienen sincronizados.
--   * Convención del proyecto: "compra válida" = estado distinto de 'Cancelado'.
--
-- ORDEN DE EJECUCIÓN: después de 01, 03, 05, 06 y 07, y ANTES de 04_Seguridad.sql
-- (04 siempre va al final).
-- =====================================================================

-- 1. Selección de la base de datos
USE ecommerce_db;
SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- 2. Planificador de eventos
--    SET GLOBAL requiere privilegio administrativo (SYSTEM_VARIABLES_ADMIN
--    o SUPER). Sin él, MySQL responde con error de acceso denegado.
--    Nota: SET GLOBAL no sobrevive a un reinicio; para hacerlo permanente
--    añade  event_scheduler=ON  en la sección [mysqld] de my.cnf / my.ini.
-- ---------------------------------------------------------------------
SHOW VARIABLES LIKE 'event_scheduler';   -- estado actual
SET GLOBAL event_scheduler = ON;
SHOW VARIABLES LIKE 'event_scheduler';   -- debe mostrar ON

-- ---------------------------------------------------------------------
-- 3. ALTER TABLE seguro (idempotente)
--    MySQL no soporta "ADD COLUMN IF NOT EXISTS" (eso es MariaDB). Se
--    consulta information_schema y se ejecuta el ALTER solo si falta la
--    columna, con SQL dinámico (PREPARE/EXECUTE). Así el script puede
--    ejecutarse varias veces sin error "Duplicate column name".
-- ---------------------------------------------------------------------

-- 3.1 fecha_ultima_compra (ya existe en este proyecto; se deja por si se usa en otra BD)
SET @existe := (SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'clientes'
                  AND COLUMN_NAME = 'fecha_ultima_compra');
SET @sql := IF(@existe = 0,
  'ALTER TABLE clientes ADD COLUMN fecha_ultima_compra DATETIME NULL DEFAULT NULL',
  'SELECT ''fecha_ultima_compra ya existe: no se modifica'' AS aviso');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- 3.2 activo: BOOLEAN (= TINYINT(1)); DEFAULT TRUE => los clientes existentes quedan activos
SET @existe := (SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'clientes'
                  AND COLUMN_NAME = 'activo');
SET @sql := IF(@existe = 0,
  'ALTER TABLE clientes ADD COLUMN activo BOOLEAN NOT NULL DEFAULT TRUE AFTER estado_cuenta',
  'SELECT ''activo ya existe: no se modifica'' AS aviso');
PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- 3.3 Coherencia inicial con estado_cuenta (idempotente: solo toca filas incoherentes)
UPDATE clientes SET activo = FALSE
WHERE estado_cuenta <> 'Activa' AND activo = TRUE;

-- 3.4 Relleno inicial de fecha_ultima_compra para clientes que ya tenían ventas
--     (solo donde está en NULL; ignora ventas canceladas)
UPDATE clientes c
JOIN (SELECT id_cliente, MAX(fecha_venta) AS ultima
      FROM ventas WHERE estado <> 'Cancelado' GROUP BY id_cliente) v
  ON v.id_cliente = c.id_cliente
SET c.fecha_ultima_compra = v.ultima
WHERE c.fecha_ultima_compra IS NULL;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 4. TRIGGER
--    El trigger anterior update_last_order_date (05_Triggers.sql) hacía lo
--    mismo pero SIN comparar fechas (pisaba el valor siempre). Se elimina
--    para que no haya dos triggers duplicando la tarea.
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS update_last_order_date$$
DROP TRIGGER IF EXISTS trg_actualizar_fecha_ultima_compra$$

CREATE TRIGGER trg_actualizar_fecha_ultima_compra
AFTER INSERT ON ventas
FOR EACH ROW
BEGIN
  -- Las ventas canceladas no cuentan como compra
  IF NEW.estado <> 'Cancelado' THEN
    -- Solo actualiza si es la primera compra (NULL) o si la nueva es más reciente
    UPDATE clientes
       SET fecha_ultima_compra = NEW.fecha_venta
     WHERE id_cliente = NEW.id_cliente
       AND (fecha_ultima_compra IS NULL OR fecha_ultima_compra < NEW.fecha_venta);
  END IF;
END$$

-- ---------------------------------------------------------------------
-- 5. EVENTO MENSUAL
--    Frecuencia: una vez al mes, a las 03:00, empezando el día 1 del mes
--    siguiente. ON COMPLETION PRESERVE evita que el evento se borre solo.
--    Criterio: última compra (o, si nunca compró, fecha de registro)
--    anterior a CURDATE() - 2 años.
--    Nunca borra filas: solo UPDATE.
-- ---------------------------------------------------------------------
DROP EVENT IF EXISTS evt_desactivar_cuentas_inactivas$$

CREATE EVENT evt_desactivar_cuentas_inactivas
ON SCHEDULE EVERY 1 MONTH
  STARTS TIMESTAMP(LAST_DAY(CURDATE()) + INTERVAL 1 DAY, '03:00:00')
ON COMPLETION PRESERVE
ENABLE
COMMENT 'Desactiva cuentas sin compras en los ultimos 2 anios (no elimina datos)'
DO
BEGIN
  UPDATE clientes
     SET activo = FALSE,
         estado_cuenta = IF(estado_cuenta = 'Activa', 'Suspendida', estado_cuenta)
   WHERE activo = TRUE
     -- Clientes que nunca compraron (NULL) se miden desde su fecha de registro:
     -- los recién registrados quedan excluidos (periodo de gracia de 2 años).
     AND COALESCE(fecha_ultima_compra, fecha_registro) < DATE_SUB(CURDATE(), INTERVAL 2 YEAR);
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 6. VERIFICACIÓN DE OBJETOS
-- ---------------------------------------------------------------------
-- 6.1 Columnas creadas
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'clientes'
  AND COLUMN_NAME IN ('fecha_ultima_compra', 'activo');

-- 6.2 Trigger creado
SELECT TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_TIMING
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = 'trg_actualizar_fecha_ultima_compra';

-- 6.3 Evento creado (estado, frecuencia, primera ejecución, última ejecución)
SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD, STARTS, LAST_EXECUTED
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME = 'evt_desactivar_cuentas_inactivas';

-- 6.4 Planificador activo
SELECT @@global.event_scheduler AS event_scheduler;

-- ---------------------------------------------------------------------
-- 7. PRUEBA FUNCIONAL (dentro de una transacción: todo se revierte al final)
-- ---------------------------------------------------------------------
START TRANSACTION;

-- Cliente de prueba registrado hace 3 años
INSERT INTO clientes (nombre, apellido, email, `contraseña`, fecha_registro)
VALUES ('Prueba', 'Inactivo', 'prueba.inactivo@mail.com', SHA2('Test#2025', 256), DATE_SUB(NOW(), INTERVAL 3 YEAR));
SET @id := LAST_INSERT_ID();
SET @suc := (SELECT MIN(id_sucursal) FROM sucursales);

-- A) Primera compra (hace 30 meses): fecha_ultima_compra pasa de NULL a esa fecha
INSERT INTO ventas (fecha_venta, id_cliente, id_sucursal)
VALUES (DATE_SUB(NOW(), INTERVAL 30 MONTH), @id, @suc);
SELECT 'A) tras 1a compra' AS paso, fecha_ultima_compra, activo FROM clientes WHERE id_cliente = @id;

-- B) Compra MÁS ANTIGUA (hace 40 meses): NO debe cambiar la fecha
INSERT INTO ventas (fecha_venta, id_cliente, id_sucursal)
VALUES (DATE_SUB(NOW(), INTERVAL 40 MONTH), @id, @suc);
SELECT 'B) compra antigua (sin cambio)' AS paso, fecha_ultima_compra, activo FROM clientes WHERE id_cliente = @id;

-- C) Misma lógica que el cuerpo del evento, limitada al cliente de prueba
UPDATE clientes
   SET activo = FALSE,
       estado_cuenta = IF(estado_cuenta = 'Activa', 'Suspendida', estado_cuenta)
 WHERE activo = TRUE
   AND id_cliente = @id
   AND COALESCE(fecha_ultima_compra, fecha_registro) < DATE_SUB(CURDATE(), INTERVAL 2 YEAR);
SELECT 'C) tras evento (debe ser activo=0)' AS paso, fecha_ultima_compra, activo, estado_cuenta
FROM clientes WHERE id_cliente = @id;

ROLLBACK;   -- no deja datos de prueba

-- Resumen real de la base
SELECT activo, estado_cuenta, COUNT(*) AS clientes FROM clientes GROUP BY activo, estado_cuenta;
