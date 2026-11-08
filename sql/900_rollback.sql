-- 900_rollback.sql | DESTROYS ALL BAKERY DATA. Take a backup first:  pg_dump -Fc -d bakery -f bakery_before_rollback.dump
-- For a partial rollback, restore the backup instead; migrations here are forward-only for data safety.
BEGIN;
DROP SCHEMA IF EXISTS bakery CASCADE;
-- DROP ROLE IF EXISTS bakery_app;   -- run separately as superuser if you created it
COMMIT;
