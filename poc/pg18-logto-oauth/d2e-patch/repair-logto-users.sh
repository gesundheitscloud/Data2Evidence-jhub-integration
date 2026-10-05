#!/bin/sh
# [SETUP] re-links D2E usermgmt users to their Logto users and gives them the Logto roles of their D2E groups
#   sh d2e-patch/repair-logto-users.sh
#
# Why: with USER_MGMT__ROLE_SOURCE=logto, D2E reads a user's permissions from the Logto roles in the
# token. If the Logto user was recreated (new id), usermgmt.user.idp_user_id points at a user that no
# longer exists and the new Logto user has no roles. The portal then answers "IDP user ID ... not
# found", ends the session, and https://localhost/sign-in loops back to the portal forever.
# Idempotent; only adds missing links/roles, never removes any.
set -eu
docker exec -i d2e-minerva-postgres-1 psql -X -v ON_ERROR_STOP=1 -U postgres -d alp <<'SQL'
-- logto's check functions name tables without schema
set search_path = logto, public;

-- 1. usermgmt user -> Logto user with the same username
update usermgmt."user" u
   set idp_user_id = l.id, modified_date = now(), modified_by = 'pg18-poc repair'
  from logto.users l
 where l.tenant_id = 'default' and l.username = u.username
   and u.idp_user_id is distinct from l.id
   and not exists (select 1 from logto.users x where x.tenant_id = 'default' and x.id = u.idp_user_id)
returning u.username, u.idp_user_id as relinked_to;

-- 2. each D2E group -> its Logto role name (as UserGroupService.buildLogtoRoleName does)
with wanted as (
  select u.idp_user_id as user_id,
         case g.role
           when 'ALP_SYSTEM_ADMIN' then 'role.systemadmin'
           when 'ALP_USER_ADMIN' then 'role.useradmin'
           when 'ALP_DASHBOARD_VIEWER' then 'role.dashboardviewer'
           when 'JUPYTER_USER' then 'role.jupyteruser'
           when 'TENANT_VIEWER' then 'role.viewer'
           when 'STUDY_WRITE_DQD_RESEARCHER' then 'role.jobrunner'
           when 'STUDY_RESULTS_READ_RESEARCHER' then 'role.studyresultsreader'
           when 'ETL_MAPPING_CONTRIBUTOR' then 'role.etlmappingcontributor'
           when 'RESEARCHER' then 'role.researcher.' || d.token_dataset_code
         end as role_name
    from usermgmt.user_group ug
    join usermgmt."user" u on u.id = ug.user_id
    join usermgmt.b2c_group g on g.id = ug.b2c_group_id
    left join portal.dataset d on d.id = g.study_id
)
insert into logto.users_roles (tenant_id, id, user_id, role_id)
select 'default', substr(md5(random()::text || w.user_id || r.id), 1, 21), w.user_id, r.id
  from wanted w
  join logto.users l on l.tenant_id = 'default' and l.id = w.user_id
  join logto.roles r on r.tenant_id = 'default' and r.name = w.role_name
on conflict (tenant_id, user_id, role_id) do nothing
returning user_id, (select name from logto.roles where id = role_id) as added_role;
SQL
