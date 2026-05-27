-- Permite re-ejecutar sp_populate_from_seed_staging cuando existen reservas o paradas
-- que referencian establecimientos/servicios del usuario semilla.

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
