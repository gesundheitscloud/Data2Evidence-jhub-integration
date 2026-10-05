# PG18 OAuth PoC: architecture, build order, testing

← [README.md](README.md) (overview, one-command run, results) ·
notebook cells: [Jupyter.md](Jupyter.md) ·
D2E integration: [D2E-PERMISSIONS.md](D2E-PERMISSIONS.md)

Goal: a D2E admin grants, in the D2E portal, (1) JupyterHub access and (2) read access to a
dataset. The user then logs in to JupyterHub with D2E's Logto, and the same Logto access token
logs them in to PostgreSQL 18, where they can only SELECT the datasets they were granted.

Every code file starts with a one-line header tag. The tags match the sections below:
`[BUILD-n]`, `[SETUP]`, `[RUN]`, `[FLOW-n]`.

## 1. Architecture

```text
                      ┌──────────── D2E stack (already running) ─────────────────────┐
browser ── https://localhost ──> d2e-caddy ──> d2e-trex (portal UI + usermgmt, patched)│
   │   (admin grants roles)            │        └─ writes Logto roles ─> d2e-logto-1   │
   │                                   │           d2e-caddy:8080/oidc = issuer + JWKS │
   │                                   │  d2e-minerva-postgres-1 (portal.dataset, ...) │
   │                                   │  d2e-demodb (dataset source, PG16)            │
   │                      └────────────▲──────────────────▲──────────────▲────────────┘
   │                       d2e_alp     │ token exchange   │ JWKS         │ FDW (read-only user)
   └── http://localhost:8000 ──> pg18d2e-jupyterhub      │              │
                                    │ [FLOW-1] notebook   │   pg18d2e-sync [FLOW-5]
            pg18d2e-notebooks (internal, no internet)     │      │ mirror + role per dataset
                                    ▼                     │      ▼
                             jupyter-<user> ──[FLOW-2] token──> pg18d2e-pg18 [FLOW-3..4]
```

| Container | Image | What it does |
| --- | --- | --- |
| `d2e-trex` | D2E's own, **patched** by `d2e-patch/apply.sh` | portal UI shows a "JupyterHub User" role; usermgmt stores it and gives the user the Logto role `role.jupyteruser` |
| `d2e-logto-1` | D2E's own | Logs users in; JWT access tokens carry all the user's role scopes in the `roles` claim |
| `pg18d2e-jupyterhub` | built from `hub/` | Logto login, gate on `role.jupyteruser`, starts one notebook per user with the token and the user's granted datasets |
| `jupyter-<user>` | `pgoauth-notebook:local` | `pg_oauth.connect("demo")` logs in to PostgreSQL with the token |
| `pg18d2e-pg18` | official `postgres:18-alpine` | Verifies the token with the mounted, patched validator; per dataset a read-only mirror |
| `pg18d2e-sync` | official `postgres:18-alpine` | `sync/sync.sh` every 15 s: one database, FDW schema mirror and login role per D2E postgres dataset |

## 2. Runtime flow

What the admin does in the D2E portal (`https://localhost/sign-in`, user `admin`):

| Portal action | usermgmt writes | Logto role (scope in the token's `roles`) | Effect |
| --- | --- | --- | --- |
| System Admin > Users > Edit roles > **JupyterHub User** | group `JUPYTER_USER` | `role.jupyteruser` | may log in to JupyterHub |
| System Admin > Datasets > *dataset* > Permissions > **Researcher** | group `RESEARCHER` of that dataset | `role.researcher.<code>` (scopes `role.researcher.<code>`, `role.researcher.<dataset id>`) | may log in to PG18 as `role.researcher.<dataset id>` |

Then, for the user:

| Step | File | What happens |
| --- | --- | --- |
| FLOW-1 | `hub/jupyterhub_config.py` | Browser goes to Logto, comes back with a code; the hub exchanges it for tokens (`resource=https://alp-default`). Without `role.jupyteruser` in the token's `roles` the hub answers 403. At server start the hub refreshes the token, puts it in the notebook as `LOGTO_ACCESS_TOKEN`, and passes the catalog entries whose `postgresRole` is in the token as `D2E_JUPYTER_DATASETS` |
| FLOW-2 | `notebook/pg_oauth.py` | `connect(dataset)` picks the dataset's role `role.researcher.<id>` and gives the token to libpq 18 through `PQsetAuthDataHook` (no Python driver supports PG18 OAuth yet) |
| FLOW-3 | `pg18/pg_hba.conf` | One rule: user `/^role\.researcher\.`, method `oauth`, issuer `http://d2e-caddy:8080/oidc`, `scope=""`, `delegate_ident_mapping=1` |
| FLOW-4 | `validator/d2e-roles.patch` | The validator checks signature, issuer, expiry and audience `https://alp-default`, then authorizes only if the requested role starts with `role.researcher.` and is listed in the token's `roles` claim. The identity stays the token `sub` (`system_user = oauth:<logto user id>`) |
| FLOW-5 | `sync/sync.sh` | Per D2E postgres dataset: in the source DB a login `d2e_jupyter_reader` with only `SELECT` on the dataset schemas; in PG18 a database `<database_code>`, `postgres_fdw` server, the schema imported as foreign tables, and the role `role.researcher.<dataset id>` with only `CONNECT`, `USAGE`, `SELECT` (and `default_transaction_read_only=on`). Writes `/catalog/datasets.json` for the hub |

Read-only is enforced twice: the PG18 role has no write, create, temp or ownership
privilege, and the FDW reads the source as a user that can only `SELECT`.

## 3. Build and run order

Prerequisite: D2E is running (`d2e start`). From `poc/pg18-logto-oauth/`:

| Order | Step | Command | Produces |
| --- | --- | --- | --- |
| 1 | SETUP D2E patch | `sh d2e-patch/apply.sh` (by `run.sh`) | patched usermgmt eszip + portal UI in `d2e-trex`, group `JUPYTER_USER`; restarts `d2e-trex` once |
| 2 | SETUP D2E users | `sh d2e-patch/repair-logto-users.sh` (by `run.sh`) | usermgmt users re-linked to their Logto user and given the Logto roles of their groups |
| 3 | SETUP D2E Logto | `logto_setup.py` (by `run.sh`) | role/scope `role.jupyteruser`, hub app; `.env.poc` |
| 4 | BUILD-1 validator | `docker build --output validator/out validator` | `validator/out/pg_oidc_validator.so` (rebuilt when the patch changes) |
| 5 | BUILD-2 notebook image | `docker build -t pgoauth-notebook:local notebook` | image `pgoauth-notebook:local` |
| 6 | BUILD-3 hub + RUN | `docker compose up -d --build` (by `run.sh`) | `pg18d2e-pg18`, `pg18d2e-sync`, `pg18d2e-jupyterhub` |

`sh run.sh` runs all of it and can be rerun. The D2E patch lives in the `d2e-trex` container's
filesystem: if the container is recreated (new image, `d2e` reinstall), rerun `run.sh`.
The patch targets the `0.17.0-beta` bundle names and stops with a message on any other build.

The validator `.so` must match PostgreSQL 18, musl (Alpine) and the CPU architecture; build
it on the machine that runs it.

## 4. How to test, from zero

1. **Start.** `sh run.sh`.
2. **Admin.** Open `https://localhost/sign-in` (accept the certificate), sign in as `admin`.
   - System Admin > Users > **Add user**: `alice`, a password.
   - alice > Edit roles > tick **JupyterHub User** > Save. The role column shows it.
   - System Admin > Datasets > *Demo dataset* > Permissions: give alice **Researcher**.
   - Add `bob` with no roles.
3. **User.** In a private window open `http://localhost:8000` > **Sign in with Data2Evidence**,
   sign in as alice. Her server starts.
4. **Query in a notebook** (more in [Jupyter.md](Jupyter.md)):

```python
import pg_oauth
pg_oauth.datasets()                     # [{'tokenDatasetCode': 'demo', ...}]
conn = pg_oauth.connect("demo")         # logs in as role.researcher.<demo id>
conn.execute("select count(*) from demo_cdm.person").fetchone()   # (2694,)
conn.execute("drop table demo_cdm.person")   # denied
conn.execute("select system_user, current_user").fetchone()  # ('oauth:<alice id>', 'role.researcher.<demo id>')
```

5. **bob** gets a JupyterHub 403. Give him JupyterHub User but no dataset: he logs in,
   `pg_oauth.datasets()` is empty, and connecting as the demo role is refused by PG18.
6. **Revoke.** Remove alice's Researcher permission: after her next token (server restart,
   at most one hour), the demo role is gone from her token and PG18 refuses her.

Grants are read when the token is issued: after a change, restart the notebook server
(File > Hub Control Panel > Stop/Start) or log in to the hub again.

On the PostgreSQL side:

```sh
docker exec pg18d2e-pg18 psql -U postgres -c "select * from pg_hba_file_rules"
docker logs pg18d2e-pg18 | grep -E 'method=oauth|Authorization failed'
docker logs pg18d2e-sync        # one line per catalog change
```

## 5. File map

| Tag | Files |
| --- | --- |
| BUILD | `validator/Dockerfile` (+ `validator/d2e-roles.patch`), `notebook/Dockerfile`, `hub/Dockerfile` |
| SETUP | `d2e-patch/apply.sh` (+ `d2e-patch/alp-usermgmt.patch`), `d2e-patch/repair-logto-users.sh`, `logto_setup.py` |
| RUN | `run.sh`, `docker-compose.yml` |
| FLOW | `hub/jupyterhub_config.py`, `notebook/pg_oauth.py`, `pg18/pg_hba.conf`, `validator/d2e-roles.patch`, `sync/sync.sh` |
| Browser test | [Jupyter.md](Jupyter.md) (cells to paste in a notebook) |
| Docs | [README.md](README.md), [D2E-PERMISSIONS.md](D2E-PERMISSIONS.md), [ARCHITECTURE-ko.md](ARCHITECTURE-ko.md) |
