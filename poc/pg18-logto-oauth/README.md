# PoC: D2E Logto ↔ JupyterHub ↔ PostgreSQL 18

A D2E admin grants a user, in the D2E portal, **JupyterHub access** and **Researcher access to a
dataset**. The user logs in to JupyterHub with D2E's Logto, and the same Logto access token logs
them in to PostgreSQL 18, where they can only `SELECT` from the datasets they were granted.
Logto, JupyterHub and PostgreSQL are separate containers.

Verified with the D2E `0.17.0-beta` stack (d2e CLI, Logto 1.23.1), the official
`postgres:18-alpine` (18.6) plus the mounted, patched `pg_oidc_validator.so`, and the hub in `hub/`.

## Where to look

| Document | Read it to | Go there when |
| --- | --- | --- |
| [README.md](README.md) (this file) | get the idea, run it in one command, see the results and findings | first |
| [ARCHITECTURE.md](ARCHITECTURE.md) ([한국어](ARCHITECTURE-ko.md)) | understand the containers, the runtime flow FLOW-1..5 file by file, the build order, and the full test procedure | you want to change something or test step by step |
| [Jupyter.md](Jupyter.md) | copy notebook cells: SELECT that must work, writes that must fail, who am I | you are logged in to JupyterHub and testing |
| [D2E-PERMISSIONS.md](D2E-PERMISSIONS.md) | see how D2E grants database access and how this PoC maps onto it | you plan the real D2E integration |

```text
admin ── https://localhost/sign-in ──> D2E portal (patched) ── usermgmt ──> Logto roles
                                         JupyterHub User  -> role.jupyteruser
                                         dataset Researcher -> role.researcher.<dataset id>
user ── http://localhost:8000 ──> pg18d2e-jupyterhub (needs role.jupyteruser)
                                     │ starts notebook with the token + granted datasets
                              jupyter-<user> ──OAUTHBEARER──> pg18d2e-pg18
                                     user role.researcher.<id>   │ validator: role must be in token `roles`
                                                                 └─ postgres_fdw (read-only) ─> d2e-demodb
```

## Run it

D2E must be running. From this folder:

```sh
sh run.sh
```

`run.sh` does everything and can be rerun:
1. `d2e-patch/apply.sh` adds the role **JupyterHub User** to the running D2E: usermgmt
   (`JUPYTER_USER` ↔ Logto role `role.jupyteruser`, function bundle rebuilt) and the portal UI
   (checkbox in Edit roles, role column). It restarts `d2e-trex` once when it changes something.
2. `d2e-patch/repair-logto-users.sh` re-links D2E users to their Logto user (see Findings).
3. `logto_setup.py` adds the hub app `jupyterhub-pg18-poc` to D2E Logto; values go to `.env.poc`.
4. Builds the validator `.so` and the notebook image, starts `pg18d2e-pg18`, `pg18d2e-sync`,
   `pg18d2e-jupyterhub`. `pg18d2e-sync` mirrors every D2E postgres dataset into PG18
   (today: `demo` → database `demo_database`, schema `demo_cdm`).

Then:
1. `https://localhost/sign-in` as `admin`: System Admin > Users > add `alice` > Edit roles >
   **JupyterHub User**; System Admin > Datasets > Demo dataset > Permissions > alice **Researcher**.
2. In a private window, `http://localhost:8000` > **Sign in with Data2Evidence** as alice:

```python
import pg_oauth
conn = pg_oauth.connect("demo")
conn.execute("select count(*) from demo_cdm.person").fetchone()   # (2694,)
conn.execute("drop table demo_cdm.person")                         # denied
```

## Results (2026-10-05)

| Test | Result |
| --- | --- |
| admin signs in at `https://localhost/sign-in` | pass, after `repair-logto-users.sh` (was an endless loop, see Findings) |
| admin grants alice **JupyterHub User** (`alp-user/register`) | usermgmt group `JUPYTER_USER`, Logto role `role.jupyteruser`; UI role list shows it |
| admin grants alice **Researcher** on demo (`register-study-roles`) | token `roles` gets `role.researcher.demo`, `role.researcher.94c35ae2-…` |
| alice logs in to the hub, server starts | pass; notebook gets `D2E_JUPYTER_DATASETS=[demo]` |
| alice: `select count(*) from demo_cdm.person` | 2694 |
| alice: DROP, DELETE, UPDATE, INSERT, ALTER, GRANT, CREATE TABLE/SCHEMA/TEMP | denied (read-only transaction) |
| same with `default_transaction_read_only=off` | denied by privileges (`permission denied`, `"person" is not a table`) |
| alice as another `role.researcher.<id>` / as `postgres` | denied (`not in token claim "roles"` / `pg_hba rejects`) |
| bob (no JupyterHub User) | hub 403 |
| bob's token as the demo role | denied |
| Researcher withdrawn | the next token has no demo role |
| PG18 log | `connection authenticated: identity="<alice sub>" method=oauth`; `system_user` = `oauth:<alice sub>` |

## Findings

- **`https://localhost/sign-in` looped** for two reasons. (a) The browser still held a Logto
  session of the old PoC user alice, who existed only in Logto; the portal rejected her
  ("User does not exist", "SECURITY INCIDENT: User does not belong to a tenant"), ended the
  session and sent the browser back to sign-in, where Logto signed alice in again. (b) The Logto
  user `admin` had been recreated (new id, no roles) while `usermgmt.user.idp_user_id` still held
  the old id, so the portal answered `IDP user ID … not found` for admin too.
  `repair-logto-users.sh` fixes (b); the old PoC users are gone, which fixes (a). If the browser
  still loops, clear the cookies of `localhost` once.
- **The running D2E does not use this repository's `plugins/`.** `d2e-trex` loads each function
  from the prebuilt `index.eszip` in the image, so the D2E change is applied by patching the
  bundled sources, rebuilding the eszip with `trex bundle` and restarting `d2e-trex`.
- **The bundler needs every module in the import map.** A new `src/…/X.ts` that is not listed in
  the function's `deno.json` fails with `Module not found`. The same was missing for
  `JupyterUserService` in `plugins/functions/alp-usermgmt` and has been added there.
- **One `pg_hba` line for all datasets** works with `delegate_ident_mapping=1` and a validator
  that reads the `roles` claim; no `pg_ident` map or per-dataset `pg_hba` line is needed.
- **The PG16 demo database cannot do OAuth.** PG18 reads it through `postgres_fdw` as a
  read-only user. A real deployment would put the dataset itself on PG18.
- **Logto 1.23 management API**: app creation returns 500 although the app is saved
  (`logto.check_application_type` misses the schema); `/roles` and `/users` page by 20.

## Clean up

```sh
sh run.sh --remove   # stops the PoC containers, deletes the hub app, reverts the D2E patch
```

D2E users created in the portal (alice, bob) stay; delete them in the portal.
