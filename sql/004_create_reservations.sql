CREATE TYPE reservation_status AS ENUM ('pending', 'confirmed', 'cancelled');

CREATE TABLE reservations (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  establishment_id UUID NOT NULL REFERENCES establishments(id) ON DELETE CASCADE,
  tourist_user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  reservation_date TIMESTAMPTZ NOT NULL,
  party_size       INT NOT NULL CHECK (party_size >= 1),
  status           reservation_status NOT NULL DEFAULT 'pending',
  note             TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
