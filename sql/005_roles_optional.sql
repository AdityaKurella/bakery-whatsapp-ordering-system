-- 005_roles_optional.sql | least-privilege role for the n8n PostgreSQL credential. Run as a superuser.
-- psql -v ON_ERROR_STOP=1 -v app_password='CHOOSE_A_STRONG_PASSWORD' -d bakery -f 005_roles_optional.sql
CREATE ROLE bakery_app LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT USAGE ON SCHEMA bakery TO bakery_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA bakery TO bakery_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA bakery TO bakery_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA bakery TO bakery_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
-- The app role cannot run DDL. schema_migrations is only written by the migration user.
REVOKE INSERT, UPDATE, DELETE ON bakery.schema_migrations FROM bakery_app;
