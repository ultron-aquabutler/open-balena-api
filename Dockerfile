FROM balena/open-balena-base:22.0.2-s6-overlay@sha256:78db983c9ca7b9223acab497d9a45ebbb1af10fd8e53038e22fb815cba7c0cbb AS runtime

EXPOSE 80

COPY package.json package-lock.json /usr/src/app/
RUN HUSKY=0 npm ci --omit=dev && npm cache clean --force

COPY . /usr/src/app

# Friday fork (AquaButler t_174e110e, 2026-10-08):
# Two small fork-side patches:
#
#   1. Cache config: patch @balena/pinejs's compiled env.js so the previously-
#      hardcoded-false apiKeyPermissions cache slot respects
#      PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS at process startup.
#
#   2. Confd template: append the env var to config/confd/templates/env.tmpl
#      so entry.sh's load_env_file (which only sees /usr/src/app/config/env,
#      not the outer container process.env) actually receives it from the
#      compose `environment:` block.
#
# With only the API_VPN_SERVICE_API_KEY in flight in this deployment, a single
# cache slot absorbs the 5-min contractSync contention that was producing
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
    print("cache config patch did not apply", file=sys.stderr); sys.exit(1)
open(p, "w").write(new)

# Confd template patch: append the new env var so load_env_file receives it.
TMPL="/usr/src/app/config/confd/templates/env.tmpl"
tsrc = open(TMPL).read()
LINE = 'PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS={{getenv "PINEJS_API_KEY_PERMISSIONS_CACHE_MAX_AGE_MS"}}'
if LINE in tsrc:
    print("confd template already patched, skipping"); sys.exit(0)
if not tsrc.endswith("\n"):
    tsrc += "\n"
tsrc += LINE + "\n"
open(TMPL, "w").write(tsrc)
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
