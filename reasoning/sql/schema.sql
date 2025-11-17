CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS documents(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org text NOT NULL,
  source text,
  mime text,
  title text,
  created_at timestamptz DEFAULT now(),
  hash text
);

CREATE TABLE IF NOT EXISTS chunks(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_id uuid REFERENCES documents(id) ON DELETE CASCADE,
  org text NOT NULL,
  n int,
  text text,
  embedding vector(3072),
  meta jsonb
);

CREATE INDEX IF NOT EXISTS idx_chunks_org ON chunks(org);
CREATE INDEX IF NOT EXISTS idx_chunks_vec ON chunks USING ivfflat (embedding vector_cosine_ops) WITH (lists=100);
