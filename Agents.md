# Agents.md

This file provides guidance to coding Agents when working with code in this repository.

## What this repository is

A Docker packaging of the XPanel EPP registry server (https://github.com/xpanel/epp). It holds only Dockerfiles, entrypoint scripts, SQL templates and Apache/registry config. The EPP server source (Perl CGI, `registry.sql`) is not in this repo: it is downloaded as the `v1.0.15` tarball at image build time. There is no test suite, linter or build system; a change is verified by bringing the stack up.

## Commands

```bash
# One-time DB provisioning: fills the init-scripts volume, then exits
docker compose --profile setup up
docker compose --profile setup down

# Run the server and database (add --build after changing anything baked into the image)
docker compose --profile run up

# Wipe containers and data, including both named volumes; setup must be rerun afterwards
docker compose --profile run down -v

# Validate the compose file without starting anything
docker compose --profile setup --profile run config -q

# Inspect the running server
docker compose --profile run logs -f epp-server
```

## Architecture

Two compose profiles split provisioning from runtime, and they communicate only through the `maria_db_install_scripts` volume:

1. **`setup` profile, `mariadb_prep` (Alpine, one-shot).** `.docker/mariadb_prep/docker_entrypoint.sh` renders three SQL files into the volume:
   - `01_registry.sql`: upstream `sql/registry.sql` with `GRANT`, `USER` and `FLUSH` lines filtered out
   - `02_registrar.sql`: `create_registrar.sql` with its placeholders filled in; it clears the registrar, TLD and price tables, then inserts two registrars and one TLD
   - `03_user.sql`: `install/user.sql` with `<MYSQL_USER>` filled in
2. **`run` profile, `mariadb` (10.1).** Mounts the same volume as `/docker-entrypoint-initdb.d`. The image runs those scripts only on first boot, when `mariadb_data` is empty.
3. **`run` profile, `epp-server` (Fedora 26, Apache).** Starts after `mariadb` is healthy. This image has three roles, chosen by the argument to `.docker/epp/docker_entrypoint.sh`: `apache` (default), `cron` and `nameserver`. `mod_epp` turns EPP traffic into HTTP requests, which `etc/httpd/epp_server_common.conf` aliases to the upstream CGI scripts in `/var/www/cgi-bin/epp` (`command/`, `session/`, `error/`). Login is Apache Basic auth against the `registrar` table via `mod_authn_dbd`, so `registrar.pw` must be in `{SHA}base64(sha1(pwd))` format.
4. **`run` profile, `nameserver` (same image, BIND).** Authoritative for `REGISTRY_TLD`, reading `named.<TLD>.zone` from the `zone_data` volume. It generates `rndc.key` in that volume.
5. **`run` profile, `epp-cron` (same image, cronie).** Starts after `mariadb` and `nameserver` are healthy, and renders `etc/cron.d/registry` from the `CRON_*` variables. `write-zone.pl` writes into `zone_data`, then runs `rndc` against `nameserver`.

`.docker/epp/patch_upstream.sh` patches the upstream sources at build time, and fails the build if a pattern no longer matches. It makes the zone NS names and the transfer lock and waiting period configurable, replaces `systemctl` with `rndc`, and fixes the host address type bugs (see below).

## Configuration: where values take effect

- **Registrar and TLD values** (`REG1_*`, `REG2_*`, `REGISTRY_TLD`) are applied only at first DB boot. Changing them requires `down -v` and rerunning setup.
- **Placeholders in `create_registrar.sql`:** any `<VAR_NAME>` is filled from the `mariadb_prep` environment, and an unset variable silently becomes an empty string. `REG_CR_DATE` and `REG1_PWD_HASH`/`REG2_PWD_HASH` are computed by the entrypoint. The `THRESHHOLD` spelling is consistent between the compose file and the template; keep it that way.
- **`etc/registry/registry.conf`** is copied into the image, and `.docker/epp/docker_entrypoint.sh` substitutes its `<PLACEHOLDER>` values at container start. Edits require a rebuild. The compose anchor `x-registry-env` supplies the values, including `ZONE_NS*` and `TRANSFER_*`.
- **`etc/cron.d/registry`** is a template baked into the image, so edits require a rebuild. Schedules come from the `CRON_*` variables and need only a container recreate.
- **TLS files** are in `etc/pki/epp/` (git-ignored), bind-mounted into `epp-server`. They are generated only when missing, so delete them to regenerate after changing `EPP_TLS_CN`.
- **`etc/httpd/conf.d/` and `etc/httpd/epp_server_common.conf`** are bind-mounted, so edits need only a container restart. `epp_server_common.conf` is not copied by the Dockerfile and exists only through this mount. The `conf.d` mount also hides the image's own `conf.d` contents.
- **DB connection settings exist in two places.** Apache's `DBDParams` hardcodes `host=mariadb` and reads `${MYSQL_USER}`/`${MYSQL_PASSWORD}` from the environment, while the CGI scripts use `registry.conf`. `MYSQL_HOST` affects only the latter.
- **Credentials** for the DB user come from `.env`.
- **`MYSQL_DATABASE` must stay `registry`.**

## Upgrading the upstream EPP version

The version is hardcoded in three files, which must change together: `.docker/epp/Dockerfile`, `.docker/mariadb_prep/Dockerfile` and `.docker/mariadb_prep/docker_entrypoint.sh` (the `epp-1.0.15/` path). Then check that `.docker/epp/patch_upstream.sh` still applies.

## Ports

EPP is reached from the host on the mapped ports, not the in-container ports that the README mentions:

| Service | Host | Container |
| --- | --- | --- |
| EPP | 7001 | 700 |
| EPP over TLS | 7043 | 743 |
| WHOIS | 43 | 43 |
| DAS | 4343 | 4343 |
| DNS, TCP and UDP (`DNS_PORT`) | 5053 | 53 |
| MariaDB | 3310 | 3306 |

## Upstream behaviour to know about

- `clTRID` is unique in the database. A reused value kills the CGI script, and the client gets no response.
- Contact IDs must start with the registrar's `prefix` followed by `-`. `prefix` is `char(2)` and must be unique.
- A single invalid record stops BIND from loading the zone, and it keeps serving the previous version. After a change, check `logs nameserver` for `not loaded due to errors`.
- Rows in `host_addr` created before the patch have an empty `ip`. `write-zone.pl` and `EPPWriter.pm` are patched to derive the type from the address, so these rows still work.

## Known incomplete areas

- Port 700 stays plain text, and TLS on 743 does not request client certificates.
- The README reports that the WHOIS and DAS configs crash Apache with no output; the cause is unresolved.
