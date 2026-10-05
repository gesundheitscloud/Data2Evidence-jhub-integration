# Notebook test cells

Paste these into a Python notebook after a D2E admin granted you **JupyterHub User** and
**Researcher** on a dataset, and you logged in to JupyterHub (see
[ARCHITECTURE.md](ARCHITECTURE.md) section 4). Expected results for alice with the demo
dataset are in the comments. ← [README.md](README.md)

```python
# 1. success
import pg_oauth
pg_oauth.datasets()                      # [{'tokenDatasetCode': 'demo', 'schema': 'demo_cdm', ...}]
conn = pg_oauth.connect("demo")          # dataset code or id; optional when you have one dataset
conn.execute("select * from demo_cdm.person limit 5").fetchall()   # good

# 2. must fail
conn.execute("drop table demo_cdm.person")                          # read-only / not owner
conn.execute("delete from demo_cdm.person")                         # read-only / permission denied
conn.execute("create table demo_cdm.x (i int)")                     # read-only / permission denied

# 1 by 1 test

import time, pg_oauth

# what is inside token
c = pg_oauth.claims()
print("Logto user:", c["sub"], "| roles:", c["roles"], "| left time:", int(c["exp"] - time.time()), "seconds")

conn = pg_oauth.connect("demo")
q = lambda sql: conn.execute(sql).fetchall()

# 1. who am i
q("select system_user, current_user, current_database()")

# 2. what is my role
q("select rolname from pg_roles where pg_has_role(current_user, oid, 'member')")

# 3. what table i can see
q("""select table_schema, table_name from information_schema.tables
   where table_schema not in ('pg_catalog', 'information_schema') order by 1, 2""")

# 4. what privileges i have (SELECT only)
q("""select privilege_type, count(*) from information_schema.role_table_grants
   where grantee = current_user group by 1""")

# 5. where can i create?
q("""select nspname,
          has_schema_privilege(nspname, 'USAGE')  as usage,
          has_schema_privilege(nspname, 'CREATE') as can_create
   from pg_namespace where nspname in ('public', 'demo_cdm') order by 1""")
```

The token lasts one hour, and the dataset list is fixed when the server starts. After a new
grant or "expired", restart the server from File > Hub Control Panel.
