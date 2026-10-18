#!/usr/bin/env bash
# One-time secrets bootstrap for the Hetzner deployment. Run ON the VM as the
# `deploy` user from this directory:
#
#   BENTO_PUBLIC_HOST=bento.wilfredchetat.com ./init-secrets.sh
#
# Writes $BENTO_HOME/secrets/compose.env and bento.env (mode 600) with fresh
# random secrets and anon/service_role JWTs minted from a fresh HS256 secret.
# It never prints a secret. It refuses to overwrite existing files.
#
# Afterwards replace every __CARRY_OVER__ in bento.env with the laptop values
# (SOCIAL_CONNECTION_ENCRYPTION_KEY, META_FACEBOOK_APP_ID/SECRET); `make check`
# refuses to start while placeholders remain.
set -Eeuo pipefail

BENTO_HOME="${BENTO_HOME:-/opt/bento}"
: "${BENTO_PUBLIC_HOST:?set BENTO_PUBLIC_HOST (e.g. bento.wilfredchetat.com)}"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
secrets_dir="$BENTO_HOME/secrets"

for f in compose.env bento.env; do
  if [[ -e "$secrets_dir/$f" ]]; then
    echo "refusing to overwrite existing $secrets_dir/$f" >&2
    exit 1
  fi
done
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }

install -d -m 700 "$secrets_dir"
umask 077

rand_hex() { openssl rand -hex 32; }

# base64url without padding, as JWT requires.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Mint an HS256 JWT the way Supabase's self-hosting generator does:
# {"role":<role>,"iss":"supabase","iat":now,"exp":now+10y}.
mint_jwt() {
  local role="$1" secret="$2"
  local now exp header payload signing_input signature
  now="$(date -u +%s)"
  exp=$(( now + 10 * 365 * 24 * 3600 ))
  header="$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)"
  payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$now" "$exp" | b64url)"
  signing_input="$header.$payload"
  signature="$(printf '%s' "$signing_input" | openssl dgst -sha256 -hmac "$secret" -binary | b64url)"
  printf '%s.%s' "$signing_input" "$signature"
}

pg_password="$(rand_hex)"
jwt_secret="$(rand_hex)"
cron_token="$(rand_hex)"
anon_key="$(mint_jwt anon "$jwt_secret")"
service_key="$(mint_jwt service_role "$jwt_secret")"

# compose.env: template with the generated values filled in.
sed \
  -e "s|^BENTO_HOME=.*|BENTO_HOME=$BENTO_HOME|" \
  -e "s|^BENTO_PUBLIC_HOST=.*|BENTO_PUBLIC_HOST=$BENTO_PUBLIC_HOST|" \
  -e "s|^BENTO_PG_PASSWORD=.*|BENTO_PG_PASSWORD=$pg_password|" \
  -e "s|^BENTO_JWT_SECRET=.*|BENTO_JWT_SECRET=$jwt_secret|" \
  -e "s|^BENTO_SUPABASE_ANON_KEY=.*|BENTO_SUPABASE_ANON_KEY=$anon_key|" \
  -e "s|^BENTO_SUPABASE_SERVICE_ROLE_KEY=.*|BENTO_SUPABASE_SERVICE_ROLE_KEY=$service_key|" \
  -e "s|^BENTO_CRON_TOKEN=.*|BENTO_CRON_TOKEN=$cron_token|" \
  "$here/compose.env.example" > "$secrets_dir/compose.env"

# bento.env: substitute placeholders; each __RANDOM__ gets its own value.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed \
  -e "s|__PUBLIC_HOST__|$BENTO_PUBLIC_HOST|g" \
  -e "s|__ANON_KEY__|$anon_key|g" \
  -e "s|__SERVICE_ROLE_KEY__|$service_key|g" \
  -e "s|__PG_PASSWORD__|$pg_password|g" \
  -e "s|__CRON_TOKEN__|$cron_token|g" \
  "$here/bento.env.example" > "$tmp"
while grep -q '__RANDOM__' "$tmp"; do
  r="$(rand_hex)"
  # Replace only the first occurrence so every secret is independent.
  sed -i "0,/__RANDOM__/s||$r|" "$tmp"
done
install -m 600 "$tmp" "$secrets_dir/bento.env"
chmod 600 "$secrets_dir/compose.env"

echo "wrote $secrets_dir/compose.env and $secrets_dir/bento.env"
echo "next: fill the $(grep -c '=__CARRY_OVER__$' "$secrets_dir/bento.env") __CARRY_OVER__ values in bento.env from the laptop .env, then run: make check"
