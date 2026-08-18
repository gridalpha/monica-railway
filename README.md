# Monica on Railway

A thin wrapper around the official [`monica`](https://hub.docker.com/_/monica)
image that makes [Monica](https://github.com/monicahq/monica) — the personal
relationship manager — deployable on Railway in one click, in the topology
upstream documents for production: web, scheduler, queue worker, MySQL, Redis,
object storage and mail.

The application is upstream's, unmodified. This repo adds only the boot-time
work a one-click deploy needs and environment variables cannot express.

## What the wrapper does

| Step | Why it cannot be a variable |
|---|---|
| Normalises `APP_KEY` into a shape Laravel accepts | It must be exactly 32 bytes, or `base64:` + 32 encoded bytes. The stock entrypoint's fallback writes a fresh key into the container layer, so it would rotate on every deploy and orphan every encrypted column. |
| Derives `HASH_SALT` when it is missing or too short | Must be ≥ 20 characters and stable, or the hashed IDs in URLs change under the user. |
| Creates the app's database and a role scoped to it | Railway's managed MySQL hands out root; a template deploy has no manual steps in which to create anything better. Idempotent, and it verifies the role by connecting as it. |
| Creates the first account | Monica's only route to an account is the registration form, so without this the instance must ship with public sign-up open. |
| Points Apache at `$PORT` and re-fixes the MPM | `php:*-apache` images ship `mpm_event` enabled beside the `mpm_prefork` that `mod_php` requires, which aborts the server with `AH00534`. The build's view of `/etc/apache2` is not what runs, so it is redone on every boot. |

## Roles

One image, three services, selected by `MONICA_ROLE`:

- `web` — Apache + mod_php, the only service with a public domain
- `cron` — `busybox crond` running `artisan schedule:run` every minute
- `queue` — `artisan queue:work` over Redis

## Configuration

Everything is upstream's own environment variables
([documentation](https://github.com/monicahq/monica/blob/4.x/.env.example)),
plus:

| Variable | Default | Purpose |
|---|---|---|
| `MONICA_ROLE` | `web` | `web`, `cron` or `queue` |
| `MONICA_ADMIN_EMAIL` | — | first account; only used while no account exists |
| `MONICA_ADMIN_PASSWORD` | — | first account's password |
| `MONICA_ADMIN_FIRSTNAME` / `_LASTNAME` | `Monica` / `Admin` | first account's name |
| `MYSQL_URL` | — | root URL used once per boot to provision the scoped role; unset it to manage the database yourself |

## Licence

Monica is licensed under the AGPL-3.0 by its authors. This repository only
contains deployment scaffolding.
