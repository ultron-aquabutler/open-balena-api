FROM balena/open-balena-base:22.0.2-s6-overlay@sha256:78db983c9ca7b9223acab497d9a45ebbb1af10fd8e53038e22fb815cba7c0cbb AS runtime

EXPOSE 80

COPY package.json package-lock.json /usr/src/app/
RUN HUSKY=0 npm ci --omit=dev && npm cache clean --force

COPY . /usr/src/app

# Friday fork (AquaButler t_174e110e, 2026-10-08):
# Patch @balena/pinejs compiled cache config to honor a runtime env knob
# PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS. With only one active api-key
# (API_VPN_SERVICE_API_KEY) in this deployment, re-enabling the cache with a
# 5-min TTL absorbs the contractSync contention window that was producing
# ~1-2 PATCH /v6/service_instance(71) 401s per hour. Drops to 0 in the
# acceptance criterion. See Hermes/Memory/Friday/2026-10-08-t_fbc6949a-...
RUN set -eux; \
    NODE_MODULES=/usr/src/app/node_modules/@balena/pinejs/out/config-loader/env.js; \
    grep -n "apiKeyPermissions: false" "$NODE_MODULES" || { echo "pinejs env.js layout changed; patch cannot apply" >&2; exit 1; }; \
    python3 - <<'PY'
import re, sys
p = "/usr/src/app/node_modules/@balena/pinejs/out/config-loader/env.js"
src = open(p).read()
new = src.replace(
    "apiKeyPermissions: false,",
    "apiKeyPermissions: process.env.PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS\n"
    "\t? { max: 5000, maxAge: parseInt(process.env.PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS, 10) }\n"
    "\t: false,",
    1,
)
if new == src:
    print("patch did not apply", file=sys.stderr); sys.exit(1)
open(p, "w").write(new)
PY
RUN npx tsc --noEmit --project ./tsconfig.build.json

CMD [ "/usr/src/app/entry.sh" ]

# Set up a test image that can be reused
FROM runtime AS test

# hadolint ignore=DL3008
RUN apt-get update \
	&& apt-get install -y --no-install-recommends python3-pglast \
	&& rm -rf /var/lib/apt/lists/*

RUN npm ci && npm run lint

# Make the default output be the runtime image
FROM runtime
