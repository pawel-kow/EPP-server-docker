#!/bin/bash
# One image, three roles: "apache" (default), "cron" and "nameserver".
set -euo pipefail

TLS_DIR=/etc/pki/tls/epp
RNDC_KEY=/var/named/rndc.key

# Fill every <PLACEHOLDER> in registry.conf from the environment.
render_registry_conf() {
  export MYSQL_HOST="${MYSQL_HOST:-mariadb}"
  export EPP_SERVER_REPOSITORY="${EPP_SERVER_REPOSITORY:-NIC}"
  export EPP_SERVER_ID="${EPP_SERVER_ID:-NIC Server}"
  perl -pi -e 's{<([A-Z0-9_]+)>}{$ENV{$1} // ""}ge' /etc/registry/registry.conf
}

# Create a self-signed certificate unless one is already in the mounted directory.
ensure_tls_certificate() {
  local cn="${EPP_TLS_CN:-epp.localhost}"
  if [ -s "$TLS_DIR/server.crt" ] && [ -s "$TLS_DIR/server.key" ]; then
    return
  fi
  echo "Generating self-signed EPP TLS certificate for $cn"
  mkdir -p "$TLS_DIR"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$TLS_DIR/server.key" -out "$TLS_DIR/server.crt" -subj "/CN=$cn" \
    -config <(cat /etc/pki/tls/openssl.cnf
              printf '[san]\nsubjectAltName=DNS:%s,DNS:localhost,DNS:epp-server,IP:127.0.0.1\n' "$cn") \
    -extensions san
  chmod 600 "$TLS_DIR/server.key"
}

start_apache() {
  render_registry_conf
  ensure_tls_certificate
  exec /usr/sbin/httpd -D FOREGROUND
}

start_cron() {
  render_registry_conf
  sed -e "s|<CRON_WRITE_ZONE>|$CRON_WRITE_ZONE|" \
      -e "s|<CRON_CHANGE_DOMAIN_STATUS>|$CRON_CHANGE_DOMAIN_STATUS|" \
      -e "s|<CRON_AUTO_APPROVE_TRANSFER>|$CRON_AUTO_APPROVE_TRANSFER|" \
      -e "s|<CRON_AUTO_CLEAN>|$CRON_AUTO_CLEAN|" \
      -e "s|<CRON_CLEAN_SESSIONS>|$CRON_CLEAN_SESSIONS|" \
      /etc/registry/cron.template > /etc/cron.d/registry
  chmod 644 /etc/cron.d/registry

  # Publish the zone now rather than at the first cron tick.
  /var/www/cgi-bin/epp/cron/write-zone.pl || echo "Initial write-zone.pl run failed; cron will retry"
  exec /usr/sbin/crond -n
}

start_nameserver() {
  # The key lives in the zone volume so that the cron container can reach it.
  [ -s "$RNDC_KEY" ] || rndc-confgen -a -A hmac-sha256 -k rndc-key -c "$RNDC_KEY"
  chown root:named "$RNDC_KEY"
  chmod 640 "$RNDC_KEY"
  mkdir -p /run/named
  chown named:named /run/named

  cat > /etc/named.conf <<CONF
options {
    directory "/var/named";
    pid-file "/run/named/named.pid";
    session-keyfile "/run/named/session.key";
    managed-keys-directory "/run/named";
    listen-on port 53 { any; };
    listen-on-v6 port 53 { any; };
    allow-query { any; };
    recursion no;
    dnssec-validation no;
    notify no;
    // Registrar data must not be able to stop the zone from loading.
    check-names master ignore;
    check-integrity no;
};

include "$RNDC_KEY";
controls {
    inet * port 953 allow { any; } keys { "rndc-key"; };
};

zone "$REGISTRY_TLD" {
    type master;
    file "named.$REGISTRY_TLD.zone";
};
CONF
  exec /usr/sbin/named -g -u named -c /etc/named.conf
}

case "${1:-apache}" in
  apache) start_apache ;;
  cron) start_cron ;;
  nameserver) start_nameserver ;;
  *) echo "Unknown role: $1 (expected apache, cron or nameserver)" >&2; exit 1 ;;
esac
