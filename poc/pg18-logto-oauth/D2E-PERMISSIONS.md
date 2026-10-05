# D2E permissions and PostgreSQL

← [README.md](README.md) · how the PoC works: [ARCHITECTURE.md](ARCHITECTURE.md)

Read from the code on 2026-09-30 (branch `feature/MIM-7-pr`). Paths are relative to the
repository root.

## Today: access is decided in the application, not in PostgreSQL

Giving a user access to a dataset never creates or changes anything inside PostgreSQL.

1. **Grant.** A tenant admin calls `POST /usermgmt/api/user-group/register-study-roles`
   (`plugins/functions/alp-usermgmt/src/routes/UserGroupRouter.ts:190-257`), or approves an
   access request (`src/services/StudyAccessRequestService.ts:82-83`). This writes rows in
   `usermgmt.b2c_group` (role, tenant, dataset) and `usermgmt.user_group` (membership).
2. **Role name.** `UserGroupService.buildLogtoRoleName`
   (`src/services/UserGroupService.ts:421-444`) turns a researcher group into
   `role.researcher.<token_dataset_code>`. `token_dataset_code` is a column of
   `portal.dataset`. The role carries the scopes from `datasetResearcherScopes`
   (`plugins/functions/_shared/idp/roles.ts:52-59`): `role.researcher.<code>`,
   `role.researcher.<datasetId>`, `source-user-<datasetId>` (WebAPI datasets) and the
   cohort/concept-set scopes.
3. **Role store.** The role is pushed to the identity provider. The default is now
   **trex** (`docker-compose.yml:597-600`: `USER_MGMT__ROLE_SOURCE=trex`,
   `IDP__ROLE_STORE=trex`), posting to `/trex/admin/roles`. Logto is the legacy store
   (`src/api/LogtoAPI.ts`).
4. **Token.** The IdP puts the user's role scopes into a `roles` claim (Logto via the
   `LOGTO__CUSTOM_JWT` script, trex via its OIDC provider).
5. **Enforcement.** Services read `roles`: WebAPI maps them to `sec_role`s, usermgmt and
   the portal filter datasets, the trex gateway maps roles to route scopes. The gateway's
   enforcement code lives in the external `ghcr.io/ohdsi/trexsql` image, not in this repo.
6. **Data access.** Services connect with **shared per-database credentials**
   (`trex.db` rows with `Admin` / `Read` users, encrypted with `DB_CREDENTIALS__*`).
   End users never get their own PostgreSQL login.

The only PostgreSQL objects per dataset are created when a schema is created, by
`create_and_assign_roles_task`
(`plugins/flows/_shared_flow_utils/create_dataset_tasks.py:54-126`):

- role `<schema>_read_role` with read privileges on the schema
- the database's service `readUser` and `readRole` (e.g. `postgres_tenant_read_role`)
  with read privileges on the schema
- skipped entirely when `IS_SELF_MANAGED_ROLES=true`

## What the PoC adds

| D2E today | PoC |
| --- | --- |
| Researcher grant → Logto role `role.researcher.<code>` with scope `role.researcher.<dataset id>` | unchanged; this scope is the PG18 login permission |
| no Jupyter permission | new ALP role `JUPYTER_USER` → Logto `role.jupyteruser` (hub gate) |
| services read data with shared `trex.db` credentials | the user logs in to PG18 as `role.researcher.<dataset id>` with their own token |
| `<schema>_read_role` per schema | `sync/sync.sh` creates the PG18 role with SELECT on the dataset schema |
| — | one `pg_hba` line for all datasets; the patched validator matches the requested role against the token's `roles` |

## Open issues before production

1. **Which IdP issues the token.** On develop the IdP moves to trex (#3371). The validator needs
   a JWT access token with `iss`, a JWKS endpoint and the `roles` claim; this PoC proves it only
   for Logto.
2. **Public issuer.** Tokens carry `iss=http://d2e-caddy:8080/oidc`, which is reachable only inside
   `d2e_alp`. PG18 or the hub on another machine needs a public HTTPS issuer, and then libpq no
   longer needs `PGOAUTHDEBUG=UNSAFE`.
3. **Datasets on PG18.** The PoC reads PG16 datasets through `postgres_fdw`. In production, the
   dataset should live on PG18, or the dataset flow should create the role next to
   `create_and_assign_roles_task`.
4. **Maintained validator patch.** `validator/d2e-roles.patch` is on top of a pinned
   `percona/pg_oidc_validator` commit and should go upstream or be owned by D2E.
5. **Revocation delay.** Removing a grant stops new logins; an issued token works until it
   expires (1 hour). Keep the resource's token lifetime short.
6. **Running D2E vs. source.** The UI/usermgmt change is in `plugins/` on this branch, but the
   running 0.17.0-beta stack is patched in its container (`d2e-patch/`). A D2E release with the
   branch merged makes `d2e-patch/` unnecessary.
