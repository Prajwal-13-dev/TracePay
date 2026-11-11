-- 009_db_roles.sql : the web application's own database role.
-- The app connects as tracepay_app, which can:
--   * SELECT what the pages show,
--   * write directly only where the app genuinely writes rows (drafts, complaints, notes, embeddings),
--   * do everything else ONLY through the SECURITY DEFINER procedures, which check the rules and the caller.
-- Migrations, seeds and tests run as the owner, tracepay_owner. The role's password is set by
-- scripts/reset-db.mjs from PG_APP_PASSWORD (.env). Roles are cluster-wide, so it is created only once.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tracepay_app') THEN
    CREATE ROLE tracepay_app LOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA public TO tracepay_app;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO tracepay_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO tracepay_app;

-- Direct writes the app needs (everything else goes through procedures).
GRANT INSERT, UPDATE, DELETE ON draft_complaints TO tracepay_app;
GRANT INSERT ON fraud_cases TO tracepay_app;
GRANT UPDATE (status, investigator_notes, priority) ON fraud_cases TO tracepay_app;
GRANT INSERT, UPDATE ON case_embeddings TO tracepay_app;                              -- complaint form + npm run embed
GRANT UPDATE (processed_at, attempts, last_error) ON graph_outbox TO tracepay_app;    -- graph-sync worker

-- Maintenance functions are for the owner only.
REVOKE EXECUTE ON FUNCTION register_invariant(text, regclass, name, name, regclass, name, name, text, name, text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION drop_invariant(text) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE seed_insert_transfers() FROM PUBLIC;
