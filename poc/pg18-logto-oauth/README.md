# PoC: D2E → JupyterHub → PostgreSQL 18 (OAuth)

A D2E admin gives a user two things in the D2E portal:

| Portal grant | Lets the user |
| --- | --- |
| **JupyterHub User** (System Admin > Users > Edit roles) | log in to JupyterHub at `http://localhost:8000` |
| **Researcher** on a dataset (System Admin > Datasets > Permissions) | `SELECT` that dataset from a notebook, read-only |

There are no database passwords. The notebook logs in to PostgreSQL 18 with the user's D2E
(Logto) access token, and PG18 only allows the dataset roles listed in that token.

| Doc | For |
| --- | --- |
| **README.md** | what it is, how to run it, troubleshooting |
| [Jupyter.md](Jupyter.md) | step-by-step test: admin grants, then notebook cells |
| [ARCHITECTURE.md](ARCHITECTURE.md) | containers, runtime flow, security, file map |
| [D2E-PERMISSIONS.md](D2E-PERMISSIONS.md) | how D2E permissions map onto PostgreSQL, open issues |

## Quick start

D2E must be running (`d2e start`). Then:

```sh
cd poc/pg18-logto-oauth
sh run.sh              # set up + start; safe to rerun
```

1. Go to `https://localhost/sign-in` and sign in as `admin`. Add a user, tick **JupyterHub User**,
   and give them **Researcher** on *Demo dataset*.
2. In a private window, open `http://localhost:8000`, click **Sign in with Data2Evidence**, and sign
   in as that user.
3. In a notebook:

```python
import pg_oauth
conn = pg_oauth.connect("demo")
conn.execute("select count(*) from demo_cdm.person").fetchone()   # (2694,)
conn.execute("drop table demo_cdm.person")                         # denied
```

The full test with expected results is in [Jupyter.md](Jupyter.md).

## What `run.sh` does

| Step | Script | Result |
| --- | --- | --- |
| 1 | `d2e-patch/apply.sh` | adds **JupyterHub User** to the running D2E (usermgmt + portal UI); restarts `d2e-trex` only when it changes something |
| 2 | `d2e-patch/repair-logto-users.sh` | re-links D2E users whose Logto account was recreated (fixes the sign-in loop) |
| 3 | `logto_setup.py` | Logto app `jupyterhub-pg18-poc` + role `role.jupyteruser`; secrets → `.env.poc` (gitignored) |
| 4 | `docker build` | `validator/out/pg_oidc_validator.so`, image `pgoauth-notebook:local` |
| 5 | `docker compose up` | `pg18d2e-pg18`, `pg18d2e-sync`, `pg18d2e-jupyterhub` |

`sh run.sh --remove` stops the PoC, deletes the hub app and reverts the D2E patch. Users you
created in the portal stay.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `https://localhost/sign-in` keeps reloading | The browser holds a Logto session of a user D2E does not know, or the D2E user's Logto link broke. Run `sh run.sh` (it runs the repair script), then clear the `localhost` cookies or use a private window |
| admin password unknown | It is stored only as a hash. Reset it with Logto's management API (`PATCH /api/users/<id>/password`, see ARCHITECTURE.md §6) |
| Hub says 403 | The user has no **JupyterHub User**. If the portal is open in the same window, the hub signs in as that portal user (e.g. admin), so use a private window |
| `pg_oauth.datasets()` is `[]` | No **Researcher** grant, or it was given after the server started. Use File > Hub Control Panel > Stop + Start |
| `connect()`: token expired | Tokens last 1 hour. Restart the server from the Hub Control Panel |
| UI has no "JupyterHub User" | `d2e-trex` was recreated (new image or reinstall). Rerun `sh run.sh` |

## Verified (2026-10-05, D2E 0.17.0-beta, postgres 18.6)

- Grants made in the portal show up in the token's `roles`. Revoking a grant removes it from the next token.
- With both grants, `SELECT` works. DROP, DELETE, UPDATE, INSERT, ALTER, GRANT and every kind of
  CREATE are denied, including after `SET default_transaction_read_only = off`.
- Logging in as another dataset's role or as `postgres` is denied. A user without
  **JupyterHub User** gets a hub 403.
- PG18 records the real user: `system_user = oauth:<logto user id>`.
