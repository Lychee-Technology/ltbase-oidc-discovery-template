#!/usr/bin/env bash
set -euo pipefail

# Required environment variables:
#   OIDC_DISCOVERY_DOMAIN        – custom domain for discovery documents
#   OIDC_DISCOVERY_STACK_CONFIG  – JSON mapping stack name -> {aws_region, aws_role_arn, kms_auth_key_alias}
#   OIDC_DISCOVERY_OUTPUT_DIR    – directory to write generated files into
# Optional:
#   TARGET_STACK                 – "all" (default) or a specific stack name

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATE_JWKS="${SCRIPT_DIR}/generate-jwks.py"

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

# --- validate required vars ---

: "${OIDC_DISCOVERY_DOMAIN:?}"
: "${OIDC_DISCOVERY_STACK_CONFIG:?}"
: "${OIDC_DISCOVERY_OUTPUT_DIR:?}"

if ! echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "OIDC_DISCOVERY_STACK_CONFIG must be a valid JSON object"
fi

TARGET_STACK="${TARGET_STACK:-all}"

# --- determine stacks ---

if [[ "${TARGET_STACK}" == "all" ]]; then
  stacks=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    stacks+=("${line}")
  done < <(echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -r 'keys[]')
else
  if ! echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -e --arg s "${TARGET_STACK}" '.[$s]' >/dev/null 2>&1; then
    fail "Stack '${TARGET_STACK}' not found in OIDC_DISCOVERY_STACK_CONFIG"
  fi
  stacks=("${TARGET_STACK}")
fi

for stack in "${stacks[@]}"; do
  if [[ ! "${stack}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "Invalid stack name '${stack}' in OIDC_DISCOVERY_STACK_CONFIG"
  fi
done

# --- stale stack cleanup (all only) ---

if [[ "${TARGET_STACK}" == "all" ]]; then
  tmp_configured="$(mktemp)"
  for stack in "${stacks[@]}"; do
    printf '%s\n' "${stack}" >> "${tmp_configured}"
  done

  shopt -s nullglob
  for stack_dir in "${OIDC_DISCOVERY_OUTPUT_DIR}"/*/; do
    stack_dir=${stack_dir%/}
    stack_name="${stack_dir##*/}"
    if [[ -d "${stack_dir}/.well-known" ]] && ! grep -qFx "${stack_name}" "${tmp_configured}" 2>/dev/null; then
      rm -rf "${stack_dir}"
      echo "Removed stale stack: ${stack_name}"
    fi
  done
  shopt -u nullglob
  rm -f "${tmp_configured}"
fi

# --- generate per-stack documents ---

mkdir -p "${OIDC_DISCOVERY_OUTPUT_DIR}"

current_stack_manifest="$(mktemp)"
trap 'rm -f "${current_stack_manifest}"' EXIT

for stack in "${stacks[@]}"; do
  echo "::group::${stack}"

  aws_region=$(echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -r --arg s "${stack}" '.[$s].aws_region')
  aws_role_arn=$(echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -r --arg s "${stack}" '.[$s].aws_role_arn')
  kms_alias=$(echo "${OIDC_DISCOVERY_STACK_CONFIG}" | jq -r --arg s "${stack}" '.[$s].kms_auth_key_alias')

  # Obtain a fresh GitHub OIDC token and assume the stack IAM role.
  oidc_token_response=$(curl -sS -f \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com") || fail "Failed to obtain GitHub OIDC token"

  oidc_token=$(echo "${oidc_token_response}" | jq -r '.value')
  if [[ -z "${oidc_token}" || "${oidc_token}" == "null" ]]; then
    fail "GitHub OIDC token value is empty"
  fi

  creds=$(AWS_DEFAULT_REGION="${aws_region}" aws sts assume-role-with-web-identity \
    --role-arn "${aws_role_arn}" \
    --role-session-name "oidc-discovery-${stack}" \
    --web-identity-token "${oidc_token}" \
    --duration-seconds 900 \
    --output json) || fail "Failed to assume role ${aws_role_arn}"

  export AWS_ACCESS_KEY_ID=$(echo "${creds}" | jq -r '.Credentials.AccessKeyId')
  export AWS_SECRET_ACCESS_KEY=$(echo "${creds}" | jq -r '.Credentials.SecretAccessKey')
  export AWS_SESSION_TOKEN=$(echo "${creds}" | jq -r '.Credentials.SessionToken')
  export AWS_DEFAULT_REGION="${aws_region}"

  # Fetch the RSA public key from KMS.
  public_key_json=$(aws kms get-public-key --key-id "${kms_alias}" --output json) || fail "Failed to get KMS public key for ${kms_alias}"
  public_key_b64=$(echo "${public_key_json}" | jq -r '.PublicKey')
  key_id=$(echo "${public_key_json}" | jq -r '.KeyId')

  # Generate JWKS.
  mkdir -p "${OIDC_DISCOVERY_OUTPUT_DIR}/${stack}/.well-known"
  python3 "${GENERATE_JWKS}" \
    --public-key-b64 "${public_key_b64}" \
    --key-id "${key_id}" \
    > "${OIDC_DISCOVERY_OUTPUT_DIR}/${stack}/.well-known/jwks.json"

  # Generate openid-configuration.
  python3 -c "
import json, sys
domain = sys.argv[1]
stack = sys.argv[2]
print(json.dumps({
    'issuer': f'https://{domain}/{stack}',
    'jwks_uri': f'https://{domain}/{stack}/.well-known/jwks.json',
    'response_types_supported': ['id_token'],
    'subject_types_supported': ['public'],
    'id_token_signing_alg_values_supported': ['RS256'],
}, indent=2))" "${OIDC_DISCOVERY_DOMAIN}" "${stack}" \
    > "${OIDC_DISCOVERY_OUTPUT_DIR}/${stack}/.well-known/openid-configuration"

  echo "Published: ${stack}/.well-known/jwks.json"
  echo "Published: ${stack}/.well-known/openid-configuration"

  printf '%s\n' "${stack}" >> "${current_stack_manifest}"

  # Clear per-stack credentials.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION

  echo "::endgroup::"
done

# --- generate _headers ---

headers_file="${OIDC_DISCOVERY_OUTPUT_DIR}/_headers"
: > "${headers_file}"

while IFS= read -r stack; do
  [[ -n "${stack}" ]] || continue
  printf '/%s/.well-known/openid-configuration\n  Content-Type: application/json; charset=utf-8\n\n/%s/.well-known/jwks.json\n  Content-Type: application/json; charset=utf-8\n\n' \
    "${stack}" "${stack}" >> "${headers_file}"
done < "${current_stack_manifest}"
