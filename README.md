# Dockerised EPP server based on XPanel https://github.com/xpanel/epp

This repository contains a full plug-and-play setup to run EPP server locally.

## Install

### Requirements
- docker
- docker compose

### Configuration:
- adjust [.env](.env) file with mysql credentials of registry user
- adjust [docker-compose.yml](./docker-compose.yml) and edit mariadb_prep container environment variables, to specify the initial registrar account to be provisioned

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

## Connecting to the server

The server listens currently on port 700 and 743.
Both ports are now without TLS.

TODO: activate TLS on port 743.

## Remove server and the data
Execute:
```
docker compose --profile run down -v
```

## TODOs:
- finish the configuration to work with TLS connection
### Generate certificate for apache
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ./etc/pki/tls/epp.localhost.key -out ./etc/pki/tls/epp.localhost.crt -subj "/C=DE/CN=epp.localhost"
```
- activate CRON jobs
- check why WHOIS and das crash apache without any output