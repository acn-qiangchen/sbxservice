# Kong Control Plane Outage Resilience

## Overview

This document describes the Kong Data Plane resilience feature that enables new Data Plane nodes to be provisioned during a Control Plane outage by fetching configuration from S3 storage.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [How It Works](#how-it-works)
- [Configuration](#configuration)
- [Infrastructure Components](#infrastructure-components)
- [Testing](#testing)
- [Operational Procedures](#operational-procedures)
- [Troubleshooting](#troubleshooting)
- [Security Considerations](#security-considerations)
- [Cost Analysis](#cost-analysis)
- [Limitations](#limitations)
- [References](#references)

---

## Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Control Plane                           │
│                      (ECS Fargate Task)                         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐   │
│  │  Kong CP (Primary Configuration Source)                 │   │
│  │  - Manages configuration in PostgreSQL                  │   │
│  │  - Serves config to Data Planes via port 8005          │   │
│  │  - Telemetry on port 8006                               │   │
│  └────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                               │
                               │ Push config (when CP is running)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                  S3 Bucket (Fallback Storage)                   │
│             sbxservice-dev-kong-config-fallback                 │
│                                                                  │
│  kong-config/                                                    │
│  ├── 3.9.1/                                                      │
│  │   ├── config.json        ← Exported Kong configuration       │
│  │   └── election/          ← Leader election files             │
│  │       ├── node-1         ← Backup node registration          │
│  │       └── node-2         ← Backup node registration          │
│  └── [version]/              ← Version-specific configs          │
└─────────────────────────────────────────────────────────────────┘
                               ▲
                               │
                ┌──────────────┴──────────────┐
                │                              │
        Export (on config change)      Import (on startup, CP down)
                │                              │
┌───────────────┴─────────────┐   ┌───────────┴──────────────────┐
│   Data Plane Node 1         │   │   Data Plane Node 2          │
│   (ECS Fargate Task)        │   │   (ECS Fargate Task)         │
│                             │   │                              │
│  Role: Backup + Proxy       │   │  Role: Backup + Proxy        │
│  Export: ON                 │   │  Export: ON                  │
│  Import: ON                 │   │  Import: ON                  │
│                             │   │                              │
│  Leader Election ✓          │   │  Leader Election             │
│  (Active Exporter)          │   │  (Standby)                   │
└─────────────────────────────┘   └──────────────────────────────┘
         │                                   │
         │ Proxy Traffic                     │ Proxy Traffic
         └──────────┬────────────────────────┘
                    ▼
         ┌──────────────────────┐
         │   Backend Services   │
         │   (hello-service)    │
         └──────────────────────┘
```

### Normal Operation (Control Plane Available)

1. Control Plane manages configuration in PostgreSQL
2. Data Plane nodes connect to Control Plane (port 8005) for configuration
3. One Data Plane node (leader) exports configuration to S3 on every change
4. Data Planes proxy traffic to backend services
5. Telemetry data flows back to Control Plane (port 8006)

### CP Outage Scenario (New Data Plane Startup)

1. New Data Plane starts and attempts to connect to Control Plane
2. Connection fails (CP is down)
3. Data Plane automatically fetches configuration from S3
4. Data Plane configures itself with the fetched configuration
5. Data Plane starts proxying requests with cached configuration
6. Data Plane continuously retries connecting to Control Plane
7. When CP comes back online, Data Plane reconnects and gets latest config

---

## How It Works

### Export Process (Configuration Backup)

When **Control Plane outage resilience** is enabled:

1. **Multiple Data Planes as Backup Nodes**: All Data Plane nodes have `EXPORT=on` enabled
2. **Leader Election**: Data Planes perform leader election using S3 objects
   - Election files stored in: `s3://bucket/kong-config/3.9.1/election/`
   - One Data Plane becomes the leader exporter
3. **Configuration Export**: The leader Data Plane exports configuration to S3
   - On every configuration change received from Control Plane
   - File path: `s3://bucket/kong-config/3.9.1/config.json`
   - Contains: routes, services, plugins, upstreams, targets, consumers, etc.
4. **Automatic Failover**: If leader fails, another Data Plane becomes leader

### Import Process (Configuration Restore)

When a **new Data Plane starts** during CP outage:

1. **Connection Attempt**: Data Plane tries to connect to Control Plane
2. **Fallback Trigger**: Connection fails after timeout
3. **S3 Fetch**: Data Plane reads configuration from S3
   - `s3://bucket/kong-config/3.9.1/config.json`
4. **Configuration Apply**: Data Plane applies the fetched configuration
5. **Cache**: Configuration is cached locally
6. **Start Proxying**: Data Plane begins handling requests
7. **Reconnection Attempts**: Data Plane continuously tries to reconnect to CP

### Version Matching

⚠️ **Critical Requirement**: The Kong Gateway version of the new Data Plane **must exactly match** the version that exported the configuration.

- Export version: `3.9.1` → Import must be: `3.9.1`
- Configuration path includes version: `kong-config/3.9.1/config.json`
- Mismatched versions will cause import failures

---

## Configuration

### Terraform Variables

#### Module Variables (`terraform/modules/ecs/variables.tf`)

```hcl
variable "kong_cp_outage_resilience_enabled" {
  description = "Enable Kong Data Plane resilience with S3 fallback during CP outage"
  type        = bool
  default     = true
}

variable "kong_fallback_s3_bucket_name" {
  description = "S3 bucket name for Kong configuration fallback (auto-generated if empty)"
  type        = string
  default     = ""
}

variable "kong_fallback_s3_prefix" {
  description = "S3 prefix/path for Kong configuration fallback"
  type        = string
  default     = "kong-config"
}
```

#### Root Variables (`terraform/variables.tf`)

Same variables are defined at root level and passed to the ECS module.

### Environment Variables (Kong Data Plane)

When `kong_cp_outage_resilience_enabled = true`, the following environment variables are automatically added to Data Plane containers:

```bash
# AWS Region for S3 access
AWS_REGION = "us-east-1"

# Enable configuration export (for backup role)
KONG_CLUSTER_FALLBACK_CONFIG_EXPORT = "on"

# Enable configuration import (fallback mechanism)
KONG_CLUSTER_FALLBACK_CONFIG_IMPORT = "on"

# S3 storage location
KONG_CLUSTER_FALLBACK_CONFIG_STORAGE = "s3://sbxservice-dev-kong-config-fallback/kong-config"
```

### Default Configuration Values

| Parameter | Default Value | Description |
|-----------|---------------|-------------|
| Feature Enabled | `true` | Enabled by default for resilience |
| S3 Bucket Name | `${project_name}-${environment}-kong-config-fallback` | Auto-generated |
| S3 Prefix | `kong-config` | Path prefix in bucket |
| Versioning | `Enabled` | Keep config history |
| Encryption | `AES256` | Server-side encryption |
| Version Retention | `30 days` | Old versions deleted after 30 days |
| Election File TTL | `7 days` | Leader election files deleted after 7 days |

---

## Infrastructure Components

### S3 Bucket

**Resource**: `aws_s3_bucket.kong_config_fallback`

```hcl
bucket = "sbxservice-dev-kong-config-fallback"
```

**Features**:
- ✅ Versioning enabled
- ✅ Server-side encryption (AES-256)
- ✅ Public access blocked
- ✅ Lifecycle policies configured

**Lifecycle Rules**:
1. **Old version cleanup**: Delete non-current versions after 30 days
2. **Election file cleanup**: Delete election files after 7 days

### IAM Policy

**Resource**: `aws_iam_policy.kong_dp_s3_access`

**Permissions**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::sbxservice-dev-kong-config-fallback",
        "arn:aws:s3:::sbxservice-dev-kong-config-fallback/*"
      ]
    }
  ]
}
```

**Attached To**: ECS Task Role (`aws_iam_role.ecs_task_role`)

### ECS Task Configuration

**Task Definition**: `aws_ecs_task_definition.kong_gateway`

- **Execution Role**: For pulling images and secrets
- **Task Role**: For S3 access (includes kong_dp_s3_access policy)
- **Image**: `kong:3.9.1`
- **CPU**: 1024 (1 vCPU)
- **Memory**: 2048 MB

---

## Testing

### Test Plan

#### 1. Verify Configuration Export

**Objective**: Confirm that configuration is being exported to S3

**Steps**:
```bash
# 1. Check S3 bucket exists
aws s3 ls s3://sbxservice-dev-kong-config-fallback/

# 2. Check for config file
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/3.9.1/

# Expected output:
# config.json

# 3. Download and inspect config
aws s3 cp s3://sbxservice-dev-kong-config-fallback/kong-config/3.9.1/config.json ./config.json
cat config.json | jq .

# 4. Verify config contains your routes/services
cat config.json | jq '.config.services[]'
```

**Expected Result**: Configuration file exists and contains valid Kong configuration

#### 2. Test Normal Data Plane Startup (CP Running)

**Objective**: Verify Data Plane connects to Control Plane when available

**Steps**:
```bash
# 1. Ensure Control Plane is running
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-cp-service

# 2. Scale Data Plane to 0
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-service \
  --desired-count 0

# 3. Wait for scale down, then scale back to 1
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-service \
  --desired-count 1

# 4. Check Data Plane logs
aws logs tail /ecs/sbxservice-dev-kong --follow
```

**Expected Result**: Data Plane logs show successful connection to Control Plane, no S3 fallback

#### 3. Test Data Plane Startup During CP Outage

**Objective**: Verify Data Plane uses S3 fallback when CP is unavailable

**Steps**:
```bash
# 1. Stop Control Plane (simulate outage)
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-cp-service \
  --desired-count 0

# 2. Wait for CP to stop (2-3 minutes)
watch aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-cp-service

# 3. Scale Data Plane to 0
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-service \
  --desired-count 0

# 4. Scale Data Plane back to 1 (simulating new node)
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-service \
  --desired-count 1

# 5. Monitor Data Plane logs
aws logs tail /ecs/sbxservice-dev-kong --follow

# Look for these log messages:
# - "unable to connect to control plane"
# - "fetching fallback configuration from S3"
# - "successfully loaded configuration from S3"
# - "kong started"

# 6. Test proxy functionality
curl http://<ALB-DNS>/hello-service/actuator/health

# 7. Restart Control Plane
aws ecs update-service \
  --cluster sbxservice-dev-cluster \
  --service sbxservice-dev-kong-cp-service \
  --desired-count 1

# 8. Verify Data Plane reconnects to CP (check logs)
```

**Expected Result**:
- Data Plane successfully fetches config from S3
- Data Plane starts and proxies requests
- Data Plane reconnects to CP when it comes back online

#### 4. Verify Proxy Functionality During CP Outage

**Objective**: Confirm Data Plane can proxy requests using S3 config

**Steps**:
```bash
# With CP down and DP running from S3 config:

# 1. Test existing route
curl -i http://<ALB-DNS>/hello-service/actuator/health

# Expected: 200 OK (route works)

# 2. Try to create new route via Admin API
curl -i -X POST http://<ALB-DNS>:8001/services \
  -d name=test-service \
  -d url=http://httpbin.org

# Expected: Connection refused (Admin API not available)
```

**Expected Result**: Existing routes work, Admin API unavailable

---

## Operational Procedures

### Deployment

1. **Initial Deployment** (New Infrastructure):
   ```bash
   cd terraform
   terraform init
   terraform plan -var-file=environments/dev.tfvars
   terraform apply -var-file=environments/dev.tfvars
   ```

2. **Enable Feature** (Existing Infrastructure):
   ```bash
   # Already enabled by default
   # To disable, set in tfvars:
   kong_cp_outage_resilience_enabled = false
   ```

3. **Custom S3 Bucket**:
   ```bash
   # In terraform.tfvars
   kong_fallback_s3_bucket_name = "my-custom-kong-config-bucket"
   ```

### Monitoring

#### CloudWatch Metrics to Monitor

1. **S3 Bucket Access**:
   - Metric: `NumberOfObjects`
   - Namespace: `AWS/S3`
   - Dimension: BucketName
   - Alert: If config.json missing

2. **ECS Service Health**:
   - Metric: `CPUUtilization`, `MemoryUtilization`
   - Alert: If Data Plane tasks failing repeatedly

3. **Control Plane Availability**:
   - Metric: `TargetResponseTime`, `HealthyHostCount`
   - Alert: If CP becomes unavailable

#### Log Monitoring

**Search Patterns**:
```bash
# Check for S3 fallback usage
aws logs filter-log-events \
  --log-group-name /ecs/sbxservice-dev-kong \
  --filter-pattern "fallback configuration"

# Check for CP connection failures
aws logs filter-log-events \
  --log-group-name /ecs/sbxservice-dev-kong \
  --filter-pattern "unable to connect to control plane"

# Check for successful config imports
aws logs filter-log-events \
  --log-group-name /ecs/sbxservice-dev-kong \
  --filter-pattern "successfully loaded configuration from S3"
```

### Maintenance

#### Update Kong Version

⚠️ **Important**: When upgrading Kong Gateway version:

1. **Export new config** before scaling down old version
2. **Verify S3 config** is updated with new version path
3. **Test new Data Plane** can import from S3
4. **Upgrade all Data Planes** simultaneously to avoid version mismatch

```bash
# Example upgrade from 3.9.1 to 3.10.0

# 1. Update Terraform
# In terraform/modules/ecs/main.tf, change:
image = "kong:3.10.0"

# 2. Apply Terraform
terraform apply

# 3. Verify new config path exists
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/3.10.0/
```

#### Rotate S3 Bucket

If you need to change the S3 bucket:

1. Create new bucket
2. Copy existing config
3. Update Terraform variable
4. Apply changes
5. Verify new bucket is used
6. Delete old bucket

---

## Troubleshooting

### Common Issues

#### 1. Data Plane Fails to Start During CP Outage

**Symptoms**:
- Data Plane container exits immediately
- Logs show: "failed to load configuration"

**Possible Causes**:
- S3 bucket doesn't exist
- IAM permissions missing
- Config file doesn't exist
- Version mismatch

**Resolution**:
```bash
# Check S3 bucket exists
aws s3 ls s3://sbxservice-dev-kong-config-fallback/

# Check config file exists
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/3.9.1/config.json

# Check IAM role has S3 permissions
aws iam list-attached-role-policies --role-name sbxservice-dev-ecs-task-role

# Verify policy document
aws iam get-policy-version \
  --policy-arn <policy-arn> \
  --version-id v1
```

#### 2. Config Not Being Exported to S3

**Symptoms**:
- S3 bucket empty or outdated config
- Election files not created

**Possible Causes**:
- No Data Plane running with export enabled
- IAM permissions missing for PutObject
- Leader election failed

**Resolution**:
```bash
# Check Data Plane environment variables
aws ecs describe-task-definition \
  --task-definition sbxservice-dev-kong-task \
  --query 'taskDefinition.containerDefinitions[0].environment'

# Verify KONG_CLUSTER_FALLBACK_CONFIG_EXPORT = "on"

# Check for election files
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/3.9.1/election/

# Check Data Plane logs for export errors
aws logs filter-log-events \
  --log-group-name /ecs/sbxservice-dev-kong \
  --filter-pattern "export.*error"
```

#### 3. Version Mismatch Error

**Symptoms**:
- Error: "configuration version mismatch"
- Data Plane fails to import config

**Resolution**:
```bash
# Check current Kong version in ECS
aws ecs describe-task-definition \
  --task-definition sbxservice-dev-kong-task \
  --query 'taskDefinition.containerDefinitions[0].image'

# Check S3 config version
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/

# If mismatch, ensure all Data Planes are same version
# Or manually copy config to correct version path:
aws s3 cp \
  s3://bucket/kong-config/3.9.1/config.json \
  s3://bucket/kong-config/3.10.0/config.json
```

#### 4. Access Denied to S3

**Symptoms**:
- Error: "AccessDenied"
- Data Plane can't read/write S3

**Resolution**:
```bash
# Verify IAM role attached to ECS task
aws ecs describe-task-definition \
  --task-definition sbxservice-dev-kong-task \
  --query 'taskDefinition.taskRoleArn'

# Check if S3 policy attached
aws iam list-attached-role-policies \
  --role-name sbxservice-dev-ecs-task-role | grep kong-dp-s3

# If missing, re-apply Terraform
cd terraform
terraform apply
```

### Debug Commands

```bash
# Get running Data Plane task ID
TASK_ID=$(aws ecs list-tasks \
  --cluster sbxservice-dev-cluster \
  --service-name sbxservice-dev-kong-service \
  --query 'taskArns[0]' --output text)

# Execute command in running container
aws ecs execute-command \
  --cluster sbxservice-dev-cluster \
  --task $TASK_ID \
  --container sbxservice-dev-kong-container \
  --command "/bin/sh" \
  --interactive

# Inside container:
# Check environment variables
env | grep KONG_CLUSTER_FALLBACK

# Check AWS credentials (from IAM role)
curl -s http://169.254.170.2$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI

# Test S3 access
aws s3 ls s3://sbxservice-dev-kong-config-fallback/kong-config/
```

---

## Security Considerations

### IAM Permissions

**Principle of Least Privilege**:
- Data Planes only have `s3:GetObject`, `s3:PutObject`, `s3:ListBucket`
- No `s3:DeleteObject` permission (prevent accidental deletion)
- Scoped to specific bucket only

### Data Encryption

**In Transit**:
- HTTPS used for S3 API calls (default)
- TLS 1.2+ required

**At Rest**:
- S3 server-side encryption (AES-256)
- Automatic encryption for all objects
- Consider KMS encryption for production

### Network Security

**Recommendations**:
- Use VPC Endpoint for S3 to keep traffic private
- Avoid exposing S3 bucket publicly
- Monitor S3 access logs

**VPC Endpoint Configuration** (Optional):
```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = var.vpc_id
  service_name = "com.amazonaws.${var.region}.s3"
  
  route_table_ids = [var.private_route_table_id]
}
```

### Sensitive Data

⚠️ **Configuration Sensitivity**:
- Exported config contains route definitions
- May include API keys in plugin configurations
- Consider additional encryption layer if needed

**Mitigation**:
- Use AWS Secrets Manager for sensitive plugin configs
- Enable S3 bucket access logging
- Implement bucket policies restricting access

---

## Cost Analysis

### S3 Storage Costs

| Component | Usage | Cost (us-east-1) |
|-----------|-------|------------------|
| Storage | ~10 MB config × 30 versions | ~$0.01/month |
| PUT Requests | ~100/month (on config change) | ~$0.01/month |
| GET Requests | ~10/month (new DP startup) | ~$0.001/month |
| **Total** | | **~$0.02/month** |

### Network Costs

- **S3 VPC Endpoint**: Free (data transfer within same region)
- **Without VPC Endpoint**: $0.09/GB (NAT Gateway)

### Overall Impact

- **Cost Increase**: **< $1/month** for typical usage
- **Benefit**: High availability during CP outage
- **ROI**: Depends on outage frequency and business impact

---

## Limitations

### What Works During CP Outage

✅ **Available**:
- Existing routes continue to work
- Existing plugins continue to function
- Request proxying
- Rate limiting (if configured)
- Authentication (if configured)
- Caching (if configured)

### What Doesn't Work During CP Outage

❌ **Unavailable**:
- **Admin API**: Cannot create/update/delete routes or services
- **Dynamic Configuration**: Cannot modify plugins or consumers
- **New Consumers**: Cannot add authentication credentials
- **Certificate Updates**: Cannot update TLS certificates
- **Telemetry**: Telemetry data not sent to Control Plane
- **Live Config Sync**: Running Data Planes keep cached config

### Edge Cases

1. **Long CP Outage**: 
   - Running Data Planes work fine (cached config)
   - New Data Planes can be provisioned (from S3)
   - But no configuration updates possible

2. **Config Changes During Outage**:
   - Changes made before outage are available in S3
   - Changes attempted during outage are lost
   - After CP recovery, make changes again

3. **Split Brain Scenario**:
   - If multiple leaders elected (rare)
   - Last write wins in S3
   - Usually self-heals via leader election

4. **Version Drift**:
   - Mixing Kong versions will fail
   - Always upgrade all nodes together
   - Test in staging first

---

## References

### Kong Documentation

- [Kong CP Outage Management](https://developer.konghq.com/gateway/cp-outage/)
- [Kong Hybrid Mode](https://docs.konghq.com/gateway/latest/production/deployment-topologies/hybrid-mode/)
- [Kong Data Plane Resilience](https://docs.konghq.com/gateway/latest/production/deployment-topologies/hybrid-mode/resilience/)

### AWS Documentation

- [Amazon S3 User Guide](https://docs.aws.amazon.com/s3/)
- [IAM Roles for ECS Tasks](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html)
- [S3 VPC Endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)

### Internal Documentation

- [Kong Gateway Guide](../kong_gateway_guide.md)
- [Kong Database Design](./kong_database_design.md)
- [System Architecture](../system_architecture.md)
- [Kong Troubleshooting](../kong_troubleshooting.md)

### Terraform Resources

- [AWS S3 Bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
- [AWS IAM Policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy)
- [AWS ECS Task Definition](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition)

---

## Changelog

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2026-02-01 | 1.0.0 | Initial documentation for Kong CP outage resilience feature | Infrastructure Team |

---

**Last Updated**: 2026-02-01  
**Author**: Infrastructure Team  
**Reviewers**: TBD
