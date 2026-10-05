#!/bin/sh
# [SETUP] adds the "JupyterHub User" role to the running D2E (bundled plugins in d2e-trex), idempotent
#   sh d2e-patch/apply.sh            # patch usermgmt + portal UI, add the JUPYTER_USER group
#   sh d2e-patch/apply.sh --revert   # put the original files back (the group row stays)
#
# The running D2E (d2e CLI, ghcr.io/ohdsi/d2e-trex image) serves the plugins bundled in the image,
# not this repository's plugins/ sources, so the same change made in plugins/ (branch feature/MIM-7-pr)
# is applied here to the bundled copies:
#   usermgmt  alp-usermgmt.patch: role JUPYTER_USER <-> Logto role role.jupyteruser (scope role.jupyteruser)
#   portal    "JupyterHub User" checkbox in System Admin > Users > Edit roles, and in the role column
# Recreating the d2e-trex container (d2e stop/start with a new container) drops the patch; rerun run.sh.
set -eu
cd "$(dirname "$0")"
here="$(pwd)"

TREX=d2e-trex                                                  # D2E container serving functions + UI
FN=/usr/src/bundled-plugins/d2e-functions/alp-usermgmt          # bundled usermgmt function
UI=/usr/src/bundled-plugins/d2e-ui/resources/portal             # built portal UI
KEEP=/usr/src/poc-jupyter-orig          # originals, for --revert
MAIN=main.2576bc4f.js                    # bundle names of the d2e-trex 0.17.0-beta image
CHUNK=9103.17637b43.chunk.js
MAIN_NEW=main.2576bc4j.js                # new names, so browsers do not keep the cached originals
CHUNK_NEW=9103.17637b4j.chunk.js
FILES="src/const.ts src/routes/AlpUserRouter.ts src/services/roles/index.ts deno.json index.eszip"  # changed by the patch
NEW_FILE=src/services/roles/JupyterUserService.ts               # added by the patch
GROUP_ID=720ad194-fdf3-4d72-b58a-b60d06bd2c91   # same id as plugins/functions/alp-usermgmt-init seed
restart=""                                                      # set when d2e-trex must reload the bundle

tmp="$(mktemp -d)"  # host-side work dir: copy out, patch, copy back
trap 'rm -rf "$tmp"' EXIT

# trex loads each function from its prebuilt index.eszip; restart so the new bundle is used
restart_trex() {
  echo "restarting $TREX (about a minute)"
  docker restart "$TREX" >/dev/null
  i=0
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$TREX")" = healthy ]; do
    i=$((i + 1)); [ $i -lt 120 ] || { echo "$TREX did not become healthy" >&2; exit 1; }
    sleep 3
  done
}

if [ "${1:-}" = "--revert" ]; then
  docker exec "$TREX" sh -c "test -d $KEEP" || { echo "nothing to revert"; exit 0; }
  docker exec "$TREX" sh -c "
    for f in $FILES; do cp $KEEP/usermgmt/\$(basename \$f) $FN/\$f; done
    rm -f $FN/$NEW_FILE
    cp $KEEP/index.html $UI/index.html
    rm -f $UI/static/js/$MAIN_NEW $UI/static/js/$CHUNK_NEW
    rm -rf $KEEP"
  restart_trex
  echo "D2E patch reverted"
  exit 0
fi

# 1. usermgmt: patch the bundled sources, rebuild the function's eszip
mark="$KEEP/usermgmt.$(shasum -a 256 "$here/alp-usermgmt.patch" | cut -c1-12)"
if docker exec "$TREX" test -f "$mark"; then
  echo "usermgmt: already patched"
else
  # keep the image's originals once; every (re)patch starts from them
  docker exec "$TREX" sh -c "mkdir -p $KEEP/usermgmt
    for f in $FILES; do [ -f $KEEP/usermgmt/\$(basename \$f) ] || cp $FN/\$f $KEEP/usermgmt/; done"
  for f in $FILES; do
    [ "$f" = index.eszip ] && continue
    mkdir -p "$tmp/alp-usermgmt/$(dirname "$f")"
    docker cp "$TREX:$KEEP/usermgmt/$(basename "$f")" "$tmp/alp-usermgmt/$f"
  done
  (cd "$tmp" && patch -s -p1 < "$here/alp-usermgmt.patch")
  for f in $FILES $NEW_FILE; do
    [ "$f" = index.eszip ] && continue
    docker cp "$tmp/alp-usermgmt/$f" "$TREX:$FN/$f"
  done
  docker exec -w "$FN" "$TREX" sh -c \
    "/usr/src/node_modules/@trex/cli/bin/trex bundle -e index.ts -o /tmp/usermgmt.eszip >/tmp/usermgmt-bundle.log 2>&1" \
    || { docker exec "$TREX" tail -5 /tmp/usermgmt-bundle.log >&2; echo "usermgmt: bundle failed" >&2; exit 1; }
  docker exec "$TREX" sh -c "mv /tmp/usermgmt.eszip $FN/index.eszip && rm -f $KEEP/usermgmt.* && touch $mark"
  restart=1
  echo "usermgmt: patched and rebundled"
fi

# 2. the usermgmt group the role is stored in (system role, no tenant)
docker exec d2e-minerva-postgres-1 psql -X -q -U postgres -d alp -c "
  insert into usermgmt.b2c_group (id, role, system, created_by, modified_by, modified_date)
  select '$GROUP_ID', 'JUPYTER_USER', system, 'pg18-poc', 'pg18-poc', now()
  from usermgmt.b2c_group where role = 'ALP_DASHBOARD_VIEWER' and tenant_id is null
  and not exists (select 1 from usermgmt.b2c_group where role = 'JUPYTER_USER')
  limit 1"

# 3. portal UI
if docker exec "$TREX" test -f "$UI/static/js/$MAIN_NEW"; then
  echo "portal UI: already patched"
else
  docker exec "$TREX" test -f "$UI/static/js/$MAIN" \
    || { echo "portal UI: $MAIN not found; this patch is for d2e-trex 0.17.0-beta" >&2; exit 1; }
  docker cp "$TREX:$UI/static/js/$MAIN" "$tmp/main.js"
  docker cp "$TREX:$UI/static/js/$CHUNK" "$tmp/chunk.js"
  docker cp "$TREX:$UI/index.html" "$tmp/index.html"
  docker exec "$TREX" sh -c "mkdir -p $KEEP && cp $UI/index.html $KEEP/index.html"
  python3 - "$tmp" "$MAIN" "$MAIN_NEW" <<'PY'
import sys
tmp, main, main_new = sys.argv[1:]
def sub(name, old, new):
    path = f"{tmp}/{name}"
    s = open(path).read()
    if s.count(old) != 1:
        sys.exit(f"portal UI: expected one {old!r} in {name}")
    open(path, "w").write(s.replace(old, new))
# ALP_ROLES (config/index.ts): the Edit roles dialog renders one checkbox per key
sub("main.js", '[u]:"Dashboard Viewer",', '[u]:"Dashboard Viewer",JUPYTER_USER:"JupyterHub User",')
# load the renamed SystemAdmin chunk
sub("main.js", '9103:"17637b43"', '9103:"17637b4j"')
# UserOverview.tsx: show the role in the users table
sub("chunk.js", "e.includes(_.Qq)&&s.push(_.s4[_.Qq]),",
    'e.includes(_.Qq)&&s.push(_.s4[_.Qq]),e.includes("JUPYTER_USER")&&s.push(_.s4.JUPYTER_USER),')
sub("index.html", main, main_new)
PY
  docker cp "$tmp/main.js" "$TREX:$UI/static/js/$MAIN_NEW"
  docker cp "$tmp/chunk.js" "$TREX:$UI/static/js/$CHUNK_NEW"
  docker cp "$tmp/index.html" "$TREX:$UI/index.html"
  echo "portal UI: patched"
fi

[ -z "$restart" ] || restart_trex
