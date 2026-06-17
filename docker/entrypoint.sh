#!/usr/bin/env bash
# First-boot bootstrap for the HR Tool container: wait for Postgres, create the
# app key, run migrations, seed the starter data once, then serve.
set -e

DB_DSN="pgsql:host=${DB_HOST};port=${DB_PORT};dbname=${DB_DATABASE}"

echo "==> Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT} ..."
# php:8.2-cli has no pg_isready binary, so probe with PDO (pdo_pgsql is built in).
until php -r '
    try {
        new PDO("'"$DB_DSN"'", getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
        exit(0);
    } catch (Throwable $e) { exit(1); }
'; do
    sleep 2
    echo "    ...still waiting for the database"
done
echo "==> Database is up."

# Give key:generate a .env file to write to (first boot only).
if [ ! -f .env ]; then
    cp docker/app.env .env
fi

# On Render.com (always HTTPS behind a proxy) point app/asset URLs at the public
# HTTPS URL so assets aren't blocked as mixed content. No effect elsewhere.
if [ -n "$RENDER_EXTERNAL_URL" ]; then
    export APP_URL="$RENDER_EXTERNAL_URL"
    export ASSET_URL="$RENDER_EXTERNAL_URL"
fi

# Generate APP_KEY only if one isn't already set (fixes the
# "No application encryption key has been specified" error).
if ! grep -q '^APP_KEY=base64:' .env; then
    echo "==> Generating application key..."
    php artisan key:generate --force
fi

echo "==> Running migrations..."
php artisan migrate --force

# Seed ONLY on first boot. StarterSeeder is not idempotent (it would crash on
# the roles' unique constraint if run twice), so gate it on an empty database.
SEEDED="$(php -r '
    try {
        $p = new PDO("'"$DB_DSN"'", getenv("DB_USERNAME"), getenv("DB_PASSWORD"));
        echo (int) $p->query("SELECT count(*) FROM globals")->fetchColumn();
    } catch (Throwable $e) { echo 0; }
')"
if [ "${SEEDED:-0}" = "0" ]; then
    echo "==> Seeding starter data (first boot)..."
    php artisan db:seed --seeder=StarterSeeder --force
else
    echo "==> Data already present — skipping seed."
fi

chmod -R ug+rw storage bootstrap/cache 2>/dev/null || true

# Listen on the platform-provided port if there is one (Render/App Platform set
# $PORT); otherwise default to 8000 (local / Droplet via docker-compose).
SERVE_PORT="${PORT:-8000}"

echo ""
echo "=================================================================="
echo "  HR TOOL IS READY  (serving on port ${SERVE_PORT})"
echo "  Local:   http://localhost:${SERVE_PORT}"
echo "  Log in:  super@root.com  /  password   (change it after first login)"
echo "=================================================================="
echo ""

# --host=0.0.0.0 is mandatory so the port is reachable from outside the container.
exec php artisan serve --host=0.0.0.0 --port="$SERVE_PORT"
