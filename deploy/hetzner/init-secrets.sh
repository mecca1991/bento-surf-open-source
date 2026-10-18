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
command -v python3 >/dev/null || { echo "python3 is required (JWK encoding)" >&2; exit 1; }

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

# ES256 signing key as a JWK, plus the HS256 secret as a verify-only `oct` JWK.
# GoTrue signs with the key whose key_ops contain "sign"; PostgREST receives the
# public half. python3 only does base64/JSON; openssl generates the key.
make_jwt_keys() {
  local secret="$1" kid txt
  kid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)"
  txt="$(openssl ecparam -name prime256v1 -genkey -noout | openssl ec -text -noout 2>/dev/null)"
  python3 - "$kid" "$secret" "$txt" <<'PY'
import sys, base64, json, re
kid, secret, txt = sys.argv[1:4]
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def hexblock(label):
    out, on = [], False
    for line in txt.split("\n"):
        if line.strip() == label + ":": on = True; continue
        if on:
            if re.fullmatch(r"\s+[0-9a-f:]+", line): out.append(line.strip())
            else: break
    return bytes.fromhex("".join(out).replace(":", ""))
d = hexblock("priv")[-32:].rjust(32, b"\0"); pub = hexblock("pub")
assert pub[0] == 4 and len(pub) == 65
priv = {"kty": "EC", "crv": "P-256", "x": b64u(pub[1:33]), "y": b64u(pub[33:65]), "d": b64u(d),
        "kid": kid, "alg": "ES256", "use": "sig", "key_ops": ["sign", "verify"]}
pub_jwk = {k: v for k, v in priv.items() if k != "d"}; pub_jwk["key_ops"] = ["verify"]
legacy = {"kty": "oct", "k": b64u(secret.encode()), "kid": "legacy-hs256", "alg": "HS256",
          "use": "sig", "key_ops": ["verify"]}
sep = (",", ":")
print(json.dumps([priv, legacy], separators=sep))
print(json.dumps({"keys": [pub_jwk, legacy]}, separators=sep))
PY
}

pg_password="$(rand_hex)"
jwt_secret="$(rand_hex)"
jwt_keys_out="$(make_jwt_keys "$jwt_secret")"
jwt_keys="$(printf '%s\n' "$jwt_keys_out" | sed -n 1p)"
pgrst_jwks="$(printf '%s\n' "$jwt_keys_out" | sed -n 2p)"
cron_token="$(rand_hex)"
anon_key="$(mint_jwt anon "$jwt_secret")"
service_key="$(mint_jwt service_role "$jwt_secret")"

# compose.env: template with the generated values filled in.
sed \
  -e "s|^BENTO_HOME=.*|BENTO_HOME=$BENTO_HOME|" \
  -e "s|^BENTO_PUBLIC_HOST=.*|BENTO_PUBLIC_HOST=$BENTO_PUBLIC_HOST|" \
  -e "s|^BENTO_PG_PASSWORD=.*|BENTO_PG_PASSWORD=$pg_password|" \
  -e "s|^BENTO_JWT_SECRET=.*|BENTO_JWT_SECRET=$jwt_secret|" \
  -e "s|^BENTO_JWT_KEYS=.*|BENTO_JWT_KEYS=$jwt_keys|" \
  -e "s|^BENTO_PGRST_JWT_SECRET=.*|BENTO_PGRST_JWT_SECRET=$pgrst_jwks|" \
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
