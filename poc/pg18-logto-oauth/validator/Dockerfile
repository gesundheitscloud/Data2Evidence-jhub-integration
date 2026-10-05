# [BUILD-1] compiles the PG18 token validator (pg_oidc_validator.so) into validator/out/; pg18 mounts it
#   docker build --output validator/out validator
FROM postgres:18-alpine AS build

# pinned commit of https://github.com/percona/pg_oidc_validator
ARG PG_OIDC_VALIDATOR_REF=ba9c4cb2dc9bd2e9779c7a33f7a30c9bb8c97862

# build deps: pg_oidc_validator has no Alpine package, so it is compiled against postgres:18-alpine
RUN apk add --no-cache build-base curl-dev krb5-dev git
RUN git init /src && cd /src \
    && git remote add origin https://github.com/percona/pg_oidc_validator \
    && git fetch --depth 1 origin "$PG_OIDC_VALIDATOR_REF" \
    && git checkout FETCH_HEAD
WORKDIR /src
# D2E patch: role_claim/role_prefix/audience settings (authorize a PG role from the token's `roles` claim)
COPY d2e-roles.patch /tmp/d2e-roles.patch
RUN git apply --check /tmp/d2e-roles.patch && git apply /tmp/d2e-roles.patch
RUN make USE_PGXS=1 with_llvm=no -j"$(nproc)"

FROM scratch
COPY --from=build /src/pg_oidc_validator.so /
