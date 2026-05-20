-- Migración: eventos — vista y funciones (BD existente)
-- psql -U postgres -d parchapp -f sql/migrations/001_events_and_booking_functions.sql

CREATE INDEX IF NOT EXISTS idx_services_event ON services (establishment_id) WHERE service_kind = 'event' AND is_active;

ALTER TABLE services DROP CONSTRAINT IF EXISTS chk_services_event_duration;
ALTER TABLE services ADD CONSTRAINT chk_services_event_duration
  CHECK (service_kind <> 'event' OR (duration_minutes IS NOT NULL AND duration_minutes > 0));

CREATE OR REPLACE VIEW v_establishment_events AS
SELECT
  s.id AS service_id,
  s.establishment_id,
  s.title,
  s.description,
  s.duration_minutes,
  s.max_party_size,
  s.is_active,
  s.created_at AS service_created_at,
  e.trade_name AS establishment_trade_name,
  e.status AS establishment_status,
  anchor.booking_id AS anchor_booking_id,
  anchor.scheduled_start,
  anchor.scheduled_end,
  COALESCE(caps.booked_party_size, 0)::integer AS booked_party_size,
  GREATEST(
    0,
    COALESCE(s.max_party_size, 50) - COALESCE(caps.booked_party_size, 0)
  )::integer AS spots_available
FROM services s
JOIN establishments e ON e.id = s.establishment_id
LEFT JOIN LATERAL (
  SELECT b.id AS booking_id, b.scheduled_start, b.scheduled_end
  FROM bookings b
  WHERE b.service_id = s.id
  ORDER BY b.created_at ASC
  LIMIT 1
) anchor ON true
LEFT JOIN LATERAL (
  SELECT COALESCE(SUM(b.party_size), 0) AS booked_party_size
  FROM bookings b
  WHERE b.service_id = s.id
    AND b.status IN ('pending', 'confirmed')
) caps ON true
WHERE s.service_kind = 'event';

CREATE OR REPLACE FUNCTION fn_create_establishment_event(
  p_establishment_id bigint,
  p_actor_user_id bigint,
  p_title varchar(200),
  p_description text,
  p_scheduled_start timestamptz,
  p_duration_minutes integer,
  p_party_size integer,
  p_max_party_size integer,
  p_notes text
)
RETURNS TABLE (out_service_id bigint, out_booking_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner bigint;
  v_est_status establishment_status;
  v_service_id bigint;
  v_booking_id bigint;
  v_scheduled_end timestamptz;
  v_max_party integer;
BEGIN
  IF p_duration_minutes IS NULL OR p_duration_minutes <= 0 THEN
    RAISE EXCEPTION 'duration_minutes debe ser mayor que 0';
  END IF;

  IF p_party_size IS NULL OR p_party_size <= 0 THEN
    RAISE EXCEPTION 'party_size debe ser mayor que 0';
  END IF;

  SELECT owner_user_id, status
  INTO v_owner, v_est_status
  FROM establishments
  WHERE id = p_establishment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Establecimiento % no existe', p_establishment_id;
  END IF;

  IF v_owner IS DISTINCT FROM p_actor_user_id THEN
    RAISE EXCEPTION 'Usuario % no autorizado para crear eventos en el establecimiento %',
      p_actor_user_id, p_establishment_id;
  END IF;

  IF v_est_status <> 'active' THEN
    RAISE EXCEPTION 'El establecimiento % no está activo', p_establishment_id;
  END IF;

  v_max_party := COALESCE(p_max_party_size, 50);
  IF v_max_party < p_party_size THEN
    RAISE EXCEPTION 'max_party_size no puede ser menor que party_size';
  END IF;

  v_scheduled_end := p_scheduled_start + make_interval(mins => p_duration_minutes);

  INSERT INTO services (
    establishment_id, title, description, service_kind,
    duration_minutes, max_party_size, is_bookable, is_active
  ) VALUES (
    p_establishment_id,
    p_title,
    p_description,
    'event',
    p_duration_minutes,
    v_max_party,
    true,
    true
  )
  RETURNING id INTO v_service_id;

  INSERT INTO bookings (
    user_id, service_id, party_size,
    scheduled_start, scheduled_end, status, notes
  ) VALUES (
    p_actor_user_id,
    v_service_id,
    p_party_size,
    p_scheduled_start,
    v_scheduled_end,
    'pending',
    p_notes
  )
  RETURNING id INTO v_booking_id;

  out_service_id := v_service_id;
  out_booking_id := v_booking_id;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION fn_create_booking_for_event(
  p_service_id bigint,
  p_user_id bigint,
  p_party_size integer,
  p_notes text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_service services%ROWTYPE;
  v_est_status establishment_status;
  v_anchor_start timestamptz;
  v_anchor_end timestamptz;
  v_booked integer;
  v_max_party integer;
  v_booking_id bigint;
BEGIN
  IF p_party_size IS NULL OR p_party_size <= 0 THEN
    RAISE EXCEPTION 'party_size debe ser mayor que 0';
  END IF;

  SELECT s.*
  INTO v_service
  FROM services s
  WHERE s.id = p_service_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Servicio/evento % no existe', p_service_id;
  END IF;

  SELECT e.status
  INTO v_est_status
  FROM establishments e
  WHERE e.id = v_service.establishment_id;

  IF v_service.service_kind <> 'event' THEN
    RAISE EXCEPTION 'El servicio % no es un evento', p_service_id;
  END IF;

  IF NOT v_service.is_active OR NOT v_service.is_bookable THEN
    RAISE EXCEPTION 'El evento % no está disponible para reservas', p_service_id;
  END IF;

  IF v_est_status <> 'active' THEN
    RAISE EXCEPTION 'El establecimiento del evento no está activo';
  END IF;

  SELECT b.scheduled_start, b.scheduled_end
  INTO v_anchor_start, v_anchor_end
  FROM bookings b
  WHERE b.service_id = p_service_id
  ORDER BY b.created_at ASC
  LIMIT 1;

  IF v_anchor_start IS NULL THEN
    RAISE EXCEPTION 'El evento % no tiene ventana horaria definida', p_service_id;
  END IF;

  v_max_party := COALESCE(v_service.max_party_size, 50);

  SELECT COALESCE(SUM(b.party_size), 0)::integer
  INTO v_booked
  FROM bookings b
  WHERE b.service_id = p_service_id
    AND b.status IN ('pending', 'confirmed');

  IF v_booked + p_party_size > v_max_party THEN
    RAISE EXCEPTION 'Cupo insuficiente: disponibles %, solicitados %',
      GREATEST(0, v_max_party - v_booked), p_party_size;
  END IF;

  INSERT INTO bookings (
    user_id, service_id, party_size,
    scheduled_start, scheduled_end, status, notes
  ) VALUES (
    p_user_id,
    p_service_id,
    p_party_size,
    v_anchor_start,
    v_anchor_end,
    'pending',
    p_notes
  )
  RETURNING id INTO v_booking_id;

  RETURN v_booking_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_create_establishment_event(
  bigint, bigint, varchar, text, timestamptz, integer, integer, integer, text
) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_create_booking_for_event(bigint, bigint, integer, text) TO parchapp_app;
GRANT SELECT ON v_establishment_events TO parchapp_readonly;
GRANT SELECT ON v_establishment_events TO parchapp_app;
