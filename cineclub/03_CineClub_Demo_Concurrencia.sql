/* =====================================================================
   PROYECTO FINAL - BASES DE DATOS (GLUD)
   Sistema de Alquiler de Películas "CineClub Vintage"
   Script 3 (apoyo a la sustentación): TRANSACCIONES CONCURRENTES,
   NIVELES DE AISLAMIENTO Y BLOQUEOS
   Motor: PostgreSQL 14+

   INSTRUCCIONES
   Abra TRES terminales psql conectadas a la misma base:
       psql -d cineclub_vintage        (Sesión A)
       psql -d cineclub_vintage        (Sesión B)
       psql -d cineclub_vintage        (Sesión C = monitor de bloqueos)
   Copie y ejecute cada bloque en la sesión indicada y EN EL ORDEN de los
   pasos (A1, B1, C1, A2...). No ejecute este archivo completo con \i.

   Antes de empezar, re-ejecute 01_CineClub_DDL_DML.sql para partir de
   datos limpios. Copias usadas: 26 (Titanic Blu-ray), 21 (Toy Story DVD),
   18 (Cantando bajo la lluvia 4K), todas en estado 'Disponible'.
   ===================================================================== */


/* =====================================================================
   ESCENARIO 1 - Dos empleados intentan alquilar LA MISMA copia
   Nivel: READ COMMITTED (el predeterminado de PostgreSQL)
   Qué se demuestra: bloqueo de fila (row-level lock) + re-evaluación
   del WHERE en READ COMMITTED -> imposible el doble préstamo.
   ===================================================================== */

-- [A1] Sesión A: el empleado 1 atiende a Laura (cliente 1)
BEGIN;
INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite)
VALUES (1, 1, CURRENT_DATE + 3);
INSERT INTO detalle_alquiler (id_alquiler, id_copia)
VALUES (currval(pg_get_serial_sequence('alquiler','id_alquiler')), 26);
-- El trigger ejecutó: UPDATE copia SET estado='Alquilada' WHERE id_copia=26 AND estado='Disponible'
-- => la fila de la copia 26 queda con bloqueo exclusivo (FOR UPDATE) hasta COMMIT/ROLLBACK.
-- (NO haga COMMIT todavía)

-- [B1] Sesión B: al mismo tiempo, el empleado 2 atiende a Andrés (cliente 2)
BEGIN;
INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite)
VALUES (2, 2, CURRENT_DATE + 3);
SELECT estado FROM copia WHERE id_copia = 26;   -- B aún ve 'Disponible' (A no ha confirmado)
INSERT INTO detalle_alquiler (id_alquiler, id_copia)
VALUES (currval(pg_get_serial_sequence('alquiler','id_alquiler')), 26);
-- >>> La sesión B QUEDA EN ESPERA: necesita bloquear la misma fila que tiene A.

-- [C1] Sesión C: observar quién espera a quién
SELECT pid,
       state,
       wait_event_type,
       wait_event,
       pg_blocking_pids(pid) AS bloqueado_por,
       LEFT(query, 70)       AS consulta
  FROM pg_stat_activity
 WHERE datname = current_database()
   AND pid <> pg_backend_pid()
 ORDER BY pid;

SELECT l.pid, l.locktype, l.relation::regclass AS tabla, l.mode, l.granted
  FROM pg_locks l
 WHERE l.relation IN ('copia'::regclass, 'detalle_alquiler'::regclass, 'alquiler'::regclass)
    OR l.locktype = 'transactionid'
 ORDER BY l.pid, l.granted DESC;
-- Se verá: B con wait_event = 'transactionid' y bloqueado_por = {pid de A};
-- en pg_locks, B tiene un ShareLock sobre el transactionid de A con granted = false.

-- [A2] Sesión A: confirma su alquiler
COMMIT;

-- [B2] Resultado inmediato en la Sesión B:
--   ERROR:  Copia NO disponible: la copia 26 (código CCV-0012-BLU, "Titanic")
--           está en estado 'Alquilada'. Se cancela la transacción.
-- Explicación: al liberarse el bloqueo, READ COMMITTED vuelve a evaluar
-- "WHERE estado = 'Disponible'" sobre la versión ya confirmada de la fila,
-- no la encuentra, y el trigger lanza la excepción. La transacción B queda
-- abortada; se debe cerrar con:
ROLLBACK;

-- (Variante: si en [A2] se hace ROLLBACK en vez de COMMIT, B continúa y
--  su alquiler de la copia 26 se registra con éxito.)


/* =====================================================================
   ESCENARIO 2 - REPEATABLE READ: instantánea + error de serialización
   Qué se demuestra: en REPEATABLE READ cada transacción ve una "foto"
   fija de los datos (MVCC). Si intenta modificar una fila que otro
   confirmó después de tomar su foto, PostgreSQL aborta con SQLSTATE 40001.
   ===================================================================== */

-- [B3] Sesión B: abre una transacción con instantánea fija
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT titulo, formato, copias_disponibles
  FROM V_CatalogoDisponible WHERE titulo = 'Toy Story';   -- ve DVD y Blu-ray disponibles

-- [A3] Sesión A (autocommit): otro empleado alquila la copia 21 (Toy Story DVD)
INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (3, 3, CURRENT_DATE + 2);
INSERT INTO detalle_alquiler (id_alquiler, id_copia)
VALUES (currval(pg_get_serial_sequence('alquiler','id_alquiler')), 21);

-- [B4] Sesión B: su instantánea NO cambió (lectura repetible, sin "lecturas no repetibles")
SELECT titulo, formato, copias_disponibles
  FROM V_CatalogoDisponible WHERE titulo = 'Toy Story';   -- ¡sigue viendo el DVD disponible!

INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (4, 4, CURRENT_DATE + 2);
INSERT INTO detalle_alquiler (id_alquiler, id_copia)
VALUES (currval(pg_get_serial_sequence('alquiler','id_alquiler')), 21);
--   ERROR:  could not serialize access due to concurrent update   (SQLSTATE 40001)
-- La aplicación debe capturar el 40001 y REINTENTAR la transacción completa.
ROLLBACK;


/* =====================================================================
   ESCENARIO 3 - Interbloqueo (deadlock) y su detección automática
   Qué se demuestra: dos transacciones toman bloqueos en orden inverso.
   PostgreSQL detecta el ciclo (deadlock_timeout = 1 s) y aborta una.
   ===================================================================== */

-- [A4] Sesión A
BEGIN;
UPDATE cliente SET telefono = '3100000001' WHERE id_cliente = 5;   -- bloquea cliente 5

-- [B5] Sesión B
BEGIN;
UPDATE copia SET estado = 'Dañada' WHERE id_copia = 18;            -- bloquea copia 18

-- [A5] Sesión A
UPDATE copia SET estado = 'Dañada' WHERE id_copia = 18;            -- espera a B

-- [B6] Sesión B
UPDATE cliente SET telefono = '3100000002' WHERE id_cliente = 5;   -- espera a A => ciclo
--   ERROR:  deadlock detected
--   DETAIL: Process X waits for ShareLock on transaction ...; blocked by process Y. ...
-- Una de las dos sesiones es abortada; la otra continúa.

-- [A6] / [B7] Cerrar ambas sin cambios
ROLLBACK;
-- Buena práctica: acceder siempre a las tablas en el mismo orden
-- (p. ej. cliente -> alquiler -> detalle -> copia) evita interbloqueos.


/* =====================================================================
   ESCENARIO 4 (opcional) - SELECT ... FOR UPDATE NOWAIT
   Para no dejar al empleado esperando: falla de inmediato si la copia
   está siendo alquilada en otra caja.
   ===================================================================== */
-- [A7] Sesión A
BEGIN;
SELECT * FROM copia WHERE id_copia = 22 FOR UPDATE;

-- [B8] Sesión B
SELECT * FROM copia WHERE id_copia = 22 FOR UPDATE NOWAIT;
--   ERROR:  could not obtain lock on row in relation "copia"   (SQLSTATE 55P03)

-- [A8] Sesión A
ROLLBACK;
