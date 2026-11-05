#!/usr/bin/env bash
# Regression suite. Starts an isolated stack (project "epptest", no published ports,
# fresh data), runs every test/*.t inside the epp-server container, then removes the stack.
#
#   test/run.sh                 run all tests
#   test/run.sh test/login.t    run the named tests
#   KEEP_STACK=1 test/run.sh    leave the stack up afterwards, for inspection
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Outside the devcontainer the workspace path and the host path are the same
export LOCAL_WORKSPACE_FOLDER="${LOCAL_WORKSPACE_FOLDER:-$root}"

project=epptest
c=(docker compose -p "$project" -f docker-compose.yml -f .devcontainer/docker-compose.test.yml)

teardown() {
	if [ "${KEEP_STACK:-}" = 1 ]; then
		echo "Stack left running. Remove it with: ${c[*]} --profile setup --profile run down -v --rmi local"
	else
		"${c[@]}" --profile setup --profile run down -v --rmi local >/dev/null 2>&1 || true
	fi
}

"${c[@]}" --profile setup --profile run down -v >/dev/null 2>&1 || true
trap teardown EXIT

"${c[@]}" --profile setup --profile run build
"${c[@]}" --profile setup up mariadb_prep
"${c[@]}" --profile setup rm -f mariadb_prep
"${c[@]}" --profile run up -d --wait

if [ "$#" -gt 0 ]; then
	tests=("$@")
else
	tests=(test/*.t)
fi

status=0
for t in "${tests[@]}"; do
	echo "=== $t ==="
	# The client library is prepended so that nothing has to be copied into the image
	cat test/lib/epp_client.pl "$t" | docker exec -i "$project-epp-server-1" perl - || status=1
done

if [ "$status" -ne 0 ]; then
	echo '=== epp-server error_log ==='
	docker exec "$project-epp-server-1" tail -n 20 /var/log/httpd/error_log || true
fi
exit "$status"
