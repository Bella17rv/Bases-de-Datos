/* =====================================================================
   PROYECTO FINAL - BASES DE DATOS (GLUD)
   Sistema de Alquiler de Películas "CineClub Vintage"
   Script 2 de 3: VALIDACIÓN DE TRIGGERS Y RESTRICCIONES
   Motor: PostgreSQL 14+

   Requisito: haber ejecutado 01_CineClub_DDL_DML.sql en la misma base.

   Cómo funciona:
     * Todo corre dentro de UNA transacción que termina en ROLLBACK, así
       los datos de prueba quedan intactos y el script se puede repetir.
     * Cada caso es un bloque DO que intenta la operación. Si el motor la
       rechaza, el bloque captura la excepción (SQLERRM) y la registra.
     * Al final se muestra una tabla con: caso, resultado esperado,
       resultado obtenido, PASA/FALLA y el mensaje del trigger.

   Estado inicial relevante (creado por el script 1):
     Cliente 1  Laura      -> Activa, sin pendientes
     Cliente 8  Sebastián  -> alquiler 10 vencido 7 días (copias 3 y 17)
     Cliente 9  Mariana    -> alquiler 11 vencido exactamente 3 días
     Cliente 11 Juliana    -> Suspendida (por mora reincidente)
     Cliente 12 Felipe     -> Suspendida
     Copia 1  Casablanca DVD   -> Disponible
     Copia 3  Casablanca 4K    -> Alquilada (alquiler 10)
     Copia 25 Titanic DVD      -> Dañada
     Alquiler 13 (copia 6)     -> vigente, vence en 2 días
   ===================================================================== */

\set ON_ERROR_STOP on
\pset null '(nulo)'

BEGIN;

-- Tabla temporal de resultados y función auxiliar de registro
CREATE TEMP TABLE resultados (
    n         SERIAL,
    caso      TEXT,
    prueba    TEXT,
    esperado  TEXT,
    obtenido  TEXT,
    mensaje   TEXT
) ON COMMIT DROP;

CREATE FUNCTION pg_temp.registrar(p_caso TEXT, p_prueba TEXT, p_esperado TEXT,
                                  p_obtenido TEXT, p_mensaje TEXT)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO resultados (caso, prueba, esperado, obtenido, mensaje)
    VALUES (p_caso, p_prueba, p_esperado, p_obtenido, p_mensaje);
    RAISE NOTICE '[%] % -> esperado %, obtenido %. %', p_caso, p_prueba, p_esperado, p_obtenido, p_mensaje;
END;
$$;


/* =====================================================================
   A. TR_ValidarClienteHabilitado (BEFORE INSERT en ALQUILER)
   ===================================================================== */

-- A1. ÉXITO: cliente activo y sin préstamos vencidos
DO $$
DECLARE v_id INT; v_estado TEXT;
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite)
    VALUES (1, 1, CURRENT_DATE + 3) RETURNING id_alquiler, estado INTO v_id, v_estado;
    PERFORM pg_temp.registrar('A1','Cliente 1 activo sin mora abre alquiler','ACEPTADO','ACEPTADO',
            format('Alquiler %s creado en estado %s', v_id, v_estado));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('A1','Cliente 1 activo sin mora abre alquiler','ACEPTADO','RECHAZADO', SQLERRM);
END $$;

-- A2. RECHAZO: membresía suspendida (cliente 12)
DO $$
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (12, 2, CURRENT_DATE + 3);
    PERFORM pg_temp.registrar('A2','Cliente 12 con membresía Suspendida','RECHAZADO','ACEPTADO','El trigger NO bloqueó');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('A2','Cliente 12 con membresía Suspendida','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- A3. RECHAZO: cliente suspendido por reincidencia (cliente 11)
DO $$
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (11, 3, CURRENT_DATE + 2);
    PERFORM pg_temp.registrar('A3','Cliente 11 suspendido tras mora de 10 días','RECHAZADO','ACEPTADO','El trigger NO bloqueó');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('A3','Cliente 11 suspendido tras mora de 10 días','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- A4. RECHAZO: cliente activo pero con copias vencidas hace 7 días (> 3)
DO $$
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (8, 4, CURRENT_DATE + 2);
    PERFORM pg_temp.registrar('A4','Cliente 8 con préstamo vencido 7 días','RECHAZADO','ACEPTADO','El trigger NO bloqueó');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('A4','Cliente 8 con préstamo vencido 7 días','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- A5. CASO LÍMITE: exactamente 3 días de atraso todavía se permite (la regla es "más de 3")
DO $$
DECLARE v_id INT;
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite)
    VALUES (9, 5, CURRENT_DATE + 2) RETURNING id_alquiler INTO v_id;
    PERFORM pg_temp.registrar('A5','Cliente 9 con exactamente 3 días de atraso','ACEPTADO','ACEPTADO',
            format('Alquiler %s creado (3 días no supera el límite)', v_id));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('A5','Cliente 9 con exactamente 3 días de atraso','ACEPTADO','RECHAZADO', SQLERRM);
END $$;


/* =====================================================================
   B. TR_ActualizarEstadoCopiaAlquiler (AFTER INSERT en DETALLE_ALQUILER)
   ===================================================================== */

-- B1. ÉXITO: copia 1 Disponible -> pasa a 'Alquilada' y se calcula el precio
DO $$
DECLARE v_alq INT; v_estado TEXT; v_precio NUMERIC; v_total NUMERIC;
BEGIN
    SELECT MAX(id_alquiler) INTO v_alq FROM alquiler WHERE id_cliente = 1 AND estado = 'Abierto';
    INSERT INTO detalle_alquiler (id_alquiler, id_copia) VALUES (v_alq, 1)
    RETURNING precio_alquiler INTO v_precio;
    SELECT estado INTO v_estado FROM copia WHERE id_copia = 1;
    SELECT total_alquiler INTO v_total FROM alquiler WHERE id_alquiler = v_alq;
    PERFORM pg_temp.registrar('B1','Alquilar copia 1 (Disponible)','ACEPTADO',
            CASE WHEN v_estado = 'Alquilada' THEN 'ACEPTADO' ELSE 'ESTADO INCORRECTO' END,
            format('Copia 1 ahora = %s; precio = %s (3 días x 3500); total alquiler = %s', v_estado, v_precio, v_total));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('B1','Alquilar copia 1 (Disponible)','ACEPTADO','RECHAZADO', SQLERRM);
END $$;

-- B2. RECHAZO: la copia 1 ya quedó alquilada en B1 (doble préstamo)
DO $$
DECLARE v_alq INT;
BEGIN
    SELECT MAX(id_alquiler) INTO v_alq FROM alquiler WHERE id_cliente = 9 AND estado = 'Abierto';
    INSERT INTO detalle_alquiler (id_alquiler, id_copia) VALUES (v_alq, 1);
    PERFORM pg_temp.registrar('B2','Alquilar de nuevo la copia 1 (ya Alquilada)','RECHAZADO','ACEPTADO','Doble préstamo NO bloqueado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('B2','Alquilar de nuevo la copia 1 (ya Alquilada)','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- B3. RECHAZO: copia en estado 'Dañada'
DO $$
DECLARE v_alq INT;
BEGIN
    SELECT MAX(id_alquiler) INTO v_alq FROM alquiler WHERE id_cliente = 9 AND estado = 'Abierto';
    INSERT INTO detalle_alquiler (id_alquiler, id_copia) VALUES (v_alq, 25);
    PERFORM pg_temp.registrar('B3','Alquilar copia 25 (Dañada)','RECHAZADO','ACEPTADO','Copia dañada NO bloqueada');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('B3','Alquilar copia 25 (Dañada)','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- B4. ATOMICIDAD: INSERT de 2 copias donde una NO está disponible.
--     Toda la sentencia se revierte: la copia 26 (válida) sigue 'Disponible'.
DO $$
DECLARE v_alq INT; v_estado26 TEXT;
BEGIN
    SELECT MAX(id_alquiler) INTO v_alq FROM alquiler WHERE id_cliente = 9 AND estado = 'Abierto';
    BEGIN
        INSERT INTO detalle_alquiler (id_alquiler, id_copia) VALUES (v_alq, 26), (v_alq, 3);
        PERFORM pg_temp.registrar('B4','Lote {26 disponible, 3 alquilada}','RECHAZADO','ACEPTADO','El lote NO se revirtió');
    EXCEPTION WHEN OTHERS THEN
        SELECT estado INTO v_estado26 FROM copia WHERE id_copia = 26;
        PERFORM pg_temp.registrar('B4','Lote {26 disponible, 3 alquilada}','RECHAZADO',
                CASE WHEN v_estado26 = 'Disponible' THEN 'RECHAZADO' ELSE 'REVERSIÓN PARCIAL' END,
                format('Copia 26 sigue %s. %s', v_estado26, SQLERRM));
    END;
END $$;

-- B5. RECHAZO (trigger auxiliar): agregar copias a un alquiler ya CERRADO
DO $$
BEGIN
    INSERT INTO detalle_alquiler (id_alquiler, id_copia) VALUES (1, 26);
    PERFORM pg_temp.registrar('B5','Agregar copia al alquiler 1 (Cerrado)','RECHAZADO','ACEPTADO','NO bloqueado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('B5','Agregar copia al alquiler 1 (Cerrado)','RECHAZADO','RECHAZADO', SQLERRM);
END $$;


/* =====================================================================
   C. TR_CalcularMoraYDisponibilidad (BEFORE UPDATE en DETALLE_ALQUILER)
   ===================================================================== */

-- C1. ÉXITO - devolución ANTICIPADA: 0 días de mora, copia vuelve a Disponible,
--     el alquiler 13 se cierra automáticamente.
DO $$
DECLARE r RECORD; v_copia TEXT; v_alq TEXT;
BEGIN
    UPDATE detalle_alquiler SET fecha_devolucion_real = CURRENT_DATE
     WHERE id_alquiler = 13 AND id_copia = 6
    RETURNING dias_retraso, recargo_mora INTO r;
    SELECT estado INTO v_copia FROM copia    WHERE id_copia = 6;
    SELECT estado INTO v_alq   FROM alquiler WHERE id_alquiler = 13;
    PERFORM pg_temp.registrar('C1','Devolución anticipada (alquiler 13)','0 días / Disponible',
            format('%s días / %s', r.dias_retraso, v_copia),
            format('Recargo = %s; alquiler 13 = %s', r.recargo_mora, v_alq));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C1','Devolución anticipada (alquiler 13)','0 días / Disponible','ERROR', SQLERRM);
END $$;

-- C2. ÉXITO - devolución TARDÍA del alquiler 10 (vencido hace 7 días)
--     Casablanca 4K : 7 x 3500 x 1.5 = 36 750
--     Cantando ... : 7 x 3000 x 1.5 = 31 500   -> total recargos 68 250
DO $$
DECLARE v_dias INT; v_rec NUMERIC; v_tot NUMERIC; v_estado TEXT; v_disp INT;
BEGIN
    UPDATE detalle_alquiler SET fecha_devolucion_real = CURRENT_DATE WHERE id_alquiler = 10;
    SELECT MAX(dias_retraso), SUM(recargo_mora) INTO v_dias, v_rec FROM detalle_alquiler WHERE id_alquiler = 10;
    SELECT total_recargos, estado INTO v_tot, v_estado FROM alquiler WHERE id_alquiler = 10;
    SELECT COUNT(*) INTO v_disp FROM copia WHERE id_copia IN (3,17) AND estado = 'Disponible';
    PERFORM pg_temp.registrar('C2','Devolución tardía (alquiler 10, 7 días)','7 días / 68250.00',
            format('%s días / %s', v_dias, v_rec),
            format('Alquiler 10 = %s, total_recargos = %s, copias disponibles = %s de 2', v_estado, v_tot, v_disp));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C2','Devolución tardía (alquiler 10, 7 días)','7 días / 68250.00','ERROR', SQLERRM);
END $$;

-- C3. INTEGRACIÓN: tras devolver (C2), el cliente 8 ya puede alquilar (TR_ValidarClienteHabilitado)
DO $$
DECLARE v_id INT;
BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite)
    VALUES (8, 6, CURRENT_DATE + 2) RETURNING id_alquiler INTO v_id;
    PERFORM pg_temp.registrar('C3','Cliente 8 alquila tras ponerse al día','ACEPTADO','ACEPTADO',
            format('Alquiler %s creado', v_id));
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C3','Cliente 8 alquila tras ponerse al día','ACEPTADO','RECHAZADO', SQLERRM);
END $$;

-- C4. INTEGRIDAD: intentar "perdonar" la mora a mano. El trigger recalcula.
DO $$
DECLARE v_rec NUMERIC;
BEGIN
    UPDATE detalle_alquiler SET recargo_mora = 0, dias_retraso = 0
     WHERE id_alquiler = 10 AND id_copia = 3
    RETURNING recargo_mora INTO v_rec;
    PERFORM pg_temp.registrar('C4','Poner recargo_mora = 0 manualmente','Recalcula 36750.00',
            format('recargo = %s', v_rec),
            'El trigger sobrescribe el valor manipulado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C4','Poner recargo_mora = 0 manualmente','Recalcula 36750.00','ERROR', SQLERRM);
END $$;

-- C5. RECHAZO: fecha de devolución anterior a la fecha de préstamo
DO $$
BEGIN
    UPDATE detalle_alquiler SET fecha_devolucion_real = CURRENT_DATE - 30
     WHERE id_alquiler = 12 AND id_copia = 23;
    PERFORM pg_temp.registrar('C5','Devolución con fecha anterior al préstamo','RECHAZADO','ACEPTADO','NO bloqueado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C5','Devolución con fecha anterior al préstamo','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- C6. RECHAZO: fecha de devolución futura
DO $$
BEGIN
    UPDATE detalle_alquiler SET fecha_devolucion_real = CURRENT_DATE + 5
     WHERE id_alquiler = 12 AND id_copia = 23;
    PERFORM pg_temp.registrar('C6','Devolución con fecha futura','RECHAZADO','ACEPTADO','NO bloqueado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C6','Devolución con fecha futura','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

-- C7. RECHAZO: anular una devolución ya registrada (volver a NULL)
DO $$
BEGIN
    UPDATE detalle_alquiler SET fecha_devolucion_real = NULL WHERE id_alquiler = 1 AND id_copia = 1;
    PERFORM pg_temp.registrar('C7','Anular devolución registrada','RECHAZADO','ACEPTADO','NO bloqueado');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('C7','Anular devolución registrada','RECHAZADO','RECHAZADO', SQLERRM);
END $$;


/* =====================================================================
   D. RESTRICCIONES DECLARATIVAS (NOT NULL, UNIQUE, CHECK, FK)
   ===================================================================== */

DO $$ BEGIN
    INSERT INTO copia (id_pelicula, codigo_barras, formato) VALUES (1, 'CCV-0001-DVD', 'DVD');
    PERFORM pg_temp.registrar('D1','UNIQUE codigo_barras duplicado','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D1','UNIQUE codigo_barras duplicado','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    INSERT INTO copia (id_pelicula, codigo_barras, formato) VALUES (1, 'CCV-0001-VHS', 'VHS');
    PERFORM pg_temp.registrar('D2','CHECK formato = VHS','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D2','CHECK formato = VHS','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    INSERT INTO cliente (documento_identidad, nombres, apellidos, telefono, email)
    VALUES ('999', 'Prueba', 'Correo', '3000000000', 'correo-invalido');
    PERFORM pg_temp.registrar('D3','CHECK formato de email','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D3','CHECK formato de email','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_prestamo, fecha_limite)
    VALUES (1, 1, CURRENT_DATE, CURRENT_DATE - 1);
    PERFORM pg_temp.registrar('D4','CHECK fecha_limite > fecha_prestamo','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D4','CHECK fecha_limite > fecha_prestamo','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    INSERT INTO alquiler (id_cliente, id_empleado, fecha_limite) VALUES (1, 999, CURRENT_DATE + 1);
    PERFORM pg_temp.registrar('D5','FK empleado inexistente (999)','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D5','FK empleado inexistente (999)','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    INSERT INTO pelicula (titulo, clasificacion_edad, genero, anio_estreno, tarifa_base_dia)
    VALUES ('Película gratis', 'PG', 'Drama', 2000, 0);
    PERFORM pg_temp.registrar('D6','CHECK tarifa_base_dia > 0','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D6','CHECK tarifa_base_dia > 0','RECHAZADO','RECHAZADO', SQLERRM);
END $$;

DO $$ BEGIN
    DELETE FROM pelicula WHERE id_pelicula = 1;
    PERFORM pg_temp.registrar('D7','DELETE película con copias (RESTRICT)','RECHAZADO','ACEPTADO','');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.registrar('D7','DELETE película con copias (RESTRICT)','RECHAZADO','RECHAZADO', SQLERRM);
END $$;


/* =====================================================================
   E. RESUMEN
   ===================================================================== */
\echo
\echo '================  RESUMEN DE VALIDACIÓN  ================'
SELECT n, caso, prueba, esperado, obtenido,
       CASE WHEN esperado = obtenido
              OR (esperado = 'Recalcula 36750.00' AND obtenido = 'recargo = 36750.00')
            THEN 'PASA' ELSE 'FALLA' END AS veredicto,
       LEFT(mensaje, 160) AS mensaje
  FROM resultados ORDER BY n;

SELECT COUNT(*) FILTER (WHERE esperado = obtenido
                          OR (esperado = 'Recalcula 36750.00' AND obtenido = 'recargo = 36750.00')) AS pasan,
       COUNT(*) AS total
  FROM resultados;

-- Efecto de las pruebas sobre las vistas (antes del ROLLBACK)
\echo '--- V_AlquileresEnMora tras las devoluciones de prueba (el alquiler 10 ya no aparece) ---'
SELECT id_alquiler, cliente, titulo, dias_mora, cliente_bloqueado FROM V_AlquileresEnMora;

ROLLBACK;   -- deja la base exactamente como la dejó el script 1

\echo 'ROLLBACK aplicado: los datos de prueba originales quedan intactos.'
