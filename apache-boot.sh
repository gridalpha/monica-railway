#!/bin/bash
#
# Second stage of the web role. Upstream's entrypoint runs the migrations and
# creates the Passport keys before handing control here, so by this point the
# schema exists and an account can be created.
set -Eeo pipefail

log() { printf '[railway] %s\n' "$*"; }

cd /var/www/html

# Monica's only route to a first account is the registration form, so a
# template that ships with registration open would serve a public sign-up page
# to the internet until its owner happened to close it. Creating the account
# here instead means APP_DISABLE_SIGNUP can be true from the very first request.
if [ -n "${MONICA_ADMIN_EMAIL:-}" ] && [ -n "${MONICA_ADMIN_PASSWORD:-}" ]; then
    users="$(php -r '
        mysqli_report(MYSQLI_REPORT_OFF);
        $m = @new mysqli(
            getenv("DB_HOST"), getenv("DB_USERNAME"), getenv("DB_PASSWORD"),
            getenv("DB_DATABASE"), (int) (getenv("DB_PORT") ?: 3306)
        );
        if ($m->connect_errno) { echo "-1"; exit; }
        $r = @$m->query("SELECT COUNT(*) AS c FROM users");
        echo $r ? $r->fetch_assoc()["c"] : "-1";
    ')"

    if [ "$users" = "0" ]; then
        log "no accounts yet — creating the first one for ${MONICA_ADMIN_EMAIL}"
        # APP_ENV=local for this one command: account:create uses Laravel's
        # ConfirmableTrait but declares no --force option, so in a production
        # environment it prompts, and a container has nothing to answer with —
        # it would report success having created nothing.
        APP_ENV=local php artisan account:create \
            --email="${MONICA_ADMIN_EMAIL}" \
            --password="${MONICA_ADMIN_PASSWORD}" \
            --firstname="${MONICA_ADMIN_FIRSTNAME:-Monica}" \
            --lastname="${MONICA_ADMIN_LASTNAME:-Admin}"
        # account:create makes an account owner, not an instance administrator.
        php artisan monica:admin --email="${MONICA_ADMIN_EMAIL}" --force
    elif [ "$users" = "-1" ]; then
        log "WARNING: could not read the users table; skipping account bootstrap."
    else
        log "${users} account(s) already exist — leaving them alone."
    fi
fi

# artisan ran as root and may have left root-owned log files behind, which the
# www-data workers then cannot append to.
chown -R www-data:www-data /var/www/html/storage

exec apache2-foreground
