#!/bin/sh
# [FLOW-5] every SYNC_INTERVAL s: D2E postgres datasets -> read-only mirror in PG18 + login role role.researcher.<dataset id>
# Runs in the pg18-sync container (postgres:18-alpine), next to pg18, through pg18's unix socket.
#
# Who may log in as role.researcher.<id> is NOT decided here: the D2E admin grants the user the
# Researcher role on the dataset in the portal (System Admin > Datasets > Permissions). usermgmt puts
# role.researcher.<id> on the user's Logto role, the token carries it in `roles`, and the patched
# validator (validator/d2e-roles.patch) lets the token log in only as a role listed there.
# This script only makes sure that, per dataset, the role exists and can SELECT the dataset schema.
#
# env:
#   MINERVA_URL               D2E metadata DB (portal.dataset, trex.db)
#   SOURCE_<DATABASE_CODE>    admin URL of the dataset's source DB, e.g. SOURCE_DEMO_DATABASE;
#                             used only to create the read-only reader role there
#   JUPYTER_READER_PASSWORD   password of that reader role (d2e_jupyter_reader); PG18's FDW uses it
#   CATALOG_HOST/PORT         how notebooks reach PG18 (written into the catalog)
set -u
export PGOPTIONS="-c client_min_messages=warning"
: "${MINERVA_URL:?}" "${JUPYTER_READER_PASSWORD:?}"
CATALOG=/catalog/datasets.json
READER=d2e_jupyter_reader
INTERVAL="${SYNC_INTERVAL:-15}"
pg18() { psql -X -q -v ON_ERROR_STOP=1 -h /var/run/postgresql -U postgres "$@"; }

log() { echo "$(date -u +%FT%TZ) $*"; }

# one line per D2E postgres dataset: id|code|database_code|schema|vocab schema|source host|port|db
datasets() {
  psql -X -At -F '|' -v ON_ERROR_STOP=1 "$MINERVA_URL" -c "
    select d.id, d.token_dataset_code, d.database_code, d.schema_name,
           coalesce(nullif(d.vocab_schema_name, ''), d.schema_name), db.host, db.port, db.name
    from portal.dataset d
    join trex.db db on db.id = d.database_code
    where d.dialect = 'postgres' and db.dialect = 'postgres' and coalesce(d.schema_name, '') <> ''
    order by d.id"
}

# source DB: a login role that can only read the dataset schemas
grant_reader_on_source() { # admin_url schema vocab
  psql -X -q -v ON_ERROR_STOP=1 "$1" -v pw="$JUPYTER_READER_PASSWORD" -v s="$2" -v v="$3" <<'SQL'
select set_config('d2e.pw', :'pw', false), set_config('d2e.s', :'s', false), set_config('d2e.v', :'v', false) \g /dev/null
DO $$
DECLARE
  r text := 'd2e_jupyter_reader';
  s text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
    EXECUTE format('CREATE ROLE %I LOGIN', r);
  END IF;
  EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
                 r, current_setting('d2e.pw'));
  EXECUTE format('ALTER ROLE %I SET default_transaction_read_only = on', r);
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), r);
  FOR s IN SELECT DISTINCT unnest(ARRAY[current_setting('d2e.s'), current_setting('d2e.v')]) LOOP
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, r);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, r);
  END LOOP;
END $$;
SQL
}

# PG18: database <database_code>, FDW to the source, schema mirror, role with SELECT only
mirror_in_pg18() { # id code database_code schema vocab host port dbname
  pg18 -d postgres -v db="$3" <<'SQL' || return 1
select format('CREATE DATABASE %I', :'db') where not exists (select 1 from pg_database where datname = :'db') \gexec
select format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db') \gexec
REVOKE ALL ON DATABASE postgres FROM PUBLIC;
SQL
  pg18 -d "$3" -v id="$1" -v code="$2" -v s="$4" -v v="$5" -v host="$6" -v port="$7" -v dbname="$8" \
    -v pw="$JUPYTER_READER_PASSWORD" <<'SQL'
select set_config('d2e.id', :'id', false), set_config('d2e.code', :'code', false),
       set_config('d2e.s', :'s', false), set_config('d2e.v', :'v', false),
       set_config('d2e.host', :'host', false), set_config('d2e.port', :'port', false),
       set_config('d2e.dbname', :'dbname', false), set_config('d2e.pw', :'pw', false) \g /dev/null
DO $$
DECLARE
  role text := 'role.researcher.' || current_setting('d2e.id');
  s text;
  existing text;
BEGIN
  CREATE EXTENSION IF NOT EXISTS postgres_fdw;
  REVOKE ALL ON SCHEMA public FROM PUBLIC;

  IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'd2e_source') THEN
    EXECUTE format('CREATE SERVER d2e_source FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L)',
                   current_setting('d2e.host'), current_setting('d2e.port'), current_setting('d2e.dbname'));
  END IF;
  -- every PG18 role reads the source as the read-only reader; what it may read is decided by the GRANTs below
  IF NOT EXISTS (SELECT 1 FROM pg_user_mappings WHERE srvname = 'd2e_source' AND usename = 'public') THEN
    EXECUTE format('CREATE USER MAPPING FOR PUBLIC SERVER d2e_source OPTIONS (user %L, password %L)',
                   'd2e_jupyter_reader', current_setting('d2e.pw'));
  ELSE
    EXECUTE format('ALTER USER MAPPING FOR PUBLIC SERVER d2e_source OPTIONS (SET password %L)', current_setting('d2e.pw'));
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role) THEN
    EXECUTE format('CREATE ROLE %I LOGIN', role);
  END IF;
  EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', role);
  EXECUTE format('ALTER ROLE %I SET default_transaction_read_only = on', role);
  EXECUTE format('COMMENT ON ROLE %I IS %L', role, 'D2E dataset ' || current_setting('d2e.code'));
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), role);

  FOR s IN SELECT DISTINCT unnest(ARRAY[current_setting('d2e.s'), current_setting('d2e.v')]) LOOP
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', s);
    -- add source tables the mirror does not have yet
    SELECT string_agg(format('%I', c.relname), ', ') INTO existing
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = s AND c.relkind = 'f';
    EXECUTE format('IMPORT FOREIGN SCHEMA %I %s FROM SERVER d2e_source INTO %I', s,
                   CASE WHEN existing IS NULL THEN '' ELSE 'EXCEPT (' || existing || ')' END, s);
    EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, role);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, role);
  END LOOP;
END $$;
SQL
}

# what the hub hands to notebooks: the mirrored datasets, filtered per user by the token's roles
write_catalog() { # comma-separated dataset ids
  psql -X -At -v ON_ERROR_STOP=1 "$MINERVA_URL" -v ids="$1" \
    -v host="${CATALOG_HOST:-pg18d2e-pg18}" -v port="${CATALOG_PORT:-5432}" <<'SQL' > "$CATALOG.tmp" || return 1
select coalesce(json_agg(json_build_object(
         'id', d.id, 'tokenDatasetCode', d.token_dataset_code,
         'name', coalesce(dd.name, d.token_dataset_code), 'databaseCode', d.database_code,
         'host', :'host', 'port', :'port', 'database', d.database_code,
         'schema', d.schema_name, 'vocabSchema', coalesce(nullif(d.vocab_schema_name, ''), d.schema_name),
         'postgresRole', 'role.researcher.' || d.id) order by d.token_dataset_code), '[]')
from portal.dataset d left join portal.dataset_detail dd on dd.dataset_id = d.id
where d.id::text = any(string_to_array(:'ids', ','))
SQL
  mv "$CATALOG.tmp" "$CATALOG"
}

sync_once() {
  rows="$(datasets)" || { log "cannot read D2E datasets"; return; }
  synced=""
  old_ifs="$IFS"; IFS='
'
  for row in $rows; do
    IFS='|' read -r id code dbcode schema vocab host port dbname <<EOF
$row
EOF
    var="SOURCE_$(printf '%s' "$dbcode" | tr 'a-z' 'A-Z' | tr -c 'A-Z0-9' '_')"
    eval "admin=\${$var:-}"
    if [ -z "$admin" ]; then
      log "skip dataset $code: no $var (source database $dbcode)"; continue
    fi
    grant_reader_on_source "$admin" "$schema" "$vocab" || { log "dataset $code: source grant failed"; continue; }
    mirror_in_pg18 "$id" "$code" "$dbcode" "$schema" "$vocab" "$host" "$port" "$dbname" \
      || { log "dataset $code: PG18 mirror failed"; continue; }
    synced="${synced:+$synced,}$id"
  done
  IFS="$old_ifs"
  before="$(cat "$CATALOG" 2>/dev/null || true)"
  write_catalog "$synced" || { log "cannot write catalog"; return; }
  [ "$before" = "$(cat "$CATALOG")" ] || log "catalog: $(cat "$CATALOG")"
}

until pg_isready -q -h /var/run/postgresql -U postgres; do sleep 1; done
while :; do
  sync_once
  [ "${1:-}" = "--once" ] && exit 0
  sleep "$INTERVAL"
done
