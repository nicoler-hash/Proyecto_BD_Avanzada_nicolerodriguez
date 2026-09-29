-- =====================================================================
-- 02_Consultas_Avanzadas.sql  |  20 consultas analíticas (MySQL 8.0+)
-- Convención: "venta válida" = estado distinto de 'Cancelado'.
-- =====================================================================
USE ecommerce_db;

-- 1. Top 10 Productos Más Vendidos (unidades e ingresos)
SELECT p.id_producto, p.nombre,
       SUM(d.cantidad) AS unidades_vendidas,
       SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
FROM detalle_ventas d
JOIN ventas v    ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
JOIN productos p ON p.id_producto = d.id_producto
GROUP BY p.id_producto, p.nombre
ORDER BY unidades_vendidas DESC, ingresos DESC
LIMIT 10;

-- 2. Productos con Bajas Ventas (10% inferior por unidades vendidas)
WITH ventas_prod AS (
  SELECT p.id_producto, p.nombre,
         COALESCE(SUM(CASE WHEN v.estado <> 'Cancelado' THEN d.cantidad END), 0) AS unidades
  FROM productos p
  LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
  LEFT JOIN ventas v         ON v.id_venta = d.id_venta
  GROUP BY p.id_producto, p.nombre
), ranking AS (
  SELECT id_producto, nombre, unidades, NTILE(10) OVER (ORDER BY unidades ASC) AS decil
  FROM ventas_prod
)
SELECT id_producto, nombre, unidades FROM ranking WHERE decil = 1 ORDER BY unidades;

-- 3. Clientes VIP (Top 5 por valor de vida del cliente - LTV)
SELECT c.id_cliente, CONCAT(c.nombre, ' ', c.apellido) AS cliente,
       COUNT(v.id_venta) AS num_compras, SUM(v.total) AS ltv,
       ROUND(AVG(v.total), 2) AS ticket_promedio
FROM clientes c
JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado IN ('Procesando','Enviado','Entregado')
GROUP BY c.id_cliente, c.nombre, c.apellido
ORDER BY ltv DESC
LIMIT 5;

-- 4. Ventas Mensuales con variación porcentual mes a mes
WITH mensual AS (
  SELECT DATE_FORMAT(fecha_venta, '%Y-%m') AS mes, COUNT(*) AS num_ventas, SUM(total) AS total_ventas
  FROM ventas WHERE estado <> 'Cancelado'
  GROUP BY DATE_FORMAT(fecha_venta, '%Y-%m')
)
SELECT mes, num_ventas, total_ventas,
       ROUND((total_ventas - LAG(total_ventas) OVER (ORDER BY mes)) / NULLIF(LAG(total_ventas) OVER (ORDER BY mes), 0) * 100, 2) AS variacion_pct
FROM mensual ORDER BY mes;

-- 5. Crecimiento de Clientes por Trimestre (nuevos, acumulado y crecimiento)
SELECT anio, trimestre, nuevos,
       SUM(nuevos) OVER (ORDER BY anio, trimestre) AS acumulado,
       ROUND((nuevos - LAG(nuevos) OVER (ORDER BY anio, trimestre)) / NULLIF(LAG(nuevos) OVER (ORDER BY anio, trimestre), 0) * 100, 2) AS crecimiento_pct
FROM (
  SELECT YEAR(fecha_registro) AS anio, QUARTER(fecha_registro) AS trimestre, COUNT(*) AS nuevos
  FROM clientes GROUP BY YEAR(fecha_registro), QUARTER(fecha_registro)
) t
ORDER BY anio, trimestre;

-- 6. Tasa de Compra Repetida (clientes con más de una compra)
SELECT COUNT(*) AS clientes_compradores,
       SUM(n_compras > 1) AS clientes_recurrentes,
       ROUND(SUM(n_compras > 1) / COUNT(*) * 100, 2) AS tasa_compra_repetida_pct
FROM (
  SELECT id_cliente, COUNT(*) AS n_compras
  FROM ventas WHERE estado <> 'Cancelado' GROUP BY id_cliente
) t;

-- 7. Productos Comprados Juntos (análisis de canasta, pares de productos)
SELECT p1.nombre AS producto_a, p2.nombre AS producto_b, COUNT(*) AS veces_juntos
FROM detalle_ventas d1
JOIN detalle_ventas d2 ON d1.id_venta = d2.id_venta AND d1.id_producto < d2.id_producto
JOIN ventas v ON v.id_venta = d1.id_venta AND v.estado <> 'Cancelado'
JOIN productos p1 ON p1.id_producto = d1.id_producto
JOIN productos p2 ON p2.id_producto = d2.id_producto
GROUP BY p1.nombre, p2.nombre
ORDER BY veces_juntos DESC, producto_a
LIMIT 15;

-- 8. Rotación de Inventario (últimos 365 días: unidades vendidas / stock actual)
SELECT p.id_producto, p.nombre, p.stock,
       COALESCE(u.unidades, 0) AS unidades_vendidas_12m,
       ROUND(COALESCE(u.unidades, 0) / NULLIF(p.stock, 0), 2) AS indice_rotacion,
       ROUND(365 / NULLIF(COALESCE(u.unidades, 0) / NULLIF(p.stock, 0), 0), 1) AS dias_de_inventario
FROM productos p
LEFT JOIN (
  SELECT d.id_producto, SUM(d.cantidad) AS unidades
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= NOW() - INTERVAL 365 DAY
  GROUP BY d.id_producto
) u ON u.id_producto = p.id_producto
ORDER BY indice_rotacion DESC;

-- 9. Productos a Reabastecer (stock igual o inferior al mínimo) con sugerencia de compra
SELECT p.id_producto, p.nombre, p.stock, p.stock_minimo,
       (p.stock_minimo * 3 - p.stock) AS cantidad_sugerida,
       pr.nombre AS proveedor, pr.email_contacto
FROM productos p
JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
WHERE p.stock <= p.stock_minimo AND p.activo = 1 AND p.eliminado = 0
ORDER BY (p.stock_minimo - p.stock) DESC;

-- 10. Carritos Abandonados (simulado: activos sin actividad hace más de 24 horas)
SELECT c.id_carrito, CONCAT(cl.nombre, ' ', cl.apellido) AS cliente, cl.email,
       COUNT(ci.id_producto) AS items, SUM(ci.cantidad * p.precio) AS valor_carrito,
       TIMESTAMPDIFF(HOUR, c.fecha_actualizacion, NOW()) AS horas_inactivo
FROM carritos c
JOIN clientes cl      ON cl.id_cliente = c.id_cliente
JOIN carrito_items ci ON ci.id_carrito = c.id_carrito
JOIN productos p      ON p.id_producto = ci.id_producto
WHERE c.estado = 'Activo' AND c.fecha_actualizacion < NOW() - INTERVAL 24 HOUR
GROUP BY c.id_carrito, cl.nombre, cl.apellido, cl.email, c.fecha_actualizacion
ORDER BY valor_carrito DESC;

-- 11. Rendimiento de Proveedores (productos, unidades, ingresos y margen)
SELECT pr.id_proveedor, pr.nombre,
       COUNT(DISTINCT p.id_producto) AS productos,
       COALESCE(SUM(CASE WHEN v.estado <> 'Cancelado' THEN d.cantidad END), 0) AS unidades_vendidas,
       COALESCE(SUM(CASE WHEN v.estado <> 'Cancelado' THEN d.cantidad * d.precio_unitario_congelado END), 0) AS ingresos,
       COALESCE(SUM(CASE WHEN v.estado <> 'Cancelado' THEN d.cantidad * (d.precio_unitario_congelado - p.costo) END), 0) AS margen_bruto
FROM proveedores pr
LEFT JOIN productos p      ON p.id_proveedor = pr.id_proveedor
LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
LEFT JOIN ventas v         ON v.id_venta = d.id_venta
GROUP BY pr.id_proveedor, pr.nombre
ORDER BY ingresos DESC;

-- 12. Análisis Geográfico (clientes, ventas e ingresos por ciudad; campo simulado ciudad)
SELECT COALESCE(c.ciudad, 'Sin ciudad') AS ciudad,
       COUNT(DISTINCT c.id_cliente) AS clientes,
       COUNT(v.id_venta) AS ventas,
       COALESCE(SUM(v.total), 0) AS ingresos,
       ROUND(COALESCE(AVG(v.total), 0), 2) AS ticket_promedio
FROM clientes c
LEFT JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado <> 'Cancelado'
GROUP BY COALESCE(c.ciudad, 'Sin ciudad')
ORDER BY ingresos DESC;

-- 13. Ventas por Hora del Día
SELECT HOUR(fecha_venta) AS hora, COUNT(*) AS num_ventas, SUM(total) AS total_ventas
FROM ventas WHERE estado <> 'Cancelado'
GROUP BY HOUR(fecha_venta)
ORDER BY hora;

-- 14. Impacto de Promociones (ventas de la categoría durante la promoción vs. periodo previo de igual duración)
SELECT x.nombre, x.porcentaje_descuento, x.ventas_durante, x.ventas_previas,
       ROUND((x.ventas_durante - x.ventas_previas) / NULLIF(x.ventas_previas, 0) * 100, 2) AS variacion_pct
FROM (
  SELECT pr.id_promocion, pr.nombre, pr.porcentaje_descuento,
    (SELECT COALESCE(SUM(d.cantidad * d.precio_unitario_congelado), 0)
       FROM detalle_ventas d
       JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
       JOIN productos p ON p.id_producto = d.id_producto
      WHERE p.id_categoria = pr.id_categoria
        AND DATE(v.fecha_venta) BETWEEN pr.fecha_inicio AND pr.fecha_fin) AS ventas_durante,
    (SELECT COALESCE(SUM(d.cantidad * d.precio_unitario_congelado), 0)
       FROM detalle_ventas d
       JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
       JOIN productos p ON p.id_producto = d.id_producto
      WHERE p.id_categoria = pr.id_categoria
        AND DATE(v.fecha_venta) BETWEEN DATE_SUB(pr.fecha_inicio, INTERVAL DATEDIFF(pr.fecha_fin, pr.fecha_inicio) + 1 DAY)
                                    AND DATE_SUB(pr.fecha_inicio, INTERVAL 1 DAY)) AS ventas_previas
  FROM promociones pr
) x
ORDER BY x.id_promocion;

-- 15. Análisis Cohort (retención mensual por mes de primera compra)
WITH primera AS (
  SELECT id_cliente,
         DATE_SUB(DATE(MIN(fecha_venta)), INTERVAL DAYOFMONTH(MIN(fecha_venta)) - 1 DAY) AS cohorte
  FROM ventas WHERE estado <> 'Cancelado' GROUP BY id_cliente
), actividad AS (
  SELECT DISTINCT v.id_cliente, p.cohorte, TIMESTAMPDIFF(MONTH, p.cohorte, v.fecha_venta) AS mes_n
  FROM ventas v JOIN primera p ON p.id_cliente = v.id_cliente
  WHERE v.estado <> 'Cancelado'
), tamano AS (
  SELECT cohorte, COUNT(*) AS clientes_cohorte FROM primera GROUP BY cohorte
)
SELECT DATE_FORMAT(a.cohorte, '%Y-%m') AS cohorte, t.clientes_cohorte, a.mes_n,
       COUNT(DISTINCT a.id_cliente) AS clientes_activos,
       ROUND(COUNT(DISTINCT a.id_cliente) / t.clientes_cohorte * 100, 2) AS retencion_pct
FROM actividad a JOIN tamano t ON t.cohorte = a.cohorte
GROUP BY a.cohorte, t.clientes_cohorte, a.mes_n
ORDER BY a.cohorte, a.mes_n;

-- 16. Margen de Beneficio por Producto (teórico y realizado)
SELECT p.id_producto, p.nombre, p.precio, p.costo,
       ROUND(p.precio - p.costo, 2) AS margen_unitario,
       ROUND((p.precio - p.costo) / p.precio * 100, 2) AS margen_pct,
       COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * (d.precio_unitario_congelado - p.costo) END), 0) AS margen_realizado
FROM productos p
LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
LEFT JOIN ventas v         ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
GROUP BY p.id_producto, p.nombre, p.precio, p.costo
ORDER BY margen_pct DESC;

-- 17. Tiempo Medio Entre Compras (por cliente y global mediante ROLLUP)
WITH compras AS (
  SELECT id_cliente, fecha_venta,
         LAG(fecha_venta) OVER (PARTITION BY id_cliente ORDER BY fecha_venta) AS compra_previa
  FROM ventas WHERE estado <> 'Cancelado'
)
SELECT id_cliente, ROUND(AVG(DATEDIFF(fecha_venta, compra_previa)), 1) AS dias_promedio_entre_compras,
       COUNT(*) AS intervalos
FROM compras
WHERE compra_previa IS NOT NULL
GROUP BY id_cliente WITH ROLLUP;

-- 18. Productos Más Vistos vs Comprados (conversión; vistas simuladas)
SELECT p.id_producto, p.nombre,
       COALESCE(vw.vistas, 0) AS vistas,
       COALESCE(cp.unidades, 0) AS unidades_compradas,
       ROUND(COALESCE(cp.unidades, 0) / NULLIF(vw.vistas, 0) * 100, 2) AS conversion_pct
FROM productos p
LEFT JOIN (SELECT id_producto, COUNT(*) AS vistas FROM vistas_producto GROUP BY id_producto) vw ON vw.id_producto = p.id_producto
LEFT JOIN (
  SELECT d.id_producto, SUM(d.cantidad) AS unidades
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  GROUP BY d.id_producto
) cp ON cp.id_producto = p.id_producto
ORDER BY vistas DESC;

-- 19. Segmentación RFM (Recencia, Frecuencia, Valor Monetario con quintiles)
WITH base AS (
  SELECT c.id_cliente, CONCAT(c.nombre, ' ', c.apellido) AS cliente,
         DATEDIFF(CURDATE(), MAX(v.fecha_venta)) AS recencia_dias,
         COUNT(*) AS frecuencia, SUM(v.total) AS monetario
  FROM clientes c
  JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado IN ('Procesando','Enviado','Entregado')
  GROUP BY c.id_cliente, c.nombre, c.apellido
), puntajes AS (
  SELECT base.*,
         NTILE(5) OVER (ORDER BY recencia_dias DESC) AS r,
         NTILE(5) OVER (ORDER BY frecuencia ASC)     AS f,
         NTILE(5) OVER (ORDER BY monetario ASC)      AS m
  FROM base
)
SELECT id_cliente, cliente, recencia_dias, frecuencia, monetario,
       CONCAT(r, f, m) AS rfm,
       CASE WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Campeones'
            WHEN r >= 3 AND f >= 3 THEN 'Leales'
            WHEN r >= 4 THEN 'Recientes'
            WHEN r <= 2 AND f >= 3 THEN 'En riesgo'
            WHEN r <= 2 THEN 'Dormidos'
            ELSE 'Regulares' END AS segmento
FROM puntajes
ORDER BY r DESC, f DESC, m DESC;

-- 20. Predicción Simple de Demanda (promedio móvil de 3 meses por producto; meses sin ventas no se rellenan)
WITH mensual AS (
  SELECT d.id_producto, DATE_FORMAT(v.fecha_venta, '%Y-%m-01') AS mes, SUM(d.cantidad) AS unidades
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  GROUP BY d.id_producto, DATE_FORMAT(v.fecha_venta, '%Y-%m-01')
), movil AS (
  SELECT id_producto, mes, unidades,
         ROUND(AVG(unidades) OVER (PARTITION BY id_producto ORDER BY mes ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2) AS media_movil_3m,
         ROW_NUMBER() OVER (PARTITION BY id_producto ORDER BY mes DESC) AS rn
  FROM mensual
)
SELECT p.id_producto, p.nombre, m.mes AS ultimo_mes_con_ventas, m.unidades AS unidades_ultimo_mes,
       m.media_movil_3m AS pronostico_proximo_mes
FROM movil m JOIN productos p ON p.id_producto = m.id_producto
WHERE m.rn = 1
ORDER BY pronostico_proximo_mes DESC;
