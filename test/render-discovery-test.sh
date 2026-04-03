#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/scripts/render-discovery.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local needle="$2"
  if [[ ! -f "${path}" ]]; then
    fail "missing file: ${path}"
  fi
  if ! grep -Fq "${needle}" "${path}"; then
    fail "expected ${path} to contain: ${needle}"
  fi
}

temp_dir="$(mktemp -d)"
fake_bin="${temp_dir}/bin"
mkdir -p "${fake_bin}" "${temp_dir}/output"

openssl genrsa -out "${temp_dir}/private.pem" 2048 >/dev/null 2>&1
openssl rsa -in "${temp_dir}/private.pem" -pubout -outform DER -out "${temp_dir}/public.der" >/dev/null 2>&1
public_key_b64="$(base64 <"${temp_dir}/public.der" | tr -d '\n')"

cat >"${fake_bin}/aws" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\$1 \$2" == "kms get-public-key" ]]; then
  printf '%s\n' '${public_key_b64}'
  exit 0
fi
exit 1
EOF
chmod +x "${fake_bin}/aws"

if ! PATH="${fake_bin}:$PATH" "${SCRIPT_PATH}" \
  --stack devo \
  --issuer-domain oidc.customer.example \
  --aws-region ap-northeast-1 \
  --kms-key-id alias/ltbase-infra-devo-authservice \
  --output-dir "${temp_dir}/output"; then
  rm -rf "${temp_dir}"
  fail "expected discovery renderer to succeed"
fi

assert_file_contains "${temp_dir}/output/devo/.well-known/openid-configuration" '"issuer": "https://oidc.customer.example/devo"'
assert_file_contains "${temp_dir}/output/devo/.well-known/openid-configuration" '"jwks_uri": "https://oidc.customer.example/devo/.well-known/jwks.json"'
assert_file_contains "${temp_dir}/output/devo/.well-known/jwks.json" '"keys"'
assert_file_contains "${temp_dir}/output/devo/.well-known/jwks.json" '"kty": "RSA"'
assert_file_contains "${temp_dir}/output/devo/.well-known/jwks.json" '"alg": "RS256"'
assert_file_contains "${temp_dir}/output/devo/.well-known/jwks.json" '"kid": "alias/ltbase-infra-devo-authservice"'

rm -rf "${temp_dir}"
printf 'PASS: render-discovery tests\n'
