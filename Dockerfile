# syntax=docker/dockerfile:1

# Base images are pinned by tag (readable) AND multi-arch index digest
# (immutable): a re-pushed tag can't change what we build. Bump both together.
ARG NODE_IMAGE=node:26.13.0-alpine3.24@sha256:8996bb5821d62a8fd9bb27c1cb07462f3fdce6e47d640c6a881ead0b064ce216
ARG ALPINE_IMAGE=alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf

# ---- deps: install production dependencies ---------------------------------
# Official Node image, because it ships npm. Runs on the *build* machine's
# platform so CI on amd64 doesn't emulate arm64 for npm ci. Safe because every
# dependency is pure JavaScript (no native .node addons): re-check this if a
# native dependency is ever added.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json .npmrc ./
# --ignore-scripts: no install scripts from third-party packages run at build.
RUN npm ci --omit=dev --ignore-scripts

# ---- runtime ----------------------------------------------------------------
# Plain Alpine + Alpine's Node 26 package, NOT the official node image: the
# official binary statically bundles OpenSSL and full ICU (148 MB on its own),
# which alone breaks the 150 MB budget. Alpine's build links them as shared
# libraries (~94 MB rootfs total) and ships no npm/yarn/corepack at all.
# `~26` = any 26.x: security patches flow in on rebuild, the major can't move.
# `apk upgrade`: the base is pinned by digest (reproducible), which also freezes
# its OS packages; upgrading pulls in fixes released since (e.g. zlib 1.4).
FROM ${ALPINE_IMAGE}
RUN apk upgrade --no-cache \
 && apk add --no-cache nodejs-current~26 \
 && addgroup -S -g 10001 app \
 && adduser -S -D -H -u 10001 -G app app

# Amazon RDS CA bundle, so the app can verify the database's TLS certificate.
# The checksum pins the exact file; if AWS changes it the build fails loudly.
ADD --checksum=sha256:90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b \
    --chmod=644 \
    https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    /etc/ssl/certs/rds-global-bundle.pem

WORKDIR /app
# Files stay owned by root: the app user can read them but not modify them.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

ENV NODE_ENV=production \
    PORT=3000 \
    # Secure by default: TLS to Postgres with full certificate + hostname check.
    # Local runs against compose override with PGSSLMODE=disable.
    PGSSLMODE=verify-full \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/rds-global-bundle.pem

# Numeric uid:gid so platforms can verify "non-root" without reading /etc/passwd.
USER 10001:10001
EXPOSE 3000

# For `docker run` / compose. ECS ignores this, so the task definition repeats
# it (Terraform). busybox wget is already in Alpine: no extra package needed.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${PORT}/healthz" || exit 1

# Exec form: node gets SIGTERM directly (no shell in between) and our handler
# in server.js drains requests. ECS adds an init process (initProcessEnabled)
# to reap zombies; locally use `docker run --init`.
CMD ["node", "src/server.js"]
