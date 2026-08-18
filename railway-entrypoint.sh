#!/bin/bash
#
# Railway entrypoint for every Monica role. Does the work that has to happen
# inside the container — normalising the encryption key, giving Apache the port
# the platform assigned it, and provisioning the app's own database role — then
# hands over to upstream's own entrypoint or role script, unchanged.
set -Eeuo pipefail

log() { printf '[railway] %s\n' "$*"; }

: "${MONICA_ROLE:=web}"
: "${PORT:=8080}"

MONICADIR=/var/www/html

# --------------------------------------------------------------- encryption key
#
# Laravel accepts a key of exactly 32 bytes, or "base64:" followed by 32
# base64-encoded bytes — a shape no Railway variable can promise. The stock
# entrypoint's fallback (`artisan key:generate`) writes into the container
# layer, so it would mint a *new* key on every deploy and make every encrypted
# column and every signed cookie unreadable. Normalise deterministically
# instead: the same input always yields the same key, and a key already in a
# valid shape is passed through untouched.
if [ -z "${APP_KEY:-}" ] || [ "${APP_KEY}" = "ChangeMeBy32KeyLengthOrGenerated" ]; then
    log "FATAL: APP_KEY is unset. It must be a stable value — a generated one"
    log "       would rotate on every deploy and orphan all encrypted data."
    exit 1
fi
APP_KEY="$(php -r '
    $k = $argv[1];
    if (str_starts_with($k, "base64:")) {
        $d = base64_decode(substr($k, 7), true);
        if ($d !== false && strlen($d) === 32) { echo $k; exit; }
    } elseif (strlen($k) === 32) { echo $k; exit; }
    echo "base64:" . base64_encode(hash("sha256", $k, true));
' "$APP_KEY")"
export APP_KEY

# HASH_SALT only obfuscates the IDs in URLs, so a short one is worth repairing
# rather than refusing to boot over — but it must stay stable, hence deriving it
# from APP_KEY rather than generating one.
if [ -z "${HASH_SALT:-}" ] || [ "${#HASH_SALT}" -lt 20 ] || [ "${HASH_SALT}" = "ChangeMeBy20+KeyLength" ]; then
    HASH_SALT="$(php -r 'echo hash("sha256", "hashsalt:" . $argv[1]);' "$APP_KEY")"
    export HASH_SALT
    log "HASH_SALT was unset or too short; derived a stable one from APP_KEY."
fi

# ------------------------------------------------------------------- storage
# The stock entrypoint creates these only on its apache branch, and a Railway
# volume mounted here starts empty, hiding whatever the image baked in.
for d in logs app/public framework/views framework/cache framework/sessions; do
    mkdir -p "${MONICADIR}/storage/${d}"
done
chown -R www-data:www-data "${MONICADIR}/storage"
chmod -R g+rw "${MONICADIR}/storage"

# -------------------------------------------------------------------- database
# Railway's managed MySQL hands out root. Give the application its own database
# and a role scoped to it, idempotently, from inside the container — a template
# deploy has no manual steps, and every role can run this safely because each
# statement is an IF NOT EXISTS.
if [ -n "${MYSQL_URL:-}" ]; then
    set +e
    php /usr/local/bin/provision-db.php
    rc=$?
    set -e
    if [ "$rc" -eq 3 ]; then
        log "WARNING: the scoped MySQL role could not be used; falling back to"
        log "         the root credentials for this boot. The app still works;"
        log "         the least-privilege split does not."
        # shellcheck disable=SC1091
        . /tmp/railway-db-fallback.env
        export DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD
    elif [ "$rc" -ne 0 ]; then
        log "FATAL: database provisioning failed (exit ${rc})."
        exit "$rc"
    fi
fi

# ---------------------------------------------------------------------- apache
if [ "$MONICA_ROLE" = "web" ]; then
    sed -ri "s/^Listen [0-9]+\$/Listen ${PORT}/" /etc/apache2/ports.conf
    sed -ri "s!<VirtualHost \*:[0-9]+>!<VirtualHost *:${PORT}>!" \
        /etc/apache2/sites-available/000-default.conf

    # php:*-apache images ship mpm_event enabled next to the mpm_prefork that
    # mod_php requires, which aborts the server with AH00534. The build's view
    # of /etc/apache2 is not what runs, so re-normalise here, every boot.
    a2dismod -f mpm_event mpm_worker >/dev/null 2>&1 || true
    rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
    a2enmod mpm_prefork >/dev/null 2>&1 || true
    log "apache mpm modules: $(ls /etc/apache2/mods-enabled | grep -c mpm) enabled -> $(ls /etc/apache2/mods-enabled | grep mpm | tr '\n' ' ')"
    apache2ctl -t || true
fi

log "role=${MONICA_ROLE} port=${PORT} db=${DB_DATABASE:-unset} user=${DB_USERNAME:-unset}"

case "$MONICA_ROLE" in
    cron)
        exec /usr/local/bin/cron.sh
        ;;
    queue)
        exec /usr/local/bin/queue.sh
        ;;
    web)
        # Upstream's entrypoint takes its migration branch when its first
        # argument starts with "apache", so passing apache-boot gets the
        # schema updated and the Passport keys created first; apache-boot then
        # creates the first account and execs Apache.
        exec /usr/local/bin/entrypoint.sh apache-boot
        ;;
    *)
        log "FATAL: unknown MONICA_ROLE '${MONICA_ROLE}' (expected web, cron or queue)."
        exit 1
        ;;
esac
