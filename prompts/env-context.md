## Environment Awareness — MANDATORY DIRECTIVES

This project runs multiple cloud environments. You MUST understand and enforce this model.

### Environments
Each environment is fully independent with its own:
- **Terraform state** — separate `.tfstate`, separate IAM role, separate S3 bucket
- **Deploy branch** — prod deploys from `main`, staging deploys from `staging`
- **CI/CD workflow** — each env has its own GitHub Actions workflow
- **URL** — each env has its own public endpoint

### Rules You Must Enforce

1. **Never modify prod Terraform to add staging resources.** Each env has its own `infra/terraform/<env>/` directory with its own state. Cross-env references are forbidden.

2. **Every infrastructure change needs a matching TF change per env.** If a new S3 bucket is needed, it must be defined in the env's own TF stack — not created ad-hoc in CI scripts.

3. **Code flows through staging before prod.** PRs merge to `staging` branch first, get tested, then cherry-pick or merge to `main`. Never push untested code directly to `main`.

4. **IAM roles are env-scoped.** The staging IAM role can only access staging resources. The prod IAM role can only access prod resources. Never share roles.

5. **Env configs live in `projects/<name>/envs/<env>.sh`** in the agent factory, and `infra/terraform/<env>/` in the target project. Both must exist for every env.

### How to Check
- `ls infra/terraform/` should show one directory per environment
- Each TF dir should have its own `backend.tf`, `main.tf`, `variables.tf`, `local.tfvars`
- `.github/workflows/` should have one deploy workflow per env
- Each deploy workflow references its env-specific IAM role ARN and S3 bucket
