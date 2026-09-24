CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    public_key BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
