#!/usr/bin/env bash

set -euo pipefail

STACK=""
ISSUER_DOMAIN=""
AWS_REGION=""
KMS_KEY_ID=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack)
      STACK="$2"
      shift 2
      ;;
    --issuer-domain)
      ISSUER_DOMAIN="$2"
      shift 2
      ;;
    --aws-region)
      AWS_REGION="$2"
      shift 2
      ;;
    --kms-key-id)
      KMS_KEY_ID="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

for name in STACK ISSUER_DOMAIN AWS_REGION KMS_KEY_ID OUTPUT_DIR; do
  if [[ -z "${!name}" ]]; then
    echo "${name} is required" >&2
    exit 1
  fi
done

issuer_host="${ISSUER_DOMAIN#https://}"
issuer_host="${issuer_host#http://}"
issuer_url="https://${issuer_host}/${STACK}"
jwks_url="${issuer_url}/.well-known/jwks.json"

temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

aws kms get-public-key --key-id "${KMS_KEY_ID}" --region "${AWS_REGION}" --query PublicKey --output text |
  base64 --decode >"${temp_dir}/public.der"

modulus_hex="$(
  openssl rsa -pubin -inform DER -in "${temp_dir}/public.der" -modulus -noout |
    sed 's/^Modulus=//'
)"
exponent_dec="$(
  openssl rsa -pubin -inform DER -in "${temp_dir}/public.der" -text -noout |
    awk '/Exponent: / { gsub(/[()]/, "", $2); print $2; exit }'
)"

read -r jwk_n jwk_e < <(
  python3 - "${modulus_hex}" "${exponent_dec}" <<'PY'
import base64
import sys

modulus = int(sys.argv[1], 16)
exponent = int(sys.argv[2], 10)

def encode_int(value: int) -> str:
    raw = value.to_bytes((value.bit_length() + 7) // 8, "big")
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

print(encode_int(modulus), encode_int(exponent))
PY
)

well_known_dir="${OUTPUT_DIR}/${STACK}/.well-known"
mkdir -p "${well_known_dir}"

cat >"${well_known_dir}/openid-configuration" <<EOF
{
  "issuer": "${issuer_url}",
  "jwks_uri": "${jwks_url}"
}
EOF

cat >"${well_known_dir}/jwks.json" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "RS256",
      "kid": "${KMS_KEY_ID}",
      "n": "${jwk_n}",
      "e": "${jwk_e}"
    }
  ]
}
EOF
