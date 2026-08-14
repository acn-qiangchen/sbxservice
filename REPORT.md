# sbxservice-infra — Repository Review Report

> **Generated**: 2026-08-14  
> **Repository**: `sbxservice-infra`  
> **Branch**: `master`  
> **Purpose**: AWS infrastructure-as-code (IaC) for the SBXService sandbox/POC platform

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Repository Structure](#2-repository-structure)
3. [Technology Stack](#3-technology-stack)
4. [Infrastructure Architecture](#4-infrastructure-architecture)
5. [CI/CD Pipeline](#5-cicd-pipeline)
6. [Security Assessment](#6-security-assessment)
7. [Code Quality & Conventions](#7-code-quality--conventions)
8. [Documentation Coverage](#8-documentation-coverage)
9. [Risks & Issues](#9-risks--issues)
10. [Recommendations](#10-recommendations)

---

## 1. Executive Summary

`sbxservice-infra` is a **Terraform-only AWS infrastructure repository** for a sandbox/POC environment. It provisions a complete cloud-native API platform centred on **Kong Gateway OSS** running on **AWS ECS Fargate**, fronted by API Gateway and protected by Network Firewall. The codebase is modular, reasonably well-documented, and uses OIDC-based GitHub Actions for CI/CD.

The project is in **active POC / exploratory** state. Several production-readiness gaps exist that should be addressed before any production use: hardcoded credentials in a bootstrap script, no branch protection triggers on CI, a hardcoded AWS account ID in backend configuration, and incomplete wiring of the Network Firewall module.

---

## 2. Repository Structure

```
sbxservice-infra/
├── .cursor/rules/             # Cursor IDE AI coding rules
├── .github/
│   └── workflows/
│       └── terraform.yml      # GitHub Actions CI/CD (manual dispatch only)
├── docs/                      # Architecture & operational documentation
│   ├── CONVENTIONS.md
│   ├── system_architecture.md
│   ├── poc_architecture.md
│   ├── dual-nlb-routing.md
│   ├── architecture/
│   │   └── network_firewall.md
│   ├── kong_gateway_guide.md
│   ├── kong_admin_api_reference.md
│   ├── kong_testing_guide.md
│   ├── kong_troubleshooting.md
│   └── github_actions_*.md
├── scripts/
│   ├── deploy.sh              # ECS force-new-deployment helper
│   ├── kong-setup.sh          # Kong Admin API bootstrap (services/routes)
│   ├── setup-github-actions-role.sh
│   └── github-actions-trust-policy.json
├── terraform/
│   ├── main.tf                # Root module — wires all child modules
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf             # S3 + DynamoDB remote state
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/
│       ├── security_groups/
│       ├── ecs/
│       ├── api_gateway/
│       ├── rds/
│       ├── network_firewall/  # Defined but not wired into root main.tf
│       └── app_mesh/          # Defined but appears unused
├── kong-dp-bootstrap.sh       # ⚠️ Contains embedded mTLS certificates
└── README.md
```

---

## 3. Technology Stack

| Layer | Technology |
|---|---|
| **IaC** | Terraform ≥ 1.0.0 (AWS provider `~> 5.0`) |
| **Compute** | AWS ECS Fargate |
| **API Gateway** | Kong Gateway OSS (CP/DP split) + AWS API Gateway (REST, REGIONAL) |
| **Database** | AWS RDS PostgreSQL 13 |
| **Networking** | Custom VPC, public/private subnets, NAT Gateways, IGW |
| **DNS & TLS** | AWS Route53, AWS ACM (wildcard via DNS validation) |
| **Container Registry** | AWS ECR (in a separate `sbxservice-apps` repo) |
| **Monitoring** | CloudWatch Logs, Metrics, Alarms, Container Insights |
| **Security** | AWS Network Firewall, AWS Secrets Manager |
| **Service Discovery** | AWS Cloud Map |
| **CI/CD** | GitHub Actions with OIDC |

---

## 4. Infrastructure Architecture

### 4.1 Networking (`vpc` module)

- **VPC CIDR**: `10.0.0.0/16` (default)
- **Availability Zones**: `us-east-1a`, `us-east-1b`
- Public and private subnets in each AZ
- One NAT Gateway per AZ for private subnet egress
- **VPC Interface Endpoints**: ECR API, ECR DKR, CloudWatch Logs
- **VPC Gateway Endpoint**: S3

### 4.2 Security Groups (`security_groups` module)

| Group | Inbound |
|---|---|
| `public-sg` | HTTP (80), HTTPS (443), Kong Admin API (8001), Kong Admin GUI (8002) — **all from `0.0.0.0/0`** |
| `app-sg` | All traffic from `public-sg` and within VPC CIDR |
| `database-sg` | Traffic from `app-sg` only |

> ⚠️ **Note**: Kong Admin API (port 8001) and Admin GUI (port 8002) are open to the public internet in `public-sg`. This is a serious exposure if these ports are associated with a public-facing resource.

### 4.3 Compute & Kong Gateway (`ecs` module)

- **ECS Cluster** with Container Insights enabled
- **Kong CP/DP architecture**: Control Plane and Data Plane run as separate ECS tasks
- mTLS cluster certificates stored in AWS Secrets Manager
- **AWS Cloud Map** private DNS namespace for service discovery (`{project}.{env}.local`)
- Service Discovery entries for `hello-service` and `kong-gateway`
- **ECS Exec** enabled for ad-hoc debugging

**Load Balancers**:
| LB | Purpose |
|---|---|
| Application Load Balancer | HTTPS termination (ACM cert), routes to Kong or Hello-Service |
| Network Load Balancer (proxy) | Kong proxy traffic |
| Network Load Balancer (direct) | Direct routing to Hello-Service |
| Network Load Balancer (admin) | Kong Admin API access |

**Dual NLB Weighted Routing**: Traffic is split between Kong Gateway and a direct Hello-Service path via weighted target groups, controlled by `kong_traffic_weight` / `direct_traffic_weight` variables.

### 4.4 Database (`rds` module)

- PostgreSQL 13 on RDS
- `gp3` storage, encrypted at rest
- Multi-AZ: disabled by default
- Enhanced Monitoring (60-second interval)
- Performance Insights (7-day retention)
- CloudWatch Alarms: CPU, freeable memory, storage, DB connections
- Connection logging via DB parameter group

### 4.5 API Gateway (`api_gateway` module)

- AWS REST API Gateway (REGIONAL type)
- HTTP_PROXY integration to ALB custom domain
- Root resource (`ANY`) + catch-all proxy resource (`{proxy+}`)
- CloudWatch log group for request logging

### 4.6 Network Firewall (`network_firewall` module)

- AWS Network Firewall with **STRICT_ORDER stateful rules**
- Custom HTTP header inspection: blocks `attack` headers, XSS, SQL injection attempts
- Integrates AWS-managed `ThreatSignaturesScannersStrictOrder` rule group
- TLS inspection configuration
- **⚠️ Not currently wired into `main.tf`** — module defined but not called from root

### 4.7 Domain Naming Convention

| Resource | Pattern |
|---|---|
| Base domain | `{aws_account_id}.realhandsonlabs.net` |
| ALB custom domain | `alb.{aws_account_id}.realhandsonlabs.net` |
| ACM Certificate | Wildcard for the base domain |

---

## 5. CI/CD Pipeline

**File**: `.github/workflows/terraform.yml`

### Trigger
- **Manual only** (`workflow_dispatch`) — no automatic push or PR triggers

### Inputs
| Input | Options |
|---|---|
| `environment` | `dev`, `test`, `prod` |
| `tag` | Container image tag |
| `aws_account_id` | Target AWS account |

### Pipeline Steps
1. Checkout code
2. Configure AWS credentials via **OIDC** (`github-actions-role`)
3. Bootstrap Terraform state: create S3 bucket + DynamoDB lock table (idempotent)
4. `terraform init` (dynamic backend config)
5. `terraform fmt -check`
6. `terraform validate`
7. Construct ECR image URL
8. Write `terraform.tfvars`
9. `terraform plan -out=tfplan`
10. `terraform apply -auto-approve tfplan`
11. Post outputs to GitHub Step Summary

### State Backend Naming
| Resource | Pattern |
|---|---|
| S3 Bucket | `sbxservice-terraform-state-{account_id}` (versioned, encrypted) |
| DynamoDB Table | `sbxservice-terraform-locks-{account_id}` |

---

## 6. Security Assessment

### 6.1 Critical Issues

| # | Issue | Location | Severity |
|---|---|---|---|
| 1 | **Embedded mTLS certificates in shell script** | `kong-dp-bootstrap.sh` | 🔴 Critical |
| 2 | **Kong Admin ports (8001, 8002) open to `0.0.0.0/0`** | `terraform/modules/security_groups/main.tf:27` | 🔴 Critical |
| 3 | **Default Kong DB password committed to repo and docs** | `terraform/variables.tf:104` | 🔴 Critical |

**Finding 1 — Hardcoded certificates**: `kong-dp-bootstrap.sh` contains inline `KONG_CLUSTER_CERT` and related private key material. This script is committed to version control, meaning the private key is exposed to anyone with repo access. Keys should be stored exclusively in AWS Secrets Manager and fetched at runtime.

**Finding 2 — Admin port exposure**: The `public-sg` security group allows inbound traffic on ports 8001 (Kong Admin API) and 8002 (Kong Admin GUI) from `0.0.0.0/0`. These ports expose full administrative control of Kong with no default authentication. An attacker can add/delete routes, install plugins, extract configuration, or configure the gateway to proxy to arbitrary backends. These ports must be restricted to bastion/management CIDRs or removed from public-facing security groups entirely.

**Finding 3 — Hardcoded default password**: `variables.tf` contains `default = "KongPassword123!"` for `kong_db_password`. This default is also documented verbatim in `docs/github_actions_quick_start.md` and `docs/kong_gateway_guide.md`. Any deployment that does not explicitly override this variable provisions a database with a publicly known password. The default must be removed and the variable must be required.

### 6.2 High Issues

| # | Issue | Location | Severity |
|---|---|---|---|
| 4 | **IAM trust policy grants all repos in the org** | `scripts/github-actions-trust-policy.json:15` | 🟠 High |
| 5 | **`kong migrations bootstrap` runs unconditionally on every restart** | `terraform/modules/ecs/main.tf:620` | 🟠 High |
| 6 | **Terraform plan-time panic: `kong_control_plane_enabled` without `kong_db_enabled`** | `terraform/modules/ecs/main.tf:609` | 🟠 High |
| 7 | **Hardcoded AWS account ID in `backend.tf`** | `terraform/backend.tf` | 🟠 High |
| 8 | **Network Firewall not wired into root module** | `terraform/main.tf` | 🟠 High |
| 9 | **`terraform apply -auto-approve` in CI** | `.github/workflows/terraform.yml` | 🟠 High |

**Finding 4 — Overly broad IAM OIDC trust**: The trust policy uses `repo:acn-qiangchen/*:*`, which matches **every repository** in the `acn-qiangchen` GitHub org. Any team member with write access to any repo in the org can trigger a workflow that assumes the deployment role and gains full infrastructure access. Restrict to `repo:acn-qiangchen/sbxservice-infra:*`.

**Finding 5 — `kong migrations bootstrap` on every restart**: The Kong CP container start command is `kong migrations bootstrap && kong migrations up && kong start`. `bootstrap` fails fatally if the schema already exists. On every ECS task restart after the first deployment (rolling updates, task replacements, auto-scaling events), the CP container exits non-zero, ECS retries indefinitely, and Kong is never available. Replace with `kong migrations up --v` or use an init container / entrypoint guard.

**Finding 6 — Conditional resource dereference panic**: If `kong_control_plane_enabled = true` but `kong_db_enabled = false`, Terraform dereferences `aws_secretsmanager_secret.kong_db_password[0].arn` where the list is empty. This causes a plan-time `Invalid index` error and the deployment cannot proceed. The CP task definition must be guarded by the same condition as the secret it references.

**Finding 7**: `backend.tf` contains a real account ID (`891376925337`) hardcoded. The CI workflow already parameterises this via `aws_account_id` input — the backend config should use a variable or environment substitution consistently.

**Finding 8**: The `network_firewall` module is fully implemented with XSS/SQLi/header-inspection rules but is never instantiated in `main.tf`. This means the firewall is not protecting the environment.

**Finding 9**: `terraform apply -auto-approve` skips human review of the plan. Even in a POC, a plan approval gate (e.g., using `terraform apply` with manual approval in GitHub Actions environments) reduces risk of unintended destructive changes.

### 6.3 Medium Issues

| # | Issue | Location | Severity |
|---|---|---|---|
| 10 | **`timestamp()` in `final_snapshot_identifier` causes perpetual plan diff** | `terraform/modules/rds/main.tf:74` | 🟡 Medium |
| 11 | **RDS Multi-AZ disabled by default** | `terraform/modules/rds/` | 🟡 Medium |
| 12 | **No branch protection / CI auto-trigger** | `.github/workflows/` | 🟡 Medium |
| 13 | **ECS Exec enabled in all environments** | `terraform/modules/ecs/` | 🟡 Medium |

**Finding 10 — Perpetual plan diff**: `final_snapshot_identifier = "...-${timestamp()}"` re-evaluates on every `terraform plan`. Every plan shows a pending change on the RDS instance even when nothing else changed. This blocks clean change detection in CI and may trigger unintended in-place updates. Use a static suffix based on the environment name instead.

**Finding 11**: Kong relies on RDS for config persistence. Single-AZ RDS means a Kong outage during AZ failure. Enable Multi-AZ for any non-dev environment.

**Finding 12**: CI is manual-dispatch only. Without automatic PR validation, Terraform formatting/validation errors can reach `master` undetected.

**Finding 13**: ECS Exec (SSM-based shell access) should be disabled in prod-equivalent environments and gated behind an additional IAM policy for operators.

---

## 7. Code Quality & Conventions

### Strengths
- **Modular Terraform**: Clean separation into `vpc`, `security_groups`, `ecs`, `api_gateway`, `rds`, `network_firewall`, `app_mesh` modules
- **Consistent variable passing**: Root `main.tf` passes variables explicitly to each module
- **Tagging strategy**: Resources are tagged consistently with `project`, `environment`, and `managed_by = "terraform"`
- **OIDC authentication**: No long-lived AWS access keys in CI — uses OIDC for credential-less authentication
- **Remote state**: S3 backend with DynamoDB locking prevents concurrent state corruption

### Issues
- **`app_mesh` module**: Appears unused in the current POC. Dead code should be removed or clearly marked as future work.
- **`network_firewall` module**: Fully implemented but never called — creates confusion about actual security posture.
- **`backend.tf` vs. root `terraform {}` block**: `main.tf` has the S3 backend commented out in its `terraform {}` block while `backend.tf` defines it separately. This could cause confusion; pick one pattern.
- **`.cursor/rules/sdxservice-rule.mdc`**: References `sdxservice` (note: **s** vs. **sb**x) — possible typo in the project name.
- **Cursor rule requires Japanese for git commit messages**: This convention may create friction for non-Japanese team members and should be explicitly documented.

---

## 8. Documentation Coverage

| Document | Status | Notes |
|---|---|---|
| `README.md` | ✅ Present | Overview and quick-start instructions |
| `docs/CONVENTIONS.md` | ✅ Present | Docker, ECS, Terraform conventions |
| `docs/system_architecture.md` | ⚠️ Placeholder | Lists services but lacks actual diagrams |
| `docs/poc_architecture.md` | ✅ Present | POC-specific architecture |
| `docs/dual-nlb-routing.md` | ✅ Present | Dual NLB design rationale |
| `docs/architecture/network_firewall.md` | ✅ Present | Network Firewall architecture |
| `docs/kong_*.md` | ✅ Present (×5) | Comprehensive Kong operational guides |
| `docs/github_actions_*.md` | ✅ Present (×2) | GitHub Actions setup |
| **CLAUDE.md** | ❌ Missing | No Claude Code project context file |
| **CHANGELOG** | ❌ Missing | No change history |
| **ADR (Architecture Decision Records)** | ❌ Missing | Design rationale not formally captured |

---

## 9. Risks & Issues Summary

| ID | Risk | Severity | File | Status |
|---|---|---|---|---|
| R1 | mTLS private key committed to repo | 🔴 Critical | `kong-dp-bootstrap.sh` | Open |
| R2 | Kong Admin API/GUI exposed to internet | 🔴 Critical | `modules/security_groups/main.tf:27` | Open |
| R3 | Default DB password in code and docs | 🔴 Critical | `terraform/variables.tf:104` | Open |
| R4 | OIDC trust grants entire GitHub org | 🟠 High | `scripts/github-actions-trust-policy.json:15` | Open |
| R5 | Kong CP crashes on every restart (migrations bootstrap) | 🟠 High | `modules/ecs/main.tf:620` | Open |
| R6 | Terraform panic: CP enabled without DB enabled | 🟠 High | `modules/ecs/main.tf:609` | Open |
| R7 | Hardcoded account ID in backend | 🟠 High | `terraform/backend.tf` | Open |
| R8 | Network Firewall not active | 🟠 High | `terraform/main.tf` | Open |
| R9 | Auto-approve apply in CI | 🟠 High | `.github/workflows/terraform.yml` | Open |
| R10 | `timestamp()` in RDS causes perpetual plan diff | 🟡 Medium | `modules/rds/main.tf:74` | Open |
| R11 | Single-AZ RDS (Kong DB) | 🟡 Medium | `modules/rds/` | Open |
| R12 | No automatic CI on PR | 🟡 Medium | `.github/workflows/` | Open |
| R13 | ECS Exec in all environments | 🟡 Medium | `modules/ecs/` | Open |
| R14 | Unused `app_mesh` module | 🟢 Low | `modules/app_mesh/` | Open |
| R15 | `system_architecture.md` is placeholder | 🟢 Low | `docs/system_architecture.md` | Open |

---

## 10. Recommendations

### Immediate (before any production use)

1. **Rotate and remove certificates from `kong-dp-bootstrap.sh`**. Treat the current keys as compromised. Store all secrets exclusively in AWS Secrets Manager and fetch at container startup via IAM.
2. **Remove the default password from `variables.tf`**: Make `kong_db_password` required (no default). Purge the plaintext value from all documentation files.
3. **Restrict Kong Admin ports**: Remove ports 8001/8002 from `public-sg`. Create a separate management security group restricted to a bastion/VPN CIDR.
4. **Fix Kong CP migrations command**: Replace `kong migrations bootstrap && kong migrations up && kong start` with conditional logic (e.g. `kong migrations up --v; kong start`) so the container survives restarts after the first deployment.
5. **Fix the conditional secret dereference**: Add a guard so the Kong CP task definition only references `kong_db_password` secret when `kong_db_enabled = true`.

### Short-term

6. **Restrict OIDC trust policy**: Change `repo:acn-qiangchen/*:*` to `repo:acn-qiangchen/sbxservice-infra:*`.
7. **Fix `final_snapshot_identifier`**: Replace `timestamp()` with a static identifier such as `"${var.project}-${var.environment}-final"`.
8. **Parameterise `backend.tf`**: Replace the hardcoded account ID with an environment variable or partial backend config supplied via `-backend-config` during `terraform init`.
9. **Add a plan approval gate in CI**: Use GitHub Actions environments with required reviewers to gate `terraform apply`.
10. **Wire the `network_firewall` module into `main.tf`**: The implementation is complete — activate it.
11. **Enable Multi-AZ on RDS** for any environment beyond personal dev.
12. **Add automatic CI triggers**: Add `on: pull_request` to `terraform.yml` for `fmt-check` and `validate` steps at minimum.

### Medium-term

13. **Remove or document `app_mesh` module**: Either delete dead code or add a comment explaining planned future use.
14. **Create `CLAUDE.md`**: Add a Claude Code project context file describing the project, key commands, and conventions.
15. **Add Architecture Decision Records (ADRs)**: Capture the dual-NLB weighted routing design, Kong CP/DP split decision, and Network Firewall rule design in ADR format.
16. **Disable ECS Exec by default**: Make it a variable-controlled opt-in (`enable_ecs_exec = false` default) and restrict the IAM policy to a named operator role.
17. **Tag all resources with cost-allocation tags**: Add `owner` and `cost-centre` tags to support cloud cost reporting.

---

*Report generated by Claude Code on 2026-08-14.*
