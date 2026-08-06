# AWS Secrets Manager (Bitrise Step)

Fetches secrets from [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/) and exports them as Environment Variables for subsequent Steps.

Compatible with the auth model of
[`authenticate-with-aws`](https://github.com/bitrise-steplib/bitrise-step-authenticate-with-aws)
(OIDC via Bitrise identity token, access keys, or ambient `AWS_*`).

## Usage

```yaml
- git::https://github.com/momenshataly/aws-secrets-manager.git@main:
    title: Fetch AWS secrets
    inputs:
    - account: "123456789012"
    - region: us-east-1
    - role_name: my-secrets-readonly-role
    - secrets: |
        APP,my-app/config
        ,my-app/config,API_TOKEN
```

Pin a tag or commit SHA instead of `main` for reproducible builds.

### With prior Authenticate with AWS

```yaml
- authenticate-with-aws@1:
    inputs:
    - region: us-east-1
    - audience: sts.amazonaws.com
    - role_arn: arn:aws:iam::123456789012:role/my-bitrise-role
- git::https://github.com/momenshataly/aws-secrets-manager.git@main:
    inputs:
    - account: "123456789012"
    - role_name: my-secrets-readonly-role
    - secrets: |
        APP,my-app/config,API_TOKEN|DB_PASSWORD
```

The Step assumes the secrets role, exports secrets, then restores the prior `AWS_*` credentials.

### Standalone OIDC

```yaml
- git::https://github.com/momenshataly/aws-secrets-manager.git@main:
    inputs:
    - account: "123456789012"
    - audience: sts.amazonaws.com
    - role_name: my-secrets-readonly-role
    - secrets: |
        APP,my-app/config
```

The secrets IAM role must trust the Bitrise OIDC provider (`token.builds.bitrise.io`). See [OIDC for AWS](https://docs.bitrise.io/en/bitrise-platform/integrations/oidc-authentication/oidc-for-aws.html).

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `secrets` | _(required)_ | Secret lines (see format below) |
| `account` | _(required)_ | AWS account ID for the role ARN |
| `region` | `us-east-1` | AWS region |
| `role_name` | _(required)_ | IAM role name in the secrets account |
| `name_transformation` | `uppercase` | `uppercase` / `lowercase` / `none` |
| `parse_json_secrets` | `true` | One env var per JSON key |
| `audience` | empty | OIDC audience when no ambient `AWS_*` |
| `access_key_id` / `secret_access_key` | empty | Static key fallback |
| `session_name` | `bitrise-$BITRISE_BUILD_NUMBER` | STS session name |
| `verbose` | `false` | Debug logging (never logs secret values) |

## Secret line format

- **All keys:** `PREFIX,secret-id` or `secret-id`
- **Selective keys:** `PREFIX,secret-id,key1|key2|key3`

Examples:

```yaml
secrets: |
  APP,my-app/config
  ,my-app/config
  APP,my-app/config,API_TOKEN|DB_PASSWORD
  OTHER,other-app/settings
```

With `parse_json_secrets: true` and prefix `APP`, JSON key `api_token` becomes `APP_API_TOKEN` (with `uppercase` transformation).

Selective mode fails if a listed key is missing from the secret JSON (strict).

## Authentication

1. If `AWS_ACCESS_KEY_ID` is already set → STS `AssumeRole` into `arn:aws:iam::{account}:role/{role_name}`
2. Else if `audience` is set → Bitrise OIDC → `AssumeRoleWithWebIdentity`
3. Else if access key inputs are set → use them, then `AssumeRole`
4. Else → fail

Ambient static keys only work if IAM allows them to assume the secrets role.

## Requirements

- `aws` CLI v2
- `jq`
- `curl`
- `envman` (available on Bitrise)

Declared as `deps` in `step.yml` for brew/apt where applicable.

## Local parse test

```bash
./test/test-parse-secrets.sh
```
