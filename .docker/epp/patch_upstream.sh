#!/bin/bash
# Build-time patches to the upstream EPP sources. The new settings are read from
# /etc/registry/registry.conf, which the entrypoint renders at container start.
set -euo pipefail

write_zone=/var/www/cgi-bin/epp/cron/write-zone.pl
transfer=/var/www/cgi-bin/epp/command/command-transfer.cgi
create=/var/www/cgi-bin/epp/command/command-create.cgi
writer=/var/www/cgi-bin/epp/lib/EPP/EPPWriter.pm

# write-zone.pl: use our NS names, and reload the nameserver container (no systemd here).
# Choose A or AAAA from the address itself: the ip column is empty on rows written by
# the unpatched host create, and a single bad record stops the whole zone from loading.
sed -i \
  -e "s/^my \$ns1 = .*/my \$ns1 = \$c{'zone_ns1'};/" \
  -e "s/^my \$ns2 = .*/my \$ns2 = \$c{'zone_ns2'};/" \
  -e 's#systemctl reload named.service#/usr/sbin/rndc -s nameserver -k /var/named/rndc.key reload >/dev/null#' \
  -e "s/if (\$type eq 'v4') {/if (\$addr !~ m{:}) {/" \
  "$write_zone"

# command-transfer.cgi: make the 60-day lock and the 5-day waiting period configurable.
sed -i -E \
  -e "s/(\\\$days_from_(registration|last_transfer)) < 60/\1 < \$c{'transfer_lock_days'}/" \
  -e "s/my \\\$waiting_period = 5; # days/my \$waiting_period = \$c{'transfer_waiting_minutes'}; # minutes/" \
  -e 's/INTERVAL \$waiting_period DAY/INTERVAL $waiting_period MINUTE/g' \
  "$transfer"

# command-create.cgi: stop turning 'v4' into '4', which MariaDB stores as an empty enum.
sed -i '/\$addr_type =~ s\/\\D\/\/g;/d' "$create"

# EPPWriter.pm: host:info printed 'v' . ip, giving ip="vv4", or ip="v" on rows left empty
# by the bug above. Derive the attribute from the address, which is right for both.
sed -i "s/'ip' => 'v' \. \${\$a}\[0\]/'ip' => (\${\$a}[1] =~ m{:} ? 'v6' : 'v4')/" "$writer"

# Fail the build if an upstream change made any of the patterns above miss.
if grep -qE "xpanel\.net|systemctl|type eq 'v4'" "$write_zone" ||
   grep -q 'addr_type =~' "$create" ||
   grep -q "'ip' => 'v'" "$writer" ||
   grep -qE '_(registration|transfer) < 60|waiting_period = 5|\$waiting_period DAY' "$transfer"; then
  echo "patch_upstream.sh: upstream sources no longer match the expected patterns" >&2
  exit 1
fi
