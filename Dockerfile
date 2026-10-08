FROM balena/open-balena-base:18.0.34 AS runtime

EXPOSE 80

COPY package.json package-lock.json /usr/src/app/
RUN HUSKY=0 npm ci --unsafe-perm --production && npm cache clean --force

COPY . /usr/src/app

# Friday fork (AquaButler t_174e110e, 2026-10-08):
# Patch @balena/pinejs's compiled env.js so the previously-hardcoded-false
# apiKeyPermissions cache slot respects PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS
# at process startup. With only one active api-key (API_VPN_SERVICE_API_KEY) in
# this AquaButler deployment, a single cache slot absorbs the 5-min
# contractSync DB contention that was producing ~1-2 PATCH
# /v6/service_instance(71) 401s per hour. Drops to 0 in the acceptance
# criterion. See Hermes/Memory/Friday/2026-10-08-t_fbc6949a-...
RUN set -eux; \
    NODE_MODULES=/usr/src/app/node_modules/@balena/pinejs/out/config-loader/env.js; \
    grep -n "apiKeyPermissions: false" "$NODE_MODULES" || { echo "pinejs env.js layout changed; patch cannot apply" >&2; exit 1; }; \
    python3 - <<'PY'
import sys
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

COPY config/services/ /etc/systemd/system/

RUN systemctl enable open-balena-api.service

# Set up a test image that can be reused
FROM runtime AS test

RUN apt update && apt install \
	&& apt install python3-pglast \
	&& rm -rf /var/lib/apt/lists/*

RUN npm ci && npm run lint

# Make the default output be the runtime image
FROM runtime
