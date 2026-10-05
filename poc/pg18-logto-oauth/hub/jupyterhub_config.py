# [FLOW-1] hub: Logto login, gate on role.jupyteruser, at spawn give the notebook a fresh token + the user's granted datasets
# Copied into the hub image (hub/Dockerfile), not mounted: rebuild (sh run.sh) after editing.
#
# runtime flow for one user
#   [flow 1] browser -> D2E Logto login page
#   [flow 2] Logto -> hub callback, hub gets tokens
#   [flow 3] hub checks the token's `roles` for LOGTO_ALLOWED_ROLE (D2E "JupyterHub User")
#   [flow 4] hub stores tokens (auth_state, encrypted with JUPYTERHUB_CRYPT_KEY)
#   [flow 5] server start -> pass_access_token refreshes the token, filters the dataset catalog
#   [flow 6] notebook container starts; pg_oauth.connect() logs in to PG18 with the token
#   [flow 7] logout stops the container
import base64
import json
import os
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


# Env value or a clear startup error; every value comes from docker-compose.yml.
def required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set")
    return value


# The `roles` claim of a D2E access token: scopes of all the user's Logto roles (role.jupyteruser, role.researcher.<id>, ...).
def token_roles(access_token: str) -> list[str]:
    try:
        part = access_token.split(".")[1]
        payload = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
    except (ValueError, IndexError, json.JSONDecodeError):
        return []
    roles = payload.get("roles", [])
    return [role for role in roles if isinstance(role, str)] if isinstance(roles, list) else []


# [flow 3] JupyterHub groups of the user = token roles; allowed_groups below lets in only LOGTO_ALLOWED_ROLE.
def user_groups(auth_state: dict) -> list[str]:
    return token_roles(auth_state.get("access_token") or "")


# Catalog entries (written by pg18-sync) whose postgresRole is in the token: the datasets this user may open.
def granted_datasets(access_token: str) -> list[dict]:
    path = required_env("D2E_DATASET_CATALOG")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        catalog = json.load(f)
    roles = set(token_roles(access_token))
    return [d for d in catalog if isinstance(d, dict) and d.get("postgresRole") in roles]


# Swap the stored refresh token for a fresh access token, so new D2E grants and a full hour reach the notebook.
def refreshed_token_state(auth_state: dict) -> dict:
    refresh_token = auth_state.get("refresh_token")
    if not refresh_token:
        return auth_state
    basic = base64.b64encode(
        f"{quote(required_env('LOGTO_JUPYTERHUB_CLIENT_ID'))}:"
        f"{quote(required_env('LOGTO_JUPYTERHUB_CLIENT_SECRET'))}".encode()
    ).decode()
    body = urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "resource": required_env("LOGTO_RESOURCE"),
    }).encode()
    request = Request(required_env("LOGTO_TOKEN_URL"), body, {
        "authorization": f"Basic {basic}",
        "content-type": "application/x-www-form-urlencoded",
    })
    with urlopen(request, timeout=15) as response:
        tokens = json.loads(response.read())
    return {
        **auth_state,
        "access_token": tokens["access_token"],
        "refresh_token": tokens.get("refresh_token", refresh_token),
    }


# [flow 5] Spawner hook: notebook env gets the access token, granted datasets and PG18 OAuth settings (never the refresh token or secret).
async def pass_access_token(spawner, auth_state):
    if not auth_state:
        return
    auth_state = refreshed_token_state(auth_state)
    await spawner.user.save_auth_state(auth_state)  # keep the rotated refresh token
    spawner.environment["LOGTO_ACCESS_TOKEN"] = auth_state["access_token"]
    spawner.environment["D2E_JUPYTER_DATASETS"] = json.dumps(
        granted_datasets(auth_state["access_token"]), separators=(",", ":")
    )
    spawner.environment["PG_OAUTH_ISSUER"] = required_env("NOTEBOOK_PG_OAUTH_ISSUER")
    spawner.environment["PG_OAUTH_CLIENT_ID"] = required_env("NOTEBOOK_PG_OAUTH_CLIENT_ID")


c = get_config()  # noqa: F821 - provided by JupyterHub at runtime

c.JupyterHub.bind_url = "http://0.0.0.0:8000"  # browser -> hub (published as localhost:8000)
c.JupyterHub.hub_bind_url = "http://0.0.0.0:8081"  # notebook -> hub API
c.JupyterHub.hub_connect_url = required_env("JUPYTERHUB_HUB_CONNECT_URL")  # how notebooks reach the hub API
c.JupyterHub.cookie_secret_file = "/srv/jupyterhub/data/jupyterhub_cookie_secret"
c.JupyterHub.db_url = "sqlite:////srv/jupyterhub/data/jupyterhub.sqlite"

# [flow 4] keep the tokens; without a crypt key nothing is stored and no token reaches the notebook
c.Authenticator.enable_auth_state = bool(os.getenv("JUPYTERHUB_CRYPT_KEY"))
# periodic re-validation re-decodes the expired id token and fails; roles are re-read at each login
c.Authenticator.auth_refresh_age = 0

c.JupyterHub.authenticator_class = "generic-oauth"
c.GenericOAuthenticator.client_id = required_env("LOGTO_JUPYTERHUB_CLIENT_ID")  # Logto app jupyterhub-pg18-poc
c.GenericOAuthenticator.client_secret = required_env("LOGTO_JUPYTERHUB_CLIENT_SECRET")
# [flow 2] Logto sends the browser back here; must equal the redirect uri registered by logto_setup.py
c.GenericOAuthenticator.oauth_callback_url = required_env("JUPYTERHUB_OAUTH_CALLBACK_URL")
# [flow 1] browser-facing Logto authorize endpoint
c.GenericOAuthenticator.authorize_url = required_env("LOGTO_AUTHORIZE_URL")
# [flow 2] server-to-server token endpoint (same host as the token's iss)
c.GenericOAuthenticator.token_url = required_env("LOGTO_TOKEN_URL")
c.GenericOAuthenticator.userdata_from_id_token = True
c.GenericOAuthenticator.username_claim = "username"  # hub user name = D2E/Logto username
c.GenericOAuthenticator.login_service = "Data2Evidence"  # button "Sign in with Data2Evidence"
c.GenericOAuthenticator.scope = ["openid", "profile", "email", "offline_access"]
# the access token is a JWT for D2E's API resource (aud=https://alp-default); PG18 requires that audience
c.GenericOAuthenticator.extra_authorize_params = {"resource": required_env("LOGTO_RESOURCE")}
c.GenericOAuthenticator.token_params = {"resource": required_env("LOGTO_RESOURCE")}
# [flow 3] the gate
c.GenericOAuthenticator.manage_groups = True
c.GenericOAuthenticator.auth_state_groups_key = user_groups
c.GenericOAuthenticator.allowed_groups = {required_env("LOGTO_ALLOWED_ROLE")}
c.GenericOAuthenticator.allow_all = False
c.GenericOAuthenticator.allow_existing_users = False
c.GenericOAuthenticator.custom_403_message = (
    "Your account is valid, but it does not have the JupyterHub User role in D2E."
)

# [flow 7] stop the user's notebook container on logout
c.JupyterHub.shutdown_on_logout = True

# [flow 5] register the hook above
c.Spawner.auth_state_hook = pass_access_token

# [flow 6] one docker container per user, on the internal notebook network only
c.JupyterHub.spawner_class = "dockerspawner.DockerSpawner"
c.DockerSpawner.image = required_env("JUPYTERHUB_NOTEBOOK_IMAGE")  # pgoauth-notebook:local
c.DockerSpawner.network_name = required_env("DOCKER_NETWORK_NAME")  # pg18d2e-notebooks (internal)
c.DockerSpawner.use_internal_ip = True
c.DockerSpawner.remove = True
c.DockerSpawner.notebook_dir = "/home/jovyan/work"
c.DockerSpawner.volumes = {"jupyterhub-user-{username}": "/home/jovyan/work"}  # user's files survive restarts
c.DockerSpawner.mem_limit = "1G"
c.DockerSpawner.cpu_limit = 1.0
c.Spawner.default_url = "/lab"
c.Spawner.start_timeout = 120

c.JupyterHub.log_level = os.getenv("JUPYTERHUB_LOG_LEVEL", "INFO")
