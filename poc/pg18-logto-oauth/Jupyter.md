# Test guide

← [README.md](README.md)

## 1. Admin grants (`https://localhost/sign-in`, user `admin`)

1. **System Admin > Users > Add user**: create `carol` with a password.
2. On carol's row, open **Edit roles**, tick **JupyterHub User**, and save. The role column now shows it.
3. **System Admin > Datasets > Demo dataset > Permissions**: give carol **Researcher**.

| carol has | Expected |
| --- | --- |
| nothing | hub login → 403 |
| JupyterHub User only | hub login works, `pg_oauth.datasets()` is `[]` |
| both | all cells below pass |

Grants are read when the token is issued. After changing them, use **File > Hub Control Panel >
Stop My Server > Start My Server**.

## 2. Log in to JupyterHub

Open a **private window**. Otherwise the hub reuses the portal's admin session and answers 403.
Go to `http://localhost:8000` (http, not https), click **Sign in with Data2Evidence**, sign in
as carol, and open a Python 3 notebook.

## 3. Notebook cells

```python
# 1) my token and my datasets
import pg_oauth, time
c = pg_oauth.claims()
print("user:", c["sub"], "| roles:", c["roles"], "| seconds left:", int(c["exp"] - time.time()))
pg_oauth.datasets()      # [{'tokenDatasetCode': 'demo', 'schema': 'demo_cdm', ...}]
```

```python
# 2) connect: who am I
conn = pg_oauth.connect("demo")          # dataset code or id; optional with one dataset
q = lambda sql: conn.execute(sql).fetchall()
q("select system_user, current_user, current_database()")
# [('oauth:<carol id>', 'role.researcher.94c35ae2-...', 'demo_database')]
```

```python
# 3) SELECT: must work
q("select count(*) from demo_cdm.person")                                  # [(2694,)]
q("select person_id, gender_concept_id, year_of_birth from demo_cdm.person limit 5")
q("""select c.concept_name, count(*) n
     from demo_cdm.condition_occurrence co
     join demo_cdm.concept c on c.concept_id = co.condition_concept_id
     group by 1 order by n desc limit 10""")
```

```python
# 4) writes: must all fail
for sql in ["drop table demo_cdm.person",
            "delete from demo_cdm.person",
            "update demo_cdm.person set year_of_birth = 1900",
            "insert into demo_cdm.person (person_id) values (-1)",
            "create table demo_cdm.x (i int)",
            "create temp table x (i int)",
            "alter table demo_cdm.person add column x int"]:
    try:
        conn.execute(sql); print("ALLOWED (bad):", sql)
    except Exception as e:
        print("denied:", sql[:45], "->", str(e).splitlines()[0])
```

```python
# 5) still denied with read-only switched off: privileges block it
conn2 = pg_oauth.connect("demo", options="-c default_transaction_read_only=off")
for sql in ["delete from demo_cdm.person", "create table demo_cdm.x (i int)", "drop table demo_cdm.person"]:
    try:
        conn2.execute(sql); print("ALLOWED (bad):", sql)
    except Exception as e:
        print("denied:", sql, "->", str(e).splitlines()[0])
```

```python
# 6) my privileges: SELECT only
q("""select privilege_type, count(*) from information_schema.role_table_grants
     where grantee = current_user group by 1""")        # [('SELECT', 40)]
```

## 4. Revoke

1. As admin, remove carol's **Researcher** grant.
2. carol restarts her server. `pg_oauth.datasets()` is now `[]` and `connect("demo")` raises an error.

## On the PostgreSQL side

```sh
docker logs pg18d2e-pg18 | grep -E 'method=oauth|Authorization failed'   # who logged in / who was refused
docker logs pg18d2e-sync                                                 # one line per catalog change
docker exec pg18d2e-pg18 psql -U postgres -c "select * from pg_hba_file_rules"
```
