# Agents.md

This file provides guidance to coding Agents when working with code in this repository.

## What this repository is

A Docker packaging of the XPanel EPP registry server (https://github.com/xpanel/epp). It holds only Dockerfiles, entrypoint scripts, SQL templates and Apache/registry config. The EPP server source (Perl CGI, `registry.sql`) is in the `epp-server` git submodule (the fork `pawel-kow/epp`), and both images copy it from that checkout at build time. Run `git submodule update --init` before building. Changes to the server code belong in the submodule; see `epp-server/AGENTS.md`. There is no linter or build system; a change is verified by bringing the stack up.

## Tests

Do not write throwaway tests: no one-off scripts, ad hoc probes or test files kept outside the repository. Every test goes in the `./test` folder, written so that it can be rerun later as a regression test.

Work test-first (TDD): write a test in `./test` that reproduces the bug or describes the new behaviour, run it and see it fail for the expected reason, make the smallest change that passes, then rerun the suite.

```bash
# Starts an isolated stack with fresh data, runs test/*.t inside epp-server, then removes the stack
test/run.sh
test/run.sh test/login.t
KEEP_STACK=1 test/run.sh    # leaves the stack up for inspection
```

`run.sh` starts each test detached and collects its output from a file, because attached `docker exec` can lose its stream and exit 0 with no output, which would pass a test unseen.

Tests are plain Perl using core modules, plus `DBI` where a test has to seed data, because they run inside the container. `test/lib/epp_client.pl` is the shared EPP client and assertions.

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
   - `01_registry.sql`: `epp-server/sql/registry.sql` with `GRANT`, `USER` and `FLUSH` lines filtered out
   - `02_registrar.sql`: `create_registrar.sql` with its placeholders filled in; it clears the registrar, TLD and price tables, then inserts two registrars and one TLD
   - `03_user.sql`: `install/user.sql` with `<MYSQL_USER>` filled in
2. **`run` profile, `mariadb` (10.1).** Mounts the same volume as `/docker-entrypoint-initdb.d`. The image runs those scripts only on first boot, when `mariadb_data` is empty.
3. **`run` profile, `epp-server` (Fedora 26, Apache).** Starts after `mariadb` is healthy. This image has three roles, chosen by the argument to `.docker/epp/docker_entrypoint.sh`: `apache` (default), `cron` and `nameserver`. `mod_epp` turns EPP traffic into HTTP requests, which `etc/httpd/epp_server_common.conf` aliases to the CGI scripts in `/var/www/cgi-bin/epp` (`command/`, `session/`, `error/`). Login is Apache Basic auth against the `registrar` table via `mod_authn_dbd`, so `registrar.pw` must be in `{SHA}base64(sha1(pwd))` format. `EPPAuthURI` is a URL with no directory behind it, so the auth block must stay a `<Location /epp/auth>`: a `<Directory>` block never applies, and logins then reach `session-login.cgi` unchecked.
4. **`run` profile, `nameserver` (same image, BIND).** Authoritative for `REGISTRY_TLD`, reading `named.<TLD>.zone` from the `zone_data` volume. It generates `rndc.key` in that volume.
5. **`run` profile, `epp-cron` (same image, cronie).** Starts after `mariadb` and `nameserver` are healthy, and renders `etc/cron.d/registry` from the `CRON_*` variables. `write-zone.pl` writes into `zone_data`, then runs `rndc` against `nameserver`.

The `epp-server` fork differs from upstream `v1.0.15` in these ways: the zone NS names and the transfer lock and waiting period are configurable, `write-zone.pl` reloads BIND with `rndc` rather than `systemctl`, and the host address type bugs are fixed (see below).

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
- **`dns_opt: single-request`** on `epp-server` and `epp-cron` keeps glibc from sending A and AAAA in parallel. Without it, about 1 lookup of `mariadb` in 5 stalls for the 5s resolver timeout, and every CGI run does such a lookup in a new process. A new service that runs the scripts needs it too.

## Changing the EPP server code

Edit `epp-server/`, then rebuild with `--build`: the images are built from the working tree of the submodule, including uncommitted changes. Commit and push inside the submodule first, then commit the updated pointer here. A parent commit that points at an unpushed submodule commit breaks fresh clones.

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

## Throwaway test stacks in the devcontainer

The devcontainer has no Docker daemon of its own: it talks to the host's daemon through a mounted socket. A plain `docker compose` run from `/workspaces/EPP-server-docker` therefore goes wrong in three ways:

- **Bind mount paths.** Compose expands `./...` to `/workspaces/EPP-server-docker/...`, but the daemon resolves that path on the host, where it does not exist. Docker silently creates empty directories there instead of failing. The real host path of the workspace is in `$LOCAL_WORKSPACE_FOLDER`. Build contexts are not affected, because the client sends them, so a successful build proves nothing about mounts, and neither does `config -q`.
- **Ports.** The main stack may already be running on the host and holding the ports in the table above, so a second stack cannot publish them. Check with `docker ps`.
- **Names and volumes.** Without `-p`, commands act on the project `epp-server-docker`: the real stack and its data, including on `down -v`.

Symptoms of the bind mount problem: `mariadb_prep` stops with `Input file '/install/user.sql' not found`, `/docker-entrypoint-initdb.d` is empty in `mariadb`, and `epp-cron` logs `Table 'registry.domain_tld' doesn't exist`. Containers can still report as up. Apache also starts with an empty `conf.d`.

For a test stack, use a separate project name and the override file [.devcontainer/docker-compose.test.yml](.devcontainer/docker-compose.test.yml). It removes the published ports and replaces every bind mount with its host path, and compose refuses to run if `LOCAL_WORKSPACE_FOLDER` is unset. If a bind mount is added to `docker-compose.yml`, add it to the override too.

```bash
# docker-compose.yml must stay first: it sets the project directory, and so where .env is read from
c="docker compose -p epptest -f docker-compose.yml -f .devcontainer/docker-compose.test.yml"
$c --profile setup --profile run build
$c --profile setup up mariadb_prep
$c --profile setup rm -f mariadb_prep
$c --profile run up -d --wait

# Remove the containers, volumes and images afterwards
$c --profile setup --profile run down -v --rmi local
```

With no published ports, reach services from inside the containers, for example `docker exec -i epptest-epp-server-1 ...` against `127.0.0.1:700` for EPP, or `docker exec epptest-nameserver-1 dig @127.0.0.1 ...` for DNS.

`etc/pki/epp` is the same directory the main stack uses. If `server.crt` and `server.key` are missing, the test stack generates them there.

If a run did use the wrong paths, bring it down, list what it left on the host, and delete only that:

```bash
docker run --rm -v /workspaces:/w alpine find /w -exec ls -ld {} \;
docker run --rm -v /workspaces:/w alpine rm -rf /w/EPP-server-docker
```

## Upstream behaviour to know about

- `clTRID` is unique per registrar. `record_cl_transaction` in `EPP/Transaction.pm` stores it as `<registrar id>:<clTRID>`, hashing the client's value when that would not fit the 64-character column, and answers `2400` on a reuse without logging the refused command. Query `clTRIDframe` for the value as sent. Rows written before this form existed are unprefixed, so they no longer count as reuse. An absent `clTRID` reaches the scripts as an empty string, is stored as `NULL`, and is left out of the reply.
- `mod_epp` ends the session on every `<logout>`, even when the script answers `2400`. The next command gets `2002`.
- Contact IDs must start with the registrar's `prefix` followed by `-`. `prefix` is `char(2)` and must be unique.
- A single invalid record stops BIND from loading the zone, and it keeps serving the previous version. After a change, check `logs nameserver` for `not loaded due to errors`.
- Rows in `host_addr` written by unfixed `command-create.cgi` have an empty `ip`. `write-zone.pl` and `EPPWriter.pm` derive the type from the address, so these rows still work.

## Known incomplete areas

- Port 700 stays plain text, and TLS on 743 does not request client certificates.
- DS data is stored and returned by `domain:info`, but `write-zone.pl` does not publish it, and WHOIS and DAS always answer `DNSSEC:Unsigned`.
- The README reports that the WHOIS and DAS configs crash Apache with no output; the cause is unresolved.
