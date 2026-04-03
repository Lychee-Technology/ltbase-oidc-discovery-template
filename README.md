# LTBase OIDC Discovery Template

Template repository for customer-specific LTBase OIDC discovery companion sites.

## What It Publishes

For each stack, this repository publishes:

- `<stack>/.well-known/openid-configuration`
- `<stack>/.well-known/jwks.json`

The resulting issuer shape is:

- `https://<OIDC_DISCOVERY_DOMAIN>/<stack>`

## Required Repository Variables

- `OIDC_DISCOVERY_DOMAIN`
- `OIDC_DISCOVERY_STACK_CONFIG`

`OIDC_DISCOVERY_STACK_CONFIG` must be a JSON object keyed by stack name. Example:

```json
{
  "devo": {
    "aws_region": "ap-northeast-1",
    "aws_role_arn": "arn:aws:iam::123456789012:role/ltbase-oidc-discovery-devo"
  },
  "prod": {
    "aws_region": "us-west-2",
    "aws_role_arn": "arn:aws:iam::210987654321:role/ltbase-oidc-discovery-prod"
  }
}
```

## Publishing

Use the `Publish OIDC Discovery` workflow and choose either:

- `all`
- a single stack name such as `devo`

Each render job assumes the configured discovery role for that stack, fetches the KMS public key from `alias/ltbase-infra-<stack>-authservice`, generates discovery documents, and commits the published output back to the repository.
