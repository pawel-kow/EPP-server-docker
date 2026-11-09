# Dockerised EPP server based on XPanel https://github.com/xpanel/epp

This repository contains a full plug-and-play setup to run EPP server locally.

## Install

### Requirements
- docker
- docker compose

### Sources
The EPP server code is in the `epp-server` git submodule, and the images are built from that checkout. Fetch it before the first build:
```
git submodule update --init
```
The submodule URL uses SSH, so this needs a GitHub SSH key.

### Configuration:
- adjust [.env](.env) file with mysql credentials of registry user; the optional settings below also go there
- adjust [docker-compose.yml](./docker-compose.yml) and edit mariadb_prep container environment variables (`REG1_*`, `REG2_*`), to specify the two registrar accounts to be provisioned

### Setup run
Execute:
```
docker compose --profile setup up
docker compose --profile setup down
```

#### Notes:
- The docker container mariadb_prep only prepares needed scripts in a volumne which is mounted to mariadb container and executed only once when mariadb container is booted the first time.

## Start server and database
Execute:
```
docker compose --profile run up
```

## What is running

| Service | Purpose | Host port |
| --- | --- | --- |
| `epp-server` | EPP over TLS | 7043 |
| `epp-server` | EPP without TLS | 7001 |
| `nameserver` | BIND, authoritative for the registry TLD | 5053 (TCP and UDP, set with `DNS_PORT`) |
| `epp-cron` | Scheduled registry jobs | none |
| `mariadb` | Database | 3310 |

## Connecting to the server

Two registrars are provisioned by default:

| Login | Password | Contact ID prefix |
| --- | --- | --- |
| `foo` | `bar` | `FO-` |
| `baz` | `qux` | `BZ-` |

Each `clTRID` must be unique across all sessions. A reused value makes the server drop the command without answering, so the client hangs until it times out.

### TLS

Port 7043 uses TLS 1.2. The first start generates a self-signed certificate in `etc/pki/epp/` (`server.crt`, `server.key`), valid for `EPP_TLS_CN`, `localhost`, `epp-server` and `127.0.0.1`. To use your own, put those two files there and restart `epp-server`. Client certificates are not requested.

```bash
openssl s_client -connect localhost:7043 -CAfile etc/pki/epp/server.crt
```

## Testing transfers

Upstream refuses a transfer within 60 days of registration or of the last transfer, and auto-approves after 5 days. Those values would make a fresh test domain impossible to transfer, so this setup shortens them:

| Variable | Default | Upstream |
| --- | --- | --- |
| `TRANSFER_LOCK_DAYS` | `0` | `60` |
| `TRANSFER_WAITING_MINUTES` | `5` | `7200` |

During the waiting period the losing registrar can approve or reject. After it, `auto-approve-transfer.pl` completes the transfer on its next run.

## Testing deletes and restores (RFC 3915)

A delete within the add grace period purges the domain at once. After it, the domain stays in `redemptionPeriod` with the status `pendingDelete`, where a `<rgp:restore op="request"/>` moves it to `pendingRestore` and a `<rgp:restore op="report">` then restores it. A restore without a report in time goes back to `redemptionPeriod`. At the end of the redemption period the domain becomes `pendingDelete`, and it is purged when that period is over. `change-domain-status.pl` makes these changes on its next run (`CRON_CHANGE_DOMAIN_STATUS`).

The periods are in minutes. The defaults are upstream's, so a domain deleted soon after it was created is gone, as before. To test restores, shorten them in `.env`, for example `RGP_ADD_PERIOD_MINUTES=1`, then recreate the containers (`docker compose --profile run up -d`):

| Variable | Default | Upstream |
| --- | --- | --- |
| `RGP_ADD_PERIOD_MINUTES` | `7200` | 5 days |
| `RGP_RENEW_PERIOD_MINUTES` | `7200` | 5 days |
| `RGP_TRANSFER_PERIOD_MINUTES` | `7200` | 5 days |
| `RGP_AUTO_RENEW_PERIOD_MINUTES` | `64800` | 45 days |
| `RGP_EXPIRY_GRACE_MINUTES` (after expiry, before an unrenewed domain goes to `redemptionPeriod`) | `43200` | 30 days |
| `RGP_REDEMPTION_PERIOD_MINUTES` | `43200` | 30 days |
| `RGP_PENDING_RESTORE_MINUTES` (deadline for the report) | `10080` | 7 days |
| `RGP_PENDING_DELETE_MINUTES` | `7200` | 5 days |

A delete within the renew, transfer or auto-renew grace period credits the registrar for that renewal or transfer, and the domain then goes to `redemptionPeriod`. A transfer starts `transferPeriod` whether the losing registrar approves it or `auto-approve-transfer.pl` does after `TRANSFER_WAITING_MINUTES`. Auto-renew is switched off in `change-domain-status.pl`, so `autoRenewPeriod` is never entered unless that is changed.

## Cron jobs

The jobs run in the `epp-cron` container, and their output is in `docker compose --profile run logs epp-cron`. Set the schedules in `.env`, using standard cron syntax:

| Variable | Job | Default |
| --- | --- | --- |
| `CRON_WRITE_ZONE` | `write-zone.pl` | `* * * * *` |
| `CRON_CHANGE_DOMAIN_STATUS` | `change-domain-status.pl` | `* * * * *` |
| `CRON_AUTO_APPROVE_TRANSFER` | `auto-approve-transfer.pl` | `* * * * *` |
| `CRON_AUTO_CLEAN` | `auto-clean-unused-contact-and-host.pl` | `5 0 * * *` (daily) |
| `CRON_CLEAN_SESSIONS` | `clean-epp-sessions.pl`: removes the stored login choices of sessions idle for a day | `15 * * * *` (hourly) |

## DNS

`write-zone.pl` writes the zone from the database and reloads BIND, so a change made over EPP is published on the next run.

```bash
dig +tcp -p 5053 @localhost EXAMPLE SOA
dig +tcp -p 5053 @localhost mydomain.EXAMPLE NS
```

Delegated names appear as referrals, in the authority section of the answer.

Use `+tcp` with Colima: its port forwarding did not carry UDP to the Mac in testing, so UDP queries from the Mac time out. UDP works from inside the Docker VM and from other containers.

`ZONE_NS1` and `ZONE_NS2` set the zone's SOA and apex NS names (no trailing dot).

## Remove server and the data
Execute:
```
docker compose --profile run down -v
```

## TODOs:
- check why WHOIS and das crash apache without any output
