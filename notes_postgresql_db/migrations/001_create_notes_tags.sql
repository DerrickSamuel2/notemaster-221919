-- Notes/Tags schema (many-to-many) with indexes for search & tag filtering.
-- This migration is designed to be idempotent and safe to re-run.

-- Track applied migrations
CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Notes table
CREATE TABLE IF NOT EXISTS notes (
    id BIGSERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    -- Optional lightweight denormalized search column (kept simple; backend can write into it if desired)
    search_text TEXT GENERATED ALWAYS AS (coalesce(title, '') || ' ' || coalesce(content, '')) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tags table
CREATE TABLE IF NOT EXISTS tags (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Join table (many-to-many)
CREATE TABLE IF NOT EXISTS note_tags (
    note_id BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag_id BIGINT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (note_id, tag_id)
);

-- Indexes for common access patterns:
-- 1) Tag filtering: find notes by tag quickly
CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id_note_id ON note_tags (tag_id, note_id);

-- 2) Tag lookup by name (already UNIQUE, but explicit btree index is implied; this is here for clarity/readability)
-- (No extra index needed; UNIQUE(name) already creates one.)

-- 3) Notes ordering/filtering by timestamps
CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes (updated_at DESC);

-- 4) Fast "contains text" search
-- Use GIN trigram indexes over title/content for ILIKE / substring search
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_notes_title_trgm ON notes USING gin (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_notes_content_trgm ON notes USING gin (content gin_trgm_ops);

-- Also add full-text search vector index for to_tsvector-based searching (backend can choose either approach)
CREATE INDEX IF NOT EXISTS idx_notes_search_tsv ON notes USING gin (to_tsvector('english', coalesce(title,'') || ' ' || coalesce(content,'')));

-- Record migration as applied
INSERT INTO schema_migrations (version)
VALUES ('001_create_notes_tags')
ON CONFLICT (version) DO NOTHING;
