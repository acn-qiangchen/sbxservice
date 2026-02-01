# Kong Database Design Considerations

## Overview

This document outlines the database architecture for Kong Gateway deployments, including how databases are created, managed, and scaled to support multiple Control Planes on a shared PostgreSQL instance.

## Table of Contents

- [Database Creation Process](#database-creation-process)
- [Multiple Control Planes Architecture](#multiple-control-planes-architecture)
- [Creating Additional Databases](#creating-additional-databases)
- [Database Limits and Constraints](#database-limits-and-constraints)
- [Connection Management](#connection-management)
- [Recommendations](#recommendations)

---

## Database Creation Process

Kong database creation happens in **two stages**:

### Stage 1: RDS PostgreSQL Instance Creation

The AWS Terraform provider creates the RDS PostgreSQL instance with an initial database:

```hcl
# terraform/modules/rds/main.tf
resource "aws_db_instance" "kong" {
  identifier     = "${var.project_name}-${var.environment}-kong-db"
  engine         = "postgres"
  engine_version = "13"
  
  db_name  = var.db_name      # Creates initial database (default: "kong")
  username = var.db_username  # Database user (default: "kong")
  password = var.db_password  # Database password
  
  # ... other configuration
}
```

**Result**: RDS instance with one database named `kong` (or whatever `db_name` is set to).

### Stage 2: Kong Schema Initialization

When the Kong Control Plane container starts, it automatically initializes the Kong schema:

```hcl
# terraform/modules/ecs/main.tf - Kong CP Task Definition
command = ["sh", "-c", "kong migrations bootstrap && kong migrations up && kong start"]
```

**Commands**:
- `kong migrations bootstrap`: Creates Kong's database schema (tables, indexes, etc.)
- `kong migrations up`: Runs any pending migrations
- `kong start`: Starts the Kong Control Plane service

**Result**: Database populated with Kong's configuration tables (services, routes, plugins, consumers, etc.).

---

## Multiple Control Planes Architecture

### Use Case

You may want to deploy multiple Kong Control Planes sharing the same PostgreSQL instance but using separate databases for:
- Different environments (dev, staging, prod)
- Different teams or business units
- Different API domains or service meshes
- Cost optimization (one RDS instance vs. multiple)

### Architecture Pattern

```
┌─────────────────────────────────────────────────────────┐
│   RDS PostgreSQL Instance (Single Host)                 │
│   Endpoint: xxx.rds.amazonaws.com:5432                  │
│                                                          │
│   ├─ Database: kong         (Control Plane 1)          │
│   ├─ Database: kong_cp2     (Control Plane 2)          │
│   ├─ Database: kong_staging (Control Plane 3)          │
│   └─ Database: kong_prod    (Control Plane 4)          │
└─────────────────────────────────────────────────────────┘
         ▲           ▲           ▲           ▲
         │           │           │           │
    DB Connection (KONG_PG_HOST = same RDS endpoint)
    Different KONG_PG_DATABASE values
         │           │           │           │
┌────────┴───┐  ┌────┴─────┐  ┌─┴────────┐ ┌┴──────────┐
│  Kong CP1  │  │ Kong CP2 │  │ Kong CP3 │ │ Kong CP4  │
│  ECS Task  │  │ ECS Task │  │ ECS Task │ │ ECS Task  │
│            │  │          │  │          │ │           │
│  Port 8005 │  │ Port 8005│  │ Port 8005│ │ Port 8005 │
└────────┬───┘  └────┬─────┘  └─┬────────┘ └┬──────────┘
         │           │           │           │
    Service Discovery (Different DNS names)
         │           │           │           │
   ┌─────▼──────┐ ┌──▼─────┐ ┌──▼──────┐ ┌─▼────────┐
   │  DP for CP1│ │DP for  │ │DP for   │ │DP for    │
   │            │ │  CP2   │ │  CP3    │ │  CP4     │
   └────────────┘ └────────┘ └─────────┘ └──────────┘
```

### Configuration Differences

Each Control Plane requires:

1. **Same Database Host**:
   ```bash
   KONG_PG_HOST=xxx.rds.amazonaws.com
   KONG_PG_PORT=5432
   KONG_PG_USER=kong
   KONG_PG_PASSWORD=<secret>
   ```

2. **Different Database Name**:
   ```bash
   # Control Plane 1
   KONG_PG_DATABASE=kong
   
   # Control Plane 2
   KONG_PG_DATABASE=kong_cp2
   
   # Control Plane 3
   KONG_PG_DATABASE=kong_staging
   ```

3. **Different Service Discovery Name** (if running simultaneously):
   ```bash
   # Control Plane 1
   Service: kong-cp.sbxservice.dev.local
   
   # Control Plane 2
   Service: kong-cp2.sbxservice.dev.local
   
   # Control Plane 3
   Service: kong-cp-staging.sbxservice.dev.local
   ```

**Note**: Service discovery names are only needed if you're running multiple Control Planes **simultaneously**. If you're switching between configurations with the same Control Plane instance, you can reuse the same service discovery name.

---

## Creating Additional Databases

The AWS Terraform provider can only create the **initial database** when provisioning the RDS instance. To create additional databases, you have three options:

### Option 1: Manual Creation (Simplest)

Connect directly to PostgreSQL and create databases manually:

```bash
# Connect to RDS instance
psql -h xxx.rds.amazonaws.com -U kong -d postgres

# Create additional databases
CREATE DATABASE kong_cp2;
CREATE DATABASE kong_staging;
CREATE DATABASE kong_prod;

# Verify
\l
```

**Pros**:
- Simple and quick
- No additional Terraform dependencies

**Cons**:
- Not infrastructure-as-code
- Manual process not tracked in version control
- Can't be easily replicated

### Option 2: PostgreSQL Terraform Provider (Recommended for Production)

Use the PostgreSQL Terraform provider to manage databases as code:

```hcl
# Add to terraform/modules/rds/main.tf

terraform {
  required_providers {
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.22"
    }
  }
}

# Configure provider to connect to RDS
provider "postgresql" {
  host     = aws_db_instance.kong.address
  port     = aws_db_instance.kong.port
  username = var.db_username
  password = var.db_password
  database = "postgres"  # Connect to default postgres database
  sslmode  = "require"
  superuser = false
}

# Create additional databases
resource "postgresql_database" "kong_cp2" {
  name  = "kong_cp2"
  owner = var.db_username
  
  lifecycle {
    prevent_destroy = true  # Prevent accidental deletion
  }
}

resource "postgresql_database" "kong_staging" {
  name  = "kong_staging"
  owner = var.db_username
  
  lifecycle {
    prevent_destroy = true
  }
}

# Export database names as outputs
output "additional_databases" {
  value = [
    postgresql_database.kong_cp2.name,
    postgresql_database.kong_staging.name,
  ]
}
```

**Pros**:
- Infrastructure as code
- Version controlled
- Easily replicable across environments
- Declarative and idempotent

**Cons**:
- Additional provider dependency
- Requires database credentials in Terraform
- Provider needs network access to RDS

### Option 3: Initialization Script

Create databases via an initialization Lambda or ECS task:

```bash
#!/bin/bash
# create-kong-databases.sh

databases=("kong_cp2" "kong_staging" "kong_prod")

for db in "${databases[@]}"; do
  psql -h $KONG_PG_HOST -U $KONG_PG_USER -d postgres -c "
    SELECT 'CREATE DATABASE $db' 
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
  "
  echo "Database $db ensured"
done
```

**Pros**:
- Can be automated in CI/CD
- No additional Terraform providers

**Cons**:
- Requires separate orchestration
- Not purely declarative

---

## Database Limits and Constraints

### PostgreSQL Engine Limits

#### Theoretical Limits
- **Database OID limit**: 32-bit integer = ~4.2 billion databases
- **Practical limit**: Millions of databases per cluster

#### Real-World Constraints

1. **System Catalog Overhead**
   - Each database has metadata in `pg_database` system catalog
   - More databases = more overhead in system queries like `\l` or schema operations

2. **Connection Pool Exhaustion**
   - Each connection connects to **one specific database**
   - Total connections are limited by instance class
   - Connections are NOT shared across databases

3. **Backup and Restore Time**
   - Each database is backed up as part of the instance snapshot
   - More databases = longer backup/restore operations

4. **Memory and Disk Overhead**
   - Each database maintains its own system tables
   - Minimal per-database overhead (~1-10 MB), but accumulates

### RDS Connection Limits by Instance Class

| Instance Class | Memory | Max Connections |
|---------------|--------|-----------------|
| db.t3.micro   | 1 GB   | ~87             |
| db.t3.small   | 2 GB   | ~175            |
| db.t3.medium  | 4 GB   | ~350            |
| db.t3.large   | 8 GB   | ~700            |
| db.m5.large   | 8 GB   | ~700            |
| db.m5.xlarge  | 16 GB  | ~1400           |

**Formula**: `LEAST({DBInstanceClassMemory/9531392}, 5000)` for PostgreSQL

---

## Connection Management

### Per Control Plane Connection Usage

Each Kong Control Plane typically uses:
- **10-20 connections** for normal operations
- **5-10 connections** per ECS task (if running multiple tasks)
- Additional connections for:
  - Admin API requests
  - Database migrations
  - Health checks
  - Monitoring queries

### Calculation Example

**Scenario**: 5 Control Planes on `db.t3.micro` (87 max connections)

```
Control Plane 1: 15 connections
Control Plane 2: 15 connections
Control Plane 3: 15 connections
Control Plane 4: 15 connections
Control Plane 5: 15 connections
----------------------------------
Total:          75 connections (86% of limit) ✅ OK
```

**Scenario**: 8 Control Planes on `db.t3.micro` (87 max connections)

```
Control Plane 1-8: 15 connections each
----------------------------------
Total:          120 connections (138% of limit) ❌ EXCEEDED
```

### Connection Pooling Solution

For high connection usage, implement **PgBouncer** as a connection pooler:

```
┌──────────┐     ┌────────────┐     ┌─────────┐
│  Kong CP │────▶│  PgBouncer │────▶│   RDS   │
│ 15 conns │     │  Pooling   │     │ 10 real │
└──────────┘     │            │     │  conns  │
┌──────────┐     │  Pool Mode │     └─────────┘
│  Kong CP │────▶│  Session/  │
│ 15 conns │     │  Trans     │
└──────────┘     └────────────┘
    ...
```

**Benefits**:
- Reduce actual database connections
- Support more Control Planes on same instance
- Better connection reuse

---

## Recommendations

### Number of Databases per Instance

| Scenario | Databases | Recommendation |
|----------|-----------|----------------|
| **2-10 databases** | Kong Control Planes for dev/staging/prod | ✅ **Perfect** - No issues, go ahead |
| **10-20 databases** | Multiple teams or services | ⚠️ **Acceptable** - Monitor connections closely |
| **20-50 databases** | Large multi-tenant setup | ⚠️ **Risky** - Upgrade instance class, use PgBouncer |
| **50+ databases** | Very large scale | ❌ **Not Recommended** - Use separate RDS instances or Aurora clusters |

### Instance Sizing Recommendations

#### Small Scale (2-5 Control Planes)
```hcl
db_instance_class = "db.t3.micro"   # 1 GB, ~87 connections
db_allocated_storage = 20           # 20 GB storage
multi_az = false                     # Single AZ for dev
```

**Use Case**: Development, staging, small production

#### Medium Scale (5-10 Control Planes)
```hcl
db_instance_class = "db.t3.small"   # 2 GB, ~175 connections
db_allocated_storage = 50           # 50 GB storage
multi_az = true                      # Multi-AZ for HA
```

**Use Case**: Production environments, multiple teams

#### Large Scale (10+ Control Planes)
```hcl
db_instance_class = "db.t3.medium"  # 4 GB, ~350 connections
db_allocated_storage = 100          # 100 GB storage
multi_az = true                      # Multi-AZ for HA
```

**Use Case**: Enterprise production, high availability requirements

### Cost Optimization

**Single RDS Instance** (Recommended for most cases):
```
Cost: $30-50/month (db.t3.micro)
Databases: 5-10 Kong Control Planes
Savings: $150-250/month vs. separate instances
```

**Multiple RDS Instances** (For isolation):
```
RDS 1 (Dev):     2-3 Control Planes
RDS 2 (Staging): 2-3 Control Planes  
RDS 3 (Prod):    2-3 Control Planes
Cost: $90-150/month total
Benefits: Better isolation, independent backups
```

### Best Practices

1. **Monitor Connection Usage**
   ```sql
   -- Check current connections per database
   SELECT datname, count(*) as connections
   FROM pg_stat_activity
   GROUP BY datname
   ORDER BY connections DESC;
   ```

2. **Set Connection Limits per Database**
   ```sql
   -- Limit connections per database (optional)
   ALTER DATABASE kong_cp2 CONNECTION LIMIT 20;
   ```

3. **Use CloudWatch Alarms**
   ```hcl
   resource "aws_cloudwatch_metric_alarm" "database_connections" {
     alarm_name          = "kong-db-connections-high"
     comparison_operator = "GreaterThanThreshold"
     metric_name         = "DatabaseConnections"
     threshold           = "70"  # 70 connections on db.t3.micro
   }
   ```

4. **Regular Monitoring**
   - Track connection count per Control Plane
   - Monitor database size growth
   - Review slow queries
   - Set up alerts for connection threshold (80% of max)

5. **Documentation**
   - Document which database belongs to which Control Plane
   - Maintain inventory of database names and purposes
   - Track environment mappings

### Migration Strategy

If you need to split databases across multiple instances:

1. **Backup existing database**
   ```bash
   pg_dump -h xxx.rds.amazonaws.com -U kong -d kong > kong_backup.sql
   ```

2. **Create new RDS instance**
   ```bash
   terraform apply -target=module.rds_prod
   ```

3. **Restore to new instance**
   ```bash
   psql -h yyy.rds.amazonaws.com -U kong -d kong < kong_backup.sql
   ```

4. **Update Control Plane configuration**
   ```hcl
   kong_db_host = module.rds_prod.db_instance_address
   ```

---

## Summary

- **RDS creates one initial database** - Use AWS provider
- **Additional databases** - Use PostgreSQL provider or manual creation
- **No hard limit on database count** - Practical limit is connection pool
- **Connection limit is the bottleneck** - Not number of databases
- **Recommended: 2-10 databases per instance** - For most use cases
- **Scale up instance class** - If you need more connections
- **Use connection pooling** - For high-density deployments

## Related Documentation

- [Kong Gateway Guide](../kong_gateway_guide.md)
- [Kong Troubleshooting](../kong_troubleshooting.md)
- [System Architecture](../system_architecture.md)
- [Network Firewall Architecture](./network_firewall.md)

---

**Last Updated**: 2026-01-08  
**Author**: Infrastructure Team


