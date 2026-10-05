# [FLOW-2] in the notebook: picks the PG role of a granted D2E dataset and hands the token to libpq 18 via its OAuth hook
"""Connect to PostgreSQL 18 with the Logto access token JupyterHub gave this notebook.

No released Python driver speaks PostgreSQL 18's OAuth yet, so this installs libpq's
own OAuth hook (PQsetAuthDataHook) with ctypes. psycopg must use the same system
libpq 18, which is why the image sets PSYCOPG_IMPL=python and has no psycopg[binary].

    import pg_oauth
    pg_oauth.datasets()                # datasets a D2E admin granted you (Researcher)
    conn = pg_oauth.connect("demo")    # token_dataset_code or dataset id; optional if only one
    conn.execute("select * from demo_cdm.person limit 5").fetchall()

Environment, all set by the hub (hub/jupyterhub_config.py, pass_access_token) at server start:
    LOGTO_ACCESS_TOKEN    D2E access token; libpq sends it to PG18 (expires after about an hour)
    D2E_JUPYTER_DATASETS  JSON list of the user's granted datasets (host, database, schema, postgresRole)
    PG_OAUTH_ISSUER       issuer libpq names to PG18 (must match pg_hba's issuer)
    PG_OAUTH_CLIENT_ID    OAuth client id libpq requires (the hub's Logto app)
New grants or an expired token: restart the server from File > Hub Control Panel.
"""
import base64
import ctypes
import ctypes.util
import json
import os
import time

import psycopg

_PQAUTHDATA_OAUTH_BEARER_TOKEN = 1  # PGauthData in libpq-fe.h (18): "libpq needs a bearer token"


# PGoauthBearerRequest from libpq-fe.h (18): the struct libpq passes to the hook; we fill `token`.
class _BearerRequest(ctypes.Structure):
    _fields_ = [
        ("openid_configuration", ctypes.c_char_p),
        ("scope", ctypes.c_char_p),
        ("async_", ctypes.c_void_p),
        ("cleanup", ctypes.c_void_p),
        ("token", ctypes.c_void_p),
        ("user", ctypes.c_void_p),
    ]


_libpq = ctypes.CDLL(ctypes.util.find_library("pq") or "libpq.so.5")
_libc = ctypes.CDLL(None)
_libc.strdup.restype = ctypes.c_void_p
_libc.strdup.argtypes = [ctypes.c_char_p]

if _libpq.PQlibVersion() < 180000:
    raise ImportError(f"libpq {_libpq.PQlibVersion()} found; PostgreSQL 18 libpq is required")

_HOOK = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
_libpq.PQdefaultAuthDataHook.restype = ctypes.c_int
_libpq.PQdefaultAuthDataHook.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
_current_token = None  # token the hook hands to libpq; set by connect()


# libpq auth-data hook: answer token requests with _current_token, pass anything else to libpq's default.
def _hook(kind, conn, data):
    if kind == _PQAUTHDATA_OAUTH_BEARER_TOKEN and _current_token:
        request = ctypes.cast(data, ctypes.POINTER(_BearerRequest)).contents
        request.token = _libc.strdup(_current_token.encode())  # small leak per connection
        return 1
    return _libpq.PQdefaultAuthDataHook(kind, conn, data)


_hook_ref = _HOOK(_hook)  # keep a reference, or the callback gets garbage collected
_libpq.PQsetAuthDataHook(_hook_ref)


# The access token from the hub; raises if missing or expired.
def token():
    value = os.environ.get("LOGTO_ACCESS_TOKEN")
    if not value:
        raise RuntimeError("LOGTO_ACCESS_TOKEN is not set; the hub did not pass a token")
    if claims(value).get("exp", 0) < time.time():
        raise RuntimeError("the access token has expired; restart your server from the Hub Control Panel")
    return value


# Decoded token claims (sub, roles, exp, ...), for inspection only: no signature check, PG18 does that.
def claims(value=None):
    part = (value or os.environ.get("LOGTO_ACCESS_TOKEN", "")).split(".")
    if len(part) != 3:
        raise RuntimeError("the access token is not a JWT")
    return json.loads(base64.urlsafe_b64decode(part[1] + "=" * (-len(part[1]) % 4)))


# The token's `roles` claim: role.jupyteruser, role.researcher.<dataset id>, ...
def roles():
    value = claims(token()).get("roles", [])
    return set(value if isinstance(value, list) else [])


# Datasets a D2E admin granted this user (Researcher), as the hub passed them at server start.
def datasets():
    raw = os.environ.get("D2E_JUPYTER_DATASETS", "[]")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("D2E_JUPYTER_DATASETS is not valid JSON") from exc
    if not isinstance(value, list):
        raise RuntimeError("D2E_JUPYTER_DATASETS must be a JSON array")
    return value


# One granted dataset by token_dataset_code or id; with no argument, the only one granted.
def _select_dataset(identifier=None):
    available = datasets()
    if not available:
        raise RuntimeError("no D2E dataset is granted to you; ask a D2E admin for the Researcher role on a dataset, "
                           "then restart your server from the Hub Control Panel")
    if identifier is None:
        if len(available) == 1:
            return available[0]
        choices = [item.get("tokenDatasetCode") or item.get("id") for item in available]
        raise RuntimeError(f"choose a dataset with connect(dataset=...); available datasets: {choices}")
    matches = [
        item for item in available
        if identifier in (item.get("id"), item.get("tokenDatasetCode"))
    ]
    if len(matches) != 1:
        raise RuntimeError(f"dataset {identifier!r} is not available to this user")
    return matches[0]


# Read-only psycopg connection to a granted dataset, logged in to PG18 as role.researcher.<dataset id>.
def connect(dataset=None, **kwargs):
    global _current_token
    connection = _select_dataset(dataset)
    role = connection["postgresRole"]
    if role not in roles():
        raise RuntimeError(f"the access token does not grant dataset role {role}")
    _current_token = token()
    issuer = os.environ["PG_OAUTH_ISSUER"]
    if issuer.startswith("http://"):
        # libpq rejects a plain-HTTP issuer even when the token comes from this hook.
        # Local PoC only; a real deployment uses an HTTPS issuer and never sets this.
        os.environ.setdefault("PGOAUTHDEBUG", "UNSAFE")
    params = {
        "host": connection["host"],
        "port": connection["port"],
        "dbname": connection["database"],
        "user": role,
        "oauth_issuer": issuer,
        "oauth_client_id": os.environ["PG_OAUTH_CLIENT_ID"],
        "autocommit": True,
    }
    params.update(kwargs)  # e.g. options="-c statement_timeout=60000"
    return psycopg.connect(**params)
