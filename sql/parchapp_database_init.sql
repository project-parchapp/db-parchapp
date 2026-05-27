-- =============================================================================
-- ParchApp — inicialización PostgreSQL (tablas, vistas, funciones, roles)
-- Basado en lineamientos: rutas, establecimientos, reservas, promociones,
-- reseñas/favoritos, compartir ruta, chat turista–establecimiento.
--
-- Prerrequisito (ejecutar como superusuario, fuera de este script si aplica):
--   CREATE DATABASE parchapp
--     WITH ENCODING 'UTF8'
--     LC_COLLATE = 'es_CO.UTF-8'
--     LC_CTYPE = 'es_CO.UTF-8'
--     TEMPLATE = template0;
--
-- Uso sugerido:
--   psql -U postgres -d parchapp -v ON_ERROR_STOP=1 -f sql/parchapp_database_init.sql
--
-- IMPORTANTE: sustituir las contraseñas de los roles (CHANGE_ME_*) antes
-- de desplegar en entornos reales.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------------------------------------------------------------------------
-- Tipos enumerados
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_role') THEN
    CREATE TYPE user_role AS ENUM ('tourist', 'establishment_admin', 'platform_admin');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'establishment_status') THEN
    CREATE TYPE establishment_status AS ENUM ('pending_review', 'active', 'suspended', 'closed');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'route_status') THEN
    CREATE TYPE route_status AS ENUM ('draft', 'saved', 'completed', 'archived');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'booking_status') THEN
    CREATE TYPE booking_status AS ENUM ('pending', 'confirmed', 'cancelled', 'completed', 'no_show');
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'promotion_status') THEN
    CREATE TYPE promotion_status AS ENUM ('draft', 'active', 'paused', 'ended');
  END IF;
END$$;

-- ---------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS interests (
  id              bigserial PRIMARY KEY,
  code            varchar(64) NOT NULL UNIQUE,
  name            varchar(120) NOT NULL,
  description     text,
  sort_order      integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
  id              bigserial PRIMARY KEY,
  email           citext NOT NULL UNIQUE,
  password_hash   varchar(255) NOT NULL,
  display_name    varchar(160) NOT NULL,
  phone           varchar(40),
  avatar_url      text,
  role            user_role NOT NULL DEFAULT 'tourist',
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS establishments (
  id              bigserial PRIMARY KEY,
  owner_user_id   bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  legal_name      varchar(255) NOT NULL,
  trade_name      varchar(255) NOT NULL,
  description     text,
  contact_email   citext,
  contact_phone   varchar(40),
  website_url     text,
  address_line    text,
  city            varchar(120) NOT NULL,
  country_code    char(2) NOT NULL,
  latitude        numeric(9, 6) NOT NULL,
  longitude       numeric(9, 6) NOT NULL,
  status          establishment_status NOT NULL DEFAULT 'pending_review',
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_establishments_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT chk_establishments_lng CHECK (longitude BETWEEN -180 AND 180)
);

CREATE TABLE IF NOT EXISTS establishment_photos (
  id                  bigserial PRIMARY KEY,
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  url                 text NOT NULL,
  caption             varchar(255),
  sort_order          integer NOT NULL DEFAULT 0,
  created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS establishment_interests (
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  interest_id         bigint NOT NULL REFERENCES interests (id) ON DELETE CASCADE,
  PRIMARY KEY (establishment_id, interest_id)
);

CREATE TABLE IF NOT EXISTS establishment_hours (
  id                  bigserial PRIMARY KEY,
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  day_of_week         smallint NOT NULL,
  opens_at            time,
  closes_at           time,
  is_closed           boolean NOT NULL DEFAULT false,
  CONSTRAINT chk_establishment_hours_dow CHECK (day_of_week BETWEEN 0 AND 6),
  CONSTRAINT uq_establishment_hours_day UNIQUE (establishment_id, day_of_week)
);

CREATE TABLE IF NOT EXISTS services (
  id                  bigserial PRIMARY KEY,
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  title               varchar(200) NOT NULL,
  description         text,
  service_kind        varchar(64) NOT NULL,
  duration_minutes    integer,
  base_price_amount   numeric(12, 2),
  currency_code       char(3) NOT NULL DEFAULT 'COP',
  max_party_size      integer,
  is_bookable         boolean NOT NULL DEFAULT true,
  is_active           boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS routes (
  id                        bigserial PRIMARY KEY,
  user_id                   bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  name                      varchar(200) NOT NULL,
  description               text,
  status                    route_status NOT NULL DEFAULT 'draft',
  total_estimated_minutes   integer,
  origin_latitude           numeric(9, 6),
  origin_longitude          numeric(9, 6),
  generation_context        jsonb,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS route_stops (
  id                                  bigserial PRIMARY KEY,
  route_id                            bigint NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  establishment_id                    bigint NOT NULL REFERENCES establishments (id) ON DELETE RESTRICT,
  service_id                          bigint REFERENCES services (id) ON DELETE SET NULL,
  sort_order                          integer NOT NULL,
  estimated_travel_minutes_from_prev  integer NOT NULL DEFAULT 0,
  estimated_stay_minutes              integer,
  latitude                            numeric(9, 6) NOT NULL,
  longitude                           numeric(9, 6) NOT NULL,
  note                                varchar(500),
  CONSTRAINT chk_route_stops_lat CHECK (latitude BETWEEN -90 AND 90),
  CONSTRAINT chk_route_stops_lng CHECK (longitude BETWEEN -180 AND 180),
  CONSTRAINT uq_route_stops_order UNIQUE (route_id, sort_order)
);

CREATE TABLE IF NOT EXISTS route_interests (
  route_id      bigint NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  interest_id   bigint NOT NULL REFERENCES interests (id) ON DELETE CASCADE,
  PRIMARY KEY (route_id, interest_id)
);

CREATE TABLE IF NOT EXISTS route_share_links (
  id                    bigserial PRIMARY KEY,
  route_id              bigint NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
  created_by_user_id    bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  token                 uuid NOT NULL DEFAULT uuid_generate_v4() UNIQUE,
  expires_at            timestamptz,
  max_visits            integer,
  visit_count           integer NOT NULL DEFAULT 0,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_route_share_visits CHECK (max_visits IS NULL OR max_visits >= 0),
  CONSTRAINT chk_route_share_count CHECK (visit_count >= 0)
);

CREATE TABLE IF NOT EXISTS bookings (
  id                  bigserial PRIMARY KEY,
  user_id             bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  service_id          bigint NOT NULL REFERENCES services (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  route_id            bigint REFERENCES routes (id) ON DELETE SET NULL,
  party_size          integer NOT NULL,
  scheduled_start     timestamptz NOT NULL,
  scheduled_end       timestamptz,
  status              booking_status NOT NULL DEFAULT 'pending',
  notes               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_bookings_party CHECK (party_size > 0),
  CONSTRAINT chk_bookings_rating_window CHECK (scheduled_end IS NULL OR scheduled_end >= scheduled_start)
);

CREATE TABLE IF NOT EXISTS promotions (
  id                    bigserial PRIMARY KEY,
  establishment_id      bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  name                  varchar(200) NOT NULL,
  status                promotion_status NOT NULL DEFAULT 'draft',
  starts_at             timestamptz NOT NULL,
  ends_at               timestamptz NOT NULL,
  visibility_weight     integer NOT NULL DEFAULT 1,
  budget_amount         numeric(12, 2),
  currency_code         char(3) NOT NULL DEFAULT 'COP',
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_promotions_window CHECK (ends_at > starts_at),
  CONSTRAINT chk_promotions_weight CHECK (visibility_weight > 0)
);

CREATE TABLE IF NOT EXISTS reviews (
  id                  bigserial PRIMARY KEY,
  user_id             bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  booking_id          bigint REFERENCES bookings (id) ON DELETE SET NULL,
  rating              smallint NOT NULL,
  comment             varchar(2000),
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_reviews_rating CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT uq_reviews_user_establishment UNIQUE (user_id, establishment_id)
);

CREATE TABLE IF NOT EXISTS favorites (
  user_id             bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  establishment_id    bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  created_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, establishment_id)
);

CREATE TABLE IF NOT EXISTS conversations (
  id                    bigserial PRIMARY KEY,
  tourist_user_id       bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  establishment_id      bigint NOT NULL REFERENCES establishments (id) ON DELETE CASCADE,
  created_at            timestamptz NOT NULL DEFAULT now(),
  last_message_at       timestamptz,
  CONSTRAINT uq_conversations_tourist_establishment UNIQUE (tourist_user_id, establishment_id)
);

CREATE TABLE IF NOT EXISTS messages (
  id                  bigserial PRIMARY KEY,
  conversation_id     bigint NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
  sender_user_id      bigint NOT NULL REFERENCES users (id) ON UPDATE CASCADE ON DELETE CASCADE,
  body                text NOT NULL,
  read_at             timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Índices de apoyo a consultas frecuentes (MVP)
-- ---------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_establishments_owner ON establishments (owner_user_id);
CREATE INDEX IF NOT EXISTS idx_establishments_status_city ON establishments (status, city);
CREATE INDEX IF NOT EXISTS idx_services_establishment ON services (establishment_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_services_event ON services (establishment_id) WHERE service_kind = 'event' AND is_active;

ALTER TABLE services DROP CONSTRAINT IF EXISTS chk_services_event_duration;
ALTER TABLE services ADD CONSTRAINT chk_services_event_duration
  CHECK (service_kind <> 'event' OR (duration_minutes IS NOT NULL AND duration_minutes > 0));
CREATE INDEX IF NOT EXISTS idx_routes_user_status ON routes (user_id, status);
CREATE INDEX IF NOT EXISTS idx_route_stops_establishment ON route_stops (establishment_id);
CREATE INDEX IF NOT EXISTS idx_bookings_user_status ON bookings (user_id, status);
CREATE INDEX IF NOT EXISTS idx_bookings_service_time ON bookings (service_id, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_promotions_establishment_status ON promotions (establishment_id, status);
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON messages (conversation_id, created_at);

-- ---------------------------------------------------------------------------
-- Tablas de staging (carga CSV → datos de simulación)
-- Ejecutar desde psql (ruta absoluta al repo), después de aplicar este script:
--   \copy stg_seed_places FROM '.../db-parchapp/seed/csv/lugares.csv' CSV HEADER
--   \copy stg_seed_restaurants FROM '.../db-parchapp/seed/csv/restaurantes.csv' CSV HEADER
--   \copy stg_seed_routes FROM '.../db-parchapp/seed/csv/rutas.csv' CSV HEADER
--   \copy stg_seed_route_stops FROM '.../db-parchapp/seed/csv/ruta_paradas.csv' CSV HEADER
--   CALL sp_populate_from_seed_staging();
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stg_seed_places (
  external_code     text NOT NULL,
  legal_name        text NOT NULL,
  trade_name        text NOT NULL,
  description       text,
  city              text NOT NULL,
  country_code      text NOT NULL,
  latitude          text NOT NULL,
  longitude         text NOT NULL,
  interest_code     text NOT NULL,
  address_line      text
);

CREATE TABLE IF NOT EXISTS stg_seed_restaurants (
  external_code       text NOT NULL,
  legal_name          text NOT NULL,
  trade_name          text NOT NULL,
  description         text,
  city                text NOT NULL,
  country_code        text NOT NULL,
  latitude            text NOT NULL,
  longitude           text NOT NULL,
  interest_code       text NOT NULL,
  service_title       text NOT NULL,
  service_kind        text NOT NULL,
  base_price_amount   text,
  address_line        text
);

CREATE TABLE IF NOT EXISTS stg_seed_routes (
  external_route_code       text NOT NULL,
  name                      text NOT NULL,
  description               text,
  status                    text NOT NULL,
  total_estimated_minutes   text,
  origin_latitude           text,
  origin_longitude          text
);

CREATE TABLE IF NOT EXISTS stg_seed_route_stops (
  external_route_code                   text NOT NULL,
  external_establishment_code           text NOT NULL,
  sort_order                            text NOT NULL,
  estimated_travel_minutes_from_prev    text,
  estimated_stay_minutes                text,
  note                                  text
);

-- Usuario semilla (login demo antes del primer CALL al procedimiento de seed)
INSERT INTO users (email, password_hash, display_name, role)
VALUES (
  'seed.catalog@parchapp.local',
  '$2b$10$LfjCCGNfTLLXQBVyk5tD4ukNMKIzd2CW.IFZ0ERqDl6YPk/SJ5gRG',
  'Catálogo semilla ParchApp',
  'tourist'
)
ON CONFLICT (email) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Triggers: updated_at y last_message_at
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_users_updated_at ON users;
CREATE TRIGGER tr_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE PROCEDURE trg_set_updated_at();

DROP TRIGGER IF EXISTS tr_establishments_updated_at ON establishments;
CREATE TRIGGER tr_establishments_updated_at
  BEFORE UPDATE ON establishments
  FOR EACH ROW EXECUTE PROCEDURE trg_set_updated_at();

DROP TRIGGER IF EXISTS tr_services_updated_at ON services;
CREATE TRIGGER tr_services_updated_at
  BEFORE UPDATE ON services
  FOR EACH ROW EXECUTE PROCEDURE trg_set_updated_at();

DROP TRIGGER IF EXISTS tr_routes_updated_at ON routes;
CREATE TRIGGER tr_routes_updated_at
  BEFORE UPDATE ON routes
  FOR EACH ROW EXECUTE PROCEDURE trg_set_updated_at();

DROP TRIGGER IF EXISTS tr_bookings_updated_at ON bookings;
CREATE TRIGGER tr_bookings_updated_at
  BEFORE UPDATE ON bookings
  FOR EACH ROW EXECUTE PROCEDURE trg_set_updated_at();

CREATE OR REPLACE FUNCTION trg_messages_touch_conversation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE conversations
  SET last_message_at = NEW.created_at
  WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tr_messages_touch_conversation ON messages;
CREATE TRIGGER tr_messages_touch_conversation
  AFTER INSERT ON messages
  FOR EACH ROW EXECUTE PROCEDURE trg_messages_touch_conversation();

-- ---------------------------------------------------------------------------
-- Vistas (reportes, panel establecimiento, generador de rutas)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_establishment_rating_summary AS
SELECT
  e.id AS establishment_id,
  e.trade_name,
  e.city,
  e.status,
  round(avg(r.rating)::numeric, 2) AS avg_rating,
  count(r.id) AS review_count
FROM establishments e
LEFT JOIN reviews r ON r.establishment_id = e.id
GROUP BY e.id, e.trade_name, e.city, e.status;

CREATE OR REPLACE VIEW v_establishment_promotion_boost AS
SELECT
  e.id AS establishment_id,
  coalesce(max(p.visibility_weight) FILTER (WHERE p.status = 'active' AND now() BETWEEN p.starts_at AND p.ends_at), 0) AS active_visibility_weight
FROM establishments e
LEFT JOIN promotions p ON p.establishment_id = e.id
GROUP BY e.id;

CREATE OR REPLACE VIEW v_establishment_catalog AS
SELECT
  e.id,
  e.trade_name,
  e.legal_name,
  e.city,
  e.country_code,
  e.latitude,
  e.longitude,
  e.status,
  s.avg_rating,
  s.review_count,
  b.active_visibility_weight
FROM establishments e
JOIN v_establishment_rating_summary s ON s.establishment_id = e.id
JOIN v_establishment_promotion_boost b ON b.establishment_id = e.id
WHERE e.status = 'active';

CREATE OR REPLACE VIEW v_user_route_summary AS
SELECT
  r.id AS route_id,
  r.user_id,
  r.name,
  r.status,
  r.total_estimated_minutes,
  count(rs.id) AS stop_count,
  r.created_at,
  r.updated_at
FROM routes r
LEFT JOIN route_stops rs ON rs.route_id = r.id
GROUP BY r.id, r.user_id, r.name, r.status, r.total_estimated_minutes, r.created_at, r.updated_at;

CREATE OR REPLACE VIEW v_bookings_for_establishment AS
SELECT
  b.id AS booking_id,
  b.status,
  b.party_size,
  b.scheduled_start,
  b.scheduled_end,
  b.notes,
  b.created_at,
  svc.id AS service_id,
  svc.title AS service_title,
  e.id AS establishment_id,
  e.trade_name,
  u.id AS tourist_user_id,
  u.display_name AS tourist_display_name,
  u.email AS tourist_email
FROM bookings b
JOIN services svc ON svc.id = b.service_id
JOIN establishments e ON e.id = svc.establishment_id
JOIN users u ON u.id = b.user_id;

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

-- ---------------------------------------------------------------------------
-- Funciones y procedimientos almacenados (lógica reutilizable en servidor)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_confirm_booking_for_establishment(
  p_booking_id bigint,
  p_actor_user_id bigint
)
RETURNS booking_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner bigint;
  v_current booking_status;
BEGIN
  SELECT e.owner_user_id, b.status
  INTO v_owner, v_current
  FROM bookings b
  JOIN services s ON s.id = b.service_id
  JOIN establishments e ON e.id = s.establishment_id
  WHERE b.id = p_booking_id
  FOR UPDATE OF b;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva % no existe', p_booking_id;
  END IF;

  IF v_owner IS DISTINCT FROM p_actor_user_id THEN
    RAISE EXCEPTION 'Usuario % no autorizado para confirmar la reserva %', p_actor_user_id, p_booking_id;
  END IF;

  IF v_current <> 'pending' THEN
    RAISE EXCEPTION 'La reserva % no está en estado pendiente (actual: %)', p_booking_id, v_current;
  END IF;

  UPDATE bookings SET status = 'confirmed' WHERE id = p_booking_id;
  RETURN 'confirmed';
END;
$$;

CREATE OR REPLACE FUNCTION fn_cancel_booking_by_tourist(
  p_booking_id bigint,
  p_tourist_user_id bigint
)
RETURNS booking_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid bigint;
  v_status booking_status;
BEGIN
  SELECT user_id, status INTO v_uid, v_status
  FROM bookings
  WHERE id = p_booking_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reserva % no existe', p_booking_id;
  END IF;

  IF v_uid IS DISTINCT FROM p_tourist_user_id THEN
    RAISE EXCEPTION 'Usuario no autorizado';
  END IF;

  IF v_status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'No se puede cancelar la reserva en estado %', v_status;
  END IF;

  UPDATE bookings SET status = 'cancelled' WHERE id = p_booking_id;
  RETURN 'cancelled';
END;
$$;

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

CREATE OR REPLACE FUNCTION fn_register_route_share_visit(p_token uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id bigint;
  v_expires timestamptz;
  v_max int;
  v_count int;
BEGIN
  SELECT id, expires_at, max_visits, visit_count
  INTO v_id, v_expires, v_max, v_count
  FROM route_share_links
  WHERE token = p_token
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_expires IS NOT NULL AND v_expires < now() THEN
    RETURN false;
  END IF;

  IF v_max IS NOT NULL AND v_count >= v_max THEN
    RETURN false;
  END IF;

  UPDATE route_share_links
  SET visit_count = visit_count + 1
  WHERE id = v_id;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION fn_create_route_share_link(
  p_route_id bigint,
  p_user_id bigint,
  p_ttl interval DEFAULT interval '30 days',
  p_max_visits integer DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM routes r WHERE r.id = p_route_id AND r.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Ruta no encontrada o no pertenece al usuario';
  END IF;

  INSERT INTO route_share_links (route_id, created_by_user_id, expires_at, max_visits)
  VALUES (
    p_route_id,
    p_user_id,
    CASE WHEN p_ttl IS NULL THEN NULL ELSE now() + p_ttl END,
    p_max_visits
  )
  RETURNING token INTO v_token;

  RETURN v_token;
END;
$$;

CREATE OR REPLACE PROCEDURE sp_activate_establishment(
  p_establishment_id bigint,
  p_platform_admin_id bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM users u
    WHERE u.id = p_platform_admin_id AND u.role = 'platform_admin' AND u.is_active
  ) THEN
    RAISE EXCEPTION 'Solo un administrador de plataforma puede activar establecimientos';
  END IF;

  UPDATE establishments
  SET status = 'active', updated_at = now()
  WHERE id = p_establishment_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Establecimiento % no existe', p_establishment_id;
  END IF;
END;
$$;

COMMENT ON FUNCTION fn_confirm_booking_for_establishment(bigint, bigint) IS
  'Confirma una reserva pendiente validando que el actor sea el owner_user_id del establecimiento del servicio.';
COMMENT ON PROCEDURE sp_activate_establishment(bigint, bigint) IS
  'Activa un establecimiento tras revisión (rol platform_admin).';

-- ---------------------------------------------------------------------------
-- Población desde staging (lugares, restaurantes, rutas y paradas)
-- Requiere datos en stg_* (vía \copy o COPY desde el backend).
-- Usuario semilla: seed.catalog@parchapp.local / contraseña demo: DemoSeed2024!
-- ---------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE sp_populate_from_seed_staging()
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_uid bigint;
  r RECORD;
  v_eid bigint;
  v_rid bigint;
  v_lat numeric(9, 6);
  v_lng numeric(9, 6);
  v_travel int;
  v_stay int;
  v_total int;
BEGIN
  INSERT INTO interests (code, name, sort_order) VALUES
    ('gastronomia', 'Gastronomía', 1),
    ('cultura', 'Cultura', 2),
    ('vida_nocturna', 'Vida nocturna', 3),
    ('naturaleza', 'Naturaleza', 4)
  ON CONFLICT (code) DO NOTHING;

  INSERT INTO users (email, password_hash, display_name, role)
  VALUES (
    'seed.catalog@parchapp.local',
    '$2b$10$LfjCCGNfTLLXQBVyk5tD4ukNMKIzd2CW.IFZ0ERqDl6YPk/SJ5gRG',
    'Catálogo semilla ParchApp',
    'tourist'
  ) ON CONFLICT (email) DO NOTHING;

  SELECT id INTO v_uid FROM users WHERE email = 'seed.catalog@parchapp.local';
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No se pudo resolver el usuario semilla seed.catalog@parchapp.local';
  END IF;

  DELETE FROM routes WHERE user_id = v_uid;

  -- Reservas y paradas de otras rutas que referencian el catálogo semilla (FK RESTRICT)
  DELETE FROM bookings
  WHERE service_id IN (
    SELECT s.id
    FROM services s
    INNER JOIN establishments e ON e.id = s.establishment_id
    WHERE e.owner_user_id = v_uid
  );

  DELETE FROM route_stops
  WHERE establishment_id IN (
    SELECT id FROM establishments WHERE owner_user_id = v_uid
  );

  DELETE FROM establishments WHERE owner_user_id = v_uid;

  DROP TABLE IF EXISTS tmp_seed_est_map;
  CREATE TEMP TABLE tmp_seed_est_map (
    external_code text PRIMARY KEY,
    establishment_id bigint NOT NULL
  ) ON COMMIT DROP;

  DROP TABLE IF EXISTS tmp_seed_route_map;
  CREATE TEMP TABLE tmp_seed_route_map (
    external_route_code text PRIMARY KEY,
    route_id bigint NOT NULL
  ) ON COMMIT DROP;

  FOR r IN SELECT * FROM stg_seed_places ORDER BY external_code LOOP
    INSERT INTO establishments (
      owner_user_id, legal_name, trade_name, description,
      contact_email, contact_phone, website_url, address_line,
      city, country_code, latitude, longitude, status
    ) VALUES (
      v_uid,
      left(trim(r.legal_name), 255),
      left(trim(r.trade_name), 255),
      NULLIF(trim(r.description), ''),
      NULL,
      NULL,
      NULL,
      NULLIF(trim(r.address_line), ''),
      left(trim(r.city), 120),
      left(trim(r.country_code), 2)::bpchar,
      trim(r.latitude)::numeric(9, 6),
      trim(r.longitude)::numeric(9, 6),
      'active'::establishment_status
    )
    RETURNING id INTO v_eid;

    INSERT INTO establishment_interests (establishment_id, interest_id)
    SELECT v_eid, i.id FROM interests i WHERE i.code = trim(r.interest_code);

    INSERT INTO tmp_seed_est_map (external_code, establishment_id)
    VALUES (trim(r.external_code), v_eid);
  END LOOP;

  FOR r IN SELECT * FROM stg_seed_restaurants ORDER BY external_code LOOP
    INSERT INTO establishments (
      owner_user_id, legal_name, trade_name, description,
      contact_email, contact_phone, website_url, address_line,
      city, country_code, latitude, longitude, status
    ) VALUES (
      v_uid,
      left(trim(r.legal_name), 255),
      left(trim(r.trade_name), 255),
      NULLIF(trim(r.description), ''),
      NULL,
      NULL,
      NULL,
      NULLIF(trim(r.address_line), ''),
      left(trim(r.city), 120),
      left(trim(r.country_code), 2)::bpchar,
      trim(r.latitude)::numeric(9, 6),
      trim(r.longitude)::numeric(9, 6),
      'active'::establishment_status
    )
    RETURNING id INTO v_eid;

    INSERT INTO establishment_interests (establishment_id, interest_id)
    SELECT v_eid, i.id FROM interests i WHERE i.code = trim(r.interest_code);

    INSERT INTO services (
      establishment_id, title, description, service_kind,
      duration_minutes, base_price_amount, currency_code,
      max_party_size, is_bookable, is_active
    ) VALUES (
      v_eid,
      left(trim(r.service_title), 200),
      NULLIF(trim(r.description), ''),
      left(trim(r.service_kind), 64),
      NULL,
      NULLIF(trim(r.base_price_amount), '')::numeric(12, 2),
      'COP',
      NULL,
      true,
      true
    );

    INSERT INTO tmp_seed_est_map (external_code, establishment_id)
    VALUES (trim(r.external_code), v_eid);
  END LOOP;

  FOR r IN SELECT * FROM stg_seed_routes ORDER BY external_route_code LOOP
    v_total := NULLIF(trim(r.total_estimated_minutes), '')::integer;

    INSERT INTO routes (
      user_id, name, description, status,
      total_estimated_minutes, origin_latitude, origin_longitude,
      generation_context
    ) VALUES (
      v_uid,
      left(trim(r.name), 200),
      NULLIF(trim(r.description), ''),
      trim(r.status)::route_status,
      v_total,
      NULLIF(trim(r.origin_latitude), '')::numeric(9, 6),
      NULLIF(trim(r.origin_longitude), '')::numeric(9, 6),
      jsonb_build_object(
        'source', 'seed',
        'external_route_code', trim(r.external_route_code)
      )
    )
    RETURNING id INTO v_rid;

    INSERT INTO tmp_seed_route_map (external_route_code, route_id)
    VALUES (trim(r.external_route_code), v_rid);
  END LOOP;

  FOR r IN
    SELECT *
    FROM stg_seed_route_stops
    ORDER BY external_route_code, NULLIF(trim(sort_order), '')::integer
  LOOP
    SELECT route_id INTO v_rid
    FROM tmp_seed_route_map
    WHERE external_route_code = trim(r.external_route_code);

    SELECT establishment_id INTO v_eid
    FROM tmp_seed_est_map
    WHERE external_code = trim(r.external_establishment_code);

    IF v_rid IS NULL THEN
      RAISE EXCEPTION 'Ruta semilla desconocida: %', r.external_route_code;
    END IF;

    IF v_eid IS NULL THEN
      RAISE EXCEPTION 'Establecimiento semilla desconocido: %', r.external_establishment_code;
    END IF;

    SELECT latitude, longitude INTO v_lat, v_lng
    FROM establishments WHERE id = v_eid;

    v_travel := coalesce(NULLIF(trim(r.estimated_travel_minutes_from_prev), '')::integer, 0);
    v_stay := NULLIF(trim(r.estimated_stay_minutes), '')::integer;

    INSERT INTO route_stops (
      route_id, establishment_id, service_id,
      sort_order, estimated_travel_minutes_from_prev, estimated_stay_minutes,
      latitude, longitude, note
    ) VALUES (
      v_rid,
      v_eid,
      NULL,
      NULLIF(trim(r.sort_order), '')::integer,
      v_travel,
      v_stay,
      v_lat,
      v_lng,
      NULLIF(trim(r.note), '')
    );
  END LOOP;
END;
$$;

COMMENT ON PROCEDURE sp_populate_from_seed_staging() IS
  'Lee tablas stg_seed_* y repuebla establecimientos, servicios, rutas y paradas del usuario semilla.';

-- ---------------------------------------------------------------------------
-- Roles y permisos (contraseña de aplicación fija para MVP / clase)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parchapp_app') THEN
    CREATE ROLE parchapp_app LOGIN PASSWORD 'mK8pQ2vNx9wL4rT6!hJ';
  ELSE
    ALTER ROLE parchapp_app WITH PASSWORD 'mK8pQ2vNx9wL4rT6!hJ';
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parchapp_readonly') THEN
    CREATE ROLE parchapp_readonly LOGIN PASSWORD 'CHANGE_ME_READONLY';
  END IF;
END$$;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'parchapp_migration') THEN
    CREATE ROLE parchapp_migration LOGIN PASSWORD 'CHANGE_ME_MIGRATION';
  END IF;
END$$;

-- Otorgar conexión a la base de datos concreta (sustituir el nombre si difiere):
--   GRANT CONNECT ON DATABASE parchapp TO parchapp_app, parchapp_readonly, parchapp_migration;

GRANT USAGE ON SCHEMA public TO parchapp_app, parchapp_readonly, parchapp_migration;
GRANT CREATE ON SCHEMA public TO parchapp_migration;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO parchapp_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO parchapp_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO parchapp_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO parchapp_migration;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO parchapp_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO parchapp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO parchapp_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO parchapp_readonly;

GRANT EXECUTE ON FUNCTION fn_confirm_booking_for_establishment(bigint, bigint) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_cancel_booking_by_tourist(bigint, bigint) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_create_establishment_event(
  bigint, bigint, varchar, text, timestamptz, integer, integer, integer, text
) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_create_booking_for_event(bigint, bigint, integer, text) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_register_route_share_visit(uuid) TO parchapp_app;
GRANT EXECUTE ON FUNCTION fn_create_route_share_link(bigint, bigint, interval, integer) TO parchapp_app;
GRANT EXECUTE ON PROCEDURE sp_activate_establishment(bigint, bigint) TO parchapp_app;
GRANT EXECUTE ON PROCEDURE sp_populate_from_seed_staging() TO parchapp_app;

-- Lectura de vistas para reporting / BI ligero
GRANT SELECT ON v_establishment_rating_summary TO parchapp_readonly;
GRANT SELECT ON v_establishment_promotion_boost TO parchapp_readonly;
GRANT SELECT ON v_establishment_catalog TO parchapp_readonly;
GRANT SELECT ON v_user_route_summary TO parchapp_readonly;
GRANT SELECT ON v_bookings_for_establishment TO parchapp_readonly;
GRANT SELECT ON v_establishment_events TO parchapp_readonly;
GRANT SELECT ON v_establishment_events TO parchapp_app;

COMMIT;