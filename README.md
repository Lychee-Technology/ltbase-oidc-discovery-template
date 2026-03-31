# LTBase OIDC Discovery Template

Template repository for LTBase OIDC discovery companion repos. Companion repos serve [OpenID Connect Discovery](https://openid.net/specs/openid-connect-discovery-1_0.html) documents (JWKS and openid-configuration) for each deployment stack via Cloudflare Pages.

This repo is used as a template — do not modify it directly for a specific deployment. Instead, use `bootstrap-oidc-discovery-companion.sh` from your private deployment repo to create a companion repo from this template.

---

**LTBase OIDC Discovery 模板仓库。** 伴随仓库通过 Cloudflare Pages 为每个部署环境提供 OpenID Connect Discovery 文档（JWKS 和 openid-configuration）。

本仓库仅作为模板使用，请勿直接修改。请通过私有部署仓库中的 `bootstrap-oidc-discovery-companion.sh` 脚本创建伴随仓库。

---

## How It Works / 工作原理

The `publish-discovery.yml` workflow:

1. Reads stack configuration from the `OIDC_DISCOVERY_STACK_CONFIG` repo variable
2. For each stack, assumes an IAM role via GitHub OIDC federation (no static credentials)
3. Fetches the RSA public key from the stack's KMS auth signing key
4. Generates `<stack>/.well-known/jwks.json` (RFC 7517) and `<stack>/.well-known/openid-configuration`
5. Commits the generated files — Cloudflare Pages auto-deploys on push

`publish-discovery.yml` 工作流：

1. 从 `OIDC_DISCOVERY_STACK_CONFIG` 仓库变量读取环境配置
2. 对每个环境，通过 GitHub OIDC 联合身份认证获取 IAM 角色（无需静态凭据）
3. 从环境的 KMS 认证签名密钥获取 RSA 公钥
4. 生成 `<stack>/.well-known/jwks.json`（RFC 7517）和 `<stack>/.well-known/openid-configuration`
5. 提交生成的文件 — Cloudflare Pages 自动部署

## Required Repo Variables / 必需的仓库变量

These are set automatically by `bootstrap-oidc-discovery-companion.sh`. Do not set them manually unless troubleshooting.

以下变量由 `bootstrap-oidc-discovery-companion.sh` 自动设置。除非排查问题，否则请勿手动设置。

| Variable | Description |
|----------|-------------|
| `OIDC_DISCOVERY_DOMAIN` | Custom domain for the Cloudflare Pages site (e.g., `oidc.example.com`) |
| `OIDC_DISCOVERY_STACK_CONFIG` | JSON object mapping each stack to its AWS region, IAM role ARN, and KMS key alias |

### `OIDC_DISCOVERY_STACK_CONFIG` format

```json
{
  "devo": {
    "aws_region": "ap-northeast-1",
    "aws_role_arn": "arn:aws:iam::123456789012:role/my-ltbase-oidc-discovery-devo",
    "kms_auth_key_alias": "alias/ltbase-infra-devo-authservice"
  },
  "prod": {
    "aws_region": "us-west-2",
    "aws_role_arn": "arn:aws:iam::210987654321:role/my-ltbase-oidc-discovery-prod",
    "kms_auth_key_alias": "alias/ltbase-infra-prod-authservice"
  }
}
```

## Running the Workflow / 运行工作流

Go to **Actions → Publish OIDC Discovery Documents → Run workflow**.

- **target_stack** = `all` (default): publish all stacks
- **target_stack** = `devo`: publish only the devo stack

前往 **Actions → Publish OIDC Discovery Documents → Run workflow**。

- **target_stack** = `all`（默认）：发布所有环境
- **target_stack** = `devo`：仅发布 devo 环境

## Output / 输出

After the workflow runs, the repo contains:

```
devo/.well-known/jwks.json
devo/.well-known/openid-configuration
prod/.well-known/jwks.json
prod/.well-known/openid-configuration
```

Served at:
- `https://<OIDC_DISCOVERY_DOMAIN>/devo/.well-known/jwks.json`
- `https://<OIDC_DISCOVERY_DOMAIN>/devo/.well-known/openid-configuration`

## Security / 安全

- **No secrets stored.** IAM roles use GitHub OIDC federation — the workflow exchanges a short-lived GitHub token for temporary AWS credentials.
- **KMS keys never leave AWS.** Only the public key is retrieved; private key material stays in KMS.
- **Read-only KMS access.** IAM roles only have `kms:GetPublicKey` and `kms:DescribeKey` permissions.

**无需存储密钥。** IAM 角色使用 GitHub OIDC 联合身份认证。KMS 密钥始终留在 AWS 中，仅获取公钥。IAM 角色仅具有 `kms:GetPublicKey` 和 `kms:DescribeKey` 权限。
