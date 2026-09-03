# AWS Secrets Manager (Bitrise Step)

Fetches secrets from [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/) and exports them as Environment Variables for subsequent Steps.

Compatible with the auth model of
[`authenticate-with-aws`](https://github.com/bitrise-steplib/bitrise-step-authenticate-with-aws)
(OIDC via Bitrise identity token, access keys, or ambient `AWS_*`).

## Usage

### With prior Authenticate with AWS (recommended)

Authenticate once, then fetch secrets **without** re-assuming the same role.
Omit `account` / `role_name` so ambient `AWS_*` from the previous Step are used as-is.

```yaml
- authenticate-with-aws@1:
    inputs:
    - region: eu-west-1
    - audience: sts.amazonaws.com
    - role_arn: arn:aws:iam::123456789012:role/my-bitrise-role
- git::https://github.com/momenshataly/aws-secrets-manager.git@main:
    title: Fetch AWS secrets
    inputs:
    - secrets: |
        APP,my-app/config
        ,my-app/config,API_TOKEN
```

### Assume a (different) secrets role after Authenticate with AWS

Pass **both** `account` and `role_name` to call STS `AssumeRole` into that role.
The bootstrap role must be allowed to assume the secrets role.

```yaml
- authenticate-with-aws@1:
    inputs:
    - region: us-east-1
    - audience: sts.amazonaws.com
    - role_arn: arn:aws:iam::123456789012:role/my-bitrise-bootstrap-role
- git::https://github.com/momenshataly/aws-secrets-manager.git@main:
    inputs:
    - account: "123456789012"
    - role_name: my-secrets-readonly-role
    - secrets: |
        APP,my-app/config,API_TOKEN|DB_PASSWORD
```

Prior `AWS_*` credentials are restored after secrets are exported when a role was assumed.

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

Pin a tag or commit SHA instead of `main` for reproducible builds.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `secrets` | _(required)_ | Secret lines (see format below) |
| `account` | empty | AWS account ID — required **with** `role_name` to assume a role; omit both to use ambient `AWS_*` |
| `region` | empty | AWS region; else keeps ambient region; else `us-east-1` |
| `role_name` | empty | IAM role name — required **with** `account` to assume; omit both for ambient creds |
| `name_transformation` | `uppercase` | `uppercase` / `lowercase` / `none` |
| `parse_json_secrets` | `true` | One env var per JSON key |
| `audience` | empty | OIDC audience when assuming via OIDC |
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

1. If **both** `account` and `role_name` are set:
   - Ambient `AWS_*` → STS `AssumeRole` into that role
   - Else `audience` → OIDC → `AssumeRoleWithWebIdentity`
   - Else access key inputs → then `AssumeRole`
2. If **neither** `account` nor `role_name` is set:
   - Ambient `AWS_*` → use as-is (no AssumeRole)
   - Else access key inputs → use as-is
3. Passing only one of `account` / `role_name` → fail
4. Else → fail

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
