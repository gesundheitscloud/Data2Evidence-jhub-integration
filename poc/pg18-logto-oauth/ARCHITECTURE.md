# Architecture

← [README.md](README.md) · test: [Jupyter.md](Jupyter.md)

## 1. Containers

```text
admin ─ https://localhost/sign-in ─> d2e-caddy ─> d2e-trex (portal UI + usermgmt, patched)
                                                     │ writes Logto roles
                                                     ▼
                                                  d2e-logto-1 ── issuer + JWKS at d2e-caddy:8080/oidc
                                                     ▲                     ▲
user ── http://localhost:8000 ─> pg18d2e-jupyterhub ─┘ login/refresh       │ verify token
                                    │ spawn                                │
                                    ▼                                      │
                       jupyter-<user> ──── token ────> pg18d2e-pg18 ───────┘
                       (internal network)                 │ postgres_fdw, read-only user
                                                          ▼
                       pg18d2e-sync ── reads D2E datasets  d2e-demodb (PG16, dataset source)
```

| Container | Image | Role |
| --- | --- | --- |
| `d2e-trex` | D2E's, patched by `d2e-patch/apply.sh` | Portal UI shows **JupyterHub User**; usermgmt stores it as group `JUPYTER_USER` and gives the Logto role `role.jupyteruser` |
| `d2e-logto-1` | D2E's | Login. Access tokens carry every scope of the user's roles in the `roles` claim |
| `pg18d2e-jupyterhub` | `hub/` | Logto login, lets in only `role.jupyteruser`, starts one notebook per user |
| `jupyter-<user>` | `notebook/` → `pgoauth-notebook:local` | `pg_oauth.connect()` logs in to PG18 with the token |
| `pg18d2e-pg18` | `postgres:18-alpine` + `validator/out/pg_oidc_validator.so` | Accepts only D2E tokens, only as roles listed in the token |
| `pg18d2e-sync` | `postgres:18-alpine` + `sync/sync.sh` | Every 15 s, creates one database, a read-only mirror and a role per D2E postgres dataset |

## 2. What a portal grant becomes

| Portal grant | usermgmt group | Logto role | Scopes in token `roles` | Used by |
| --- | --- | --- | --- | --- |
| JupyterHub User | `JUPYTER_USER` | `role.jupyteruser` | `role.jupyteruser` | hub gate (`LOGTO_ALLOWED_ROLE`) |
| Researcher on dataset X | `RESEARCHER` + dataset X | `role.researcher.<code>` | `role.researcher.<code>`, `role.researcher.<X id>` | PG18 login as `role.researcher.<X id>` |

## 3. Runtime flow

| Step | File | What happens |
| --- | --- | --- |
| FLOW-1 | `hub/jupyterhub_config.py` | The user logs in through Logto. The hub requires `role.jupyteruser` in the token's `roles`. At server start it refreshes the token and passes `LOGTO_ACCESS_TOKEN` and `D2E_JUPYTER_DATASETS` (the catalog entries whose role is in the token) |
| FLOW-2 | `notebook/pg_oauth.py` | `connect(dataset)` logs in as `role.researcher.<id>` and hands the token to libpq 18 via `PQsetAuthDataHook` |
| FLOW-3 | `pg18/pg_hba.conf` | One rule for every dataset: user `/^role\.researcher\.`, `oauth`, `scope=""`, `delegate_ident_mapping=1` |
| FLOW-4 | `validator/d2e-roles.patch` | The validator checks signature, issuer, expiry and audience `https://alp-default`. The requested role must start with `role.researcher.` and be in the token's `roles`. The identity stays the token `sub` |
| FLOW-5 | `sync/sync.sh` | For each dataset: a source reader `d2e_jupyter_reader` (SELECT only), a PG18 database `<database_code>`, an FDW mirror of the schema, the role `role.researcher.<id>` (CONNECT/USAGE/SELECT only), and `/catalog/datasets.json` |

## 4. Why it is read-only

1. **PG18 privileges.** The role has only `CONNECT`, `USAGE` and `SELECT`: it owns nothing and
   cannot CREATE, use TEMP or write.
2. **Read-only default.** `default_transaction_read_only=on` is set on the role, as a guard rail
   only, because the user can switch it off.
3. **Source user.** The FDW reads the source as `d2e_jupyter_reader`, which can only `SELECT`.
4. **Login.** A token can log in only as the dataset roles in its own `roles` claim. Removing a
   grant takes effect with the next token (at most 1 hour).

## 5. Why the D2E patch exists

The running D2E (d2e CLI, `ghcr.io/ohdsi/d2e-trex:0.17.0-beta`) does not run this repository's
`plugins/`. It loads each function from a prebuilt `index.eszip` and the UI from a built bundle.
`d2e-patch/apply.sh` therefore:

- applies `d2e-patch/alp-usermgmt.patch` to the bundled usermgmt sources (the same change as
  `plugins/functions/alp-usermgmt` on this branch), rebuilds `index.eszip` with `trex bundle`,
  and restarts `d2e-trex`;
- inserts the `usermgmt.b2c_group` row `JUPYTER_USER`;
- adds `JUPYTER_USER: "JupyterHub User"` to the built portal JS under new file names, so
  browsers do not keep the cached old file.

It keeps the originals in the container (`/usr/src/poc-jupyter-orig`) for `--revert`. A new
`d2e-trex` container loses the patch, so rerun `run.sh`.

## 6. Operations

```sh
sh run.sh                         # set up / update (idempotent)
sh run.sh --remove                # tear down the PoC, revert the D2E patch
sh d2e-patch/repair-logto-users.sh    # re-link D2E users to Logto (sign-in loop)
docker exec pg18d2e-sync sh /sync/sync.sh --once   # one sync pass now
```

Reset a Logto password (e.g. `admin`, id from `logto.users`):

```sh
docker run --rm --network d2e_alp -e ID="$(docker exec d2e-logto-1 printenv LOGTO_API_M2M_CLIENT_ID)" \
  -e SECRET="$(docker exec d2e-logto-1 printenv LOGTO_API_M2M_CLIENT_SECRET)" python:3.12-alpine python -c '
import base64,json,os,urllib.request as u,urllib.parse as p
L="http://d2e-logto-1:3001"; b="Basic "+base64.b64encode((os.environ["ID"]+":"+os.environ["SECRET"]).encode()).decode()
t=json.load(u.urlopen(u.Request(L+"/oidc/token",p.urlencode({"grant_type":"client_credentials","resource":"https://default.logto.app/api","scope":"all"}).encode(),{"authorization":b})))["access_token"]
print(u.urlopen(u.Request(L+"/api/users/<USER_ID>/password",json.dumps({"password":"<NEW>"}).encode(),{"authorization":"Bearer "+t,"content-type":"application/json"},method="PATCH")).status)'
```

## 7. File map

| Tag | File | Role |
| --- | --- | --- |
| RUN | `run.sh` | one command: patch D2E, set up Logto, build, start |
| RUN | `docker-compose.yml` | `pg18`, `pg18-sync`, `jupyterhub`; every env value commented |
| SETUP | `d2e-patch/apply.sh` | patch the running D2E (usermgmt eszip, portal UI, group row) |
| SETUP | `d2e-patch/alp-usermgmt.patch` | the usermgmt change, against the bundled 0.17.0-beta sources |
| SETUP | `d2e-patch/repair-logto-users.sh` | re-link usermgmt users to Logto, restore their Logto roles |
| SETUP | `logto_setup.py` | Logto app for the hub + `role.jupyteruser` |
| BUILD-1 | `validator/Dockerfile`, `validator/d2e-roles.patch` | PG18 token validator with the `roles` claim check |
| BUILD-2 | `notebook/Dockerfile` | notebook image: libpq 18 + psycopg + `pg_oauth.py` |
| BUILD-3 | `hub/Dockerfile` | hub image: JupyterHub + DockerSpawner + OAuthenticator |
| FLOW-1 | `hub/jupyterhub_config.py` | hub login gate, token + datasets to the notebook |
| FLOW-2 | `notebook/pg_oauth.py` | `datasets()`, `connect()` in the notebook |
| FLOW-3 | `pg18/pg_hba.conf` | the single oauth rule |
| FLOW-5 | `sync/sync.sh` | dataset mirror + role + catalog |
