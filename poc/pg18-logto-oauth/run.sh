#!/bin/sh
# [RUN] one command: D2E patch + Logto setup -> .env.poc -> build missing files -> start docker-compose.yml
# D2E must be running (d2e CLI). Safe to run again.
#   sh run.sh            # set up and start
#   sh run.sh --remove   # stop, remove the PoC app from D2E Logto, revert the D2E UI/usermgmt patch
set -eu
cd "$(dirname "$0")"

# D2E's Logto management app (M2M); logto_setup.py uses it to create the hub app
export LOGTO_M2M_ID="$(docker exec d2e-logto-1 printenv LOGTO_API_M2M_CLIENT_ID)"
export LOGTO_M2M_SECRET="$(docker exec d2e-logto-1 printenv LOGTO_API_M2M_CLIENT_SECRET)"
# Run logto_setup.py in a throwaway container on d2e_alp (where d2e-logto-1 resolves).
setup() {
  docker run --rm --network d2e_alp -v "$PWD:/w:ro" -e LOGTO_M2M_ID -e LOGTO_M2M_SECRET \
    python:3.12-alpine python /w/logto_setup.py "$@"
}

if [ "${1:-}" = "--remove" ]; then
  docker compose --env-file .env.poc down -v 2>/dev/null || docker compose down -v
  for c in $(docker ps -aq --filter 'name=^jupyter-'); do docker rm -f "$c" >/dev/null; done
  setup --remove
  sh d2e-patch/apply.sh --revert
  rm -f .env.poc
  exit 0
fi

# 1. D2E: "JupyterHub User" role in usermgmt + portal UI; users whose Logto link broke get it back
sh d2e-patch/apply.sh
sh d2e-patch/repair-logto-users.sh >/dev/null

# 2. D2E Logto: hub app -> .env.poc (gitignored), plus what pg18-sync needs to read D2E datasets
umask 077
# Value of KEY from the current .env.poc, so reruns keep the same secrets.
keep() { grep "^$1=" .env.poc 2>/dev/null | cut -d= -f2- || true; }
# POC_HUB_CRYPT_KEY: hub auth_state encryption | POC_JUPYTER_READER_PASSWORD: source DB reader (FDW)
key="$(keep POC_HUB_CRYPT_KEY)"; [ -n "$key" ] || key="$(openssl rand -hex 32)"
reader="$(keep POC_JUPYTER_READER_PASSWORD)"; [ -n "$reader" ] || reader="$(openssl rand -hex 24)"
{
  setup
  echo "POC_HUB_CRYPT_KEY=$key"
  echo "POC_JUPYTER_READER_PASSWORD=$reader"
  # D2E metadata DB for pg18-sync (portal.dataset, trex.db)
  echo "POC_MINERVA_URL=postgres://$(docker exec d2e-trex printenv PG_SUPER_USER):$(docker exec d2e-trex printenv PG_SUPER_PASSWORD)@d2e-minerva-postgres-1:5432/alp"
  # admin URL of D2E's demo database (trex.db code demo_database); only used to create the read-only reader
  echo "POC_SOURCE_DEMO_DATABASE=$(docker exec d2e-trex printenv REP_PG)"
} > .env.poc.new
if ! grep -q '^POC_HUB_CLIENT_ID=' .env.poc.new; then
  rm -f .env.poc.new
  echo "D2E Logto setup failed (no hub client id); see the messages above" >&2
  exit 1
fi
mv .env.poc.new .env.poc

# 3. build what the plain images lack (the validator again whenever its patch changes)
[ validator/out/pg_oidc_validator.so -nt validator/d2e-roles.patch ] || docker build --output validator/out validator
docker build -q -t pgoauth-notebook:local notebook >/dev/null

# 4. start pg18, pg18-sync and the hub
docker compose --env-file .env.poc up -d --build
echo "D2E portal: https://localhost/sign-in (admin) | JupyterHub: http://localhost:8000"
