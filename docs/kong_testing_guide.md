# Kong Gateway Testing Guide

## Pre-Deployment Testing

### 1. Validate Terraform Configuration

```bash
cd terraform

# Format check
terraform fmt -check

# Validate configuration
terraform validate

# Plan without applying
terraform plan -out=tfplan
```

## Deployment Testing

### 1. Initial Deployment

```bash
# Deploy infrastructure
terraform apply

# Expected output:
# - alb_custom_domain_url
# - kong_admin_api_endpoint
# - kong_nlb_dns_name
# - postgres_dns_name
# - kong_cp_dns_name
```

### 2. Wait for Services

```bash
# Wait for all services to be running
aws ecs wait services-stable \
  --cluster sbxservice-dev-cluster \
  --services \
    sbxservice-dev-postgres-service \
    sbxservice-dev-kong-cp-service \
    sbxservice-dev-kong-service \
    sbxservice-dev-service
```

### 3. Verify Service Health

```bash
# Check PostgreSQL
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-postgres-service \
  --query 'services[0].{name:serviceName,status:status,running:runningCount,desired:desiredCount}'

# Check Kong Control Plane
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-cp-service \
  --query 'services[0].{name:serviceName,status:status,running:runningCount,desired:desiredCount}'

# Check Kong Data Plane
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-service \
  --query 'services[0].{name:serviceName,status:status,running:runningCount,desired:desiredCount}'

# Check Hello Service
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-service \
  --query 'services[0].{name:serviceName,status:status,running:runningCount,desired:desiredCount}'
```

## Kong Control Plane Testing

### 1. Test Admin API Access

```bash
export KONG_ADMIN_URL=$(cd terraform && terraform output -raw kong_admin_api_endpoint)

# Test status endpoint
curl -v $KONG_ADMIN_URL/status

# Expected output:
# {
#   "database": {
#     "reachable": true
#   },
#   "server": {
#     "connections_accepted": 1,
#     "connections_active": 1,
#     "connections_handled": 1,
#     "connections_reading": 0,
#     "connections_waiting": 0,
#     "connections_writing": 1,
#     "total_requests": 1
#   }
# }
```

### 2. Verify Database Connection

```bash
# Check database configuration
curl $KONG_ADMIN_URL/ | jq '.configuration.database'

# Expected: "postgres"
```

### 3. Check Data Plane Connections

```bash
# List connected data planes
curl $KONG_ADMIN_URL/clustering/data-planes | jq

# Expected output:
# {
#   "data": [
#     {
#       "id": "...",
#       "hostname": "...",
#       "ip": "...",
#       "last_seen": ...,
#       "config_hash": "...",
#       "status": "connected"
#     }
#   ]
# }
```

## Service Configuration Testing

Kong supports two approaches for backend service configuration:

1. **Direct URL** (Simple): Service points directly to backend URL - good for PoC
2. **Upstream + Targets** (Production): Service points to upstream with multiple targets - supports health checks, load balancing, and circuit breakers

### 1. Configure Hello Service via Script (Using Direct URL)

```bash
# Run setup script
./scripts/kong-setup.sh health
./scripts/kong-setup.sh setup

# Verify services created
./scripts/kong-setup.sh list-services
./scripts/kong-setup.sh list-routes
```

### 2. Manual Service Configuration Test (Using Upstream)

This test demonstrates the **production-ready approach** using upstream and targets for better load balancing and health checking.

**Upstream vs Direct URL:**
- **Direct URL** (`url: "http://host:port"`): Simple, good for PoC or single backend
- **Upstream** (`host: "upstream-name"`): Production-ready, supports multiple targets, health checks, load balancing

```bash
# Step 1: Create upstream
curl -X POST $KONG_ADMIN_URL/upstreams \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-upstream",
    "algorithm": "round-robin",
    "healthchecks": {
      "active": {
        "healthy": {
          "interval": 10,
          "successes": 2
        },
        "unhealthy": {
          "interval": 10,
          "http_failures": 3
        },
        "http_path": "/actuator/health"
      }
    }
  }' | jq

# Step 2: Add target to upstream
curl -X POST $KONG_ADMIN_URL/upstreams/test-upstream/targets \
  -H "Content-Type: application/json" \
  -d '{
    "target": "sbxservice.sbxservice.dev.local:8080",
    "weight": 100
  }' | jq

# Step 3: Verify upstream and targets
curl $KONG_ADMIN_URL/upstreams/test-upstream | jq
curl $KONG_ADMIN_URL/upstreams/test-upstream/targets | jq

# Step 4: Create service pointing to upstream
curl -X POST $KONG_ADMIN_URL/services \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-service",
    "host": "test-upstream",
    "path": "/",
    "protocol": "http",
    "port": 80
  }' | jq

# Step 5: Verify service created
curl $KONG_ADMIN_URL/services/test-service | jq

# Step 6: Create route
curl -X POST $KONG_ADMIN_URL/services/test-service/routes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-route",
    "paths": ["/test"],
    "strip_path": false
  }' | jq

# Step 7: Verify route created
curl $KONG_ADMIN_URL/routes | jq '.data[] | select(.name=="test-route")'

# Step 8: Check upstream health
curl $KONG_ADMIN_URL/upstreams/test-upstream/health | jq

# Step 9: Test the route through Kong proxy
# Get ALB URL first
export ALB_URL=$(cd terraform && terraform output -raw alb_custom_domain_url)

# Test the endpoint
curl -v $ALB_URL/test/actuator/health

# Expected: HTTP 200 with health status

# Step 10: Clean up (delete in reverse order)
curl -X DELETE $KONG_ADMIN_URL/routes/test-route
curl -X DELETE $KONG_ADMIN_URL/services/test-service
curl -X DELETE $KONG_ADMIN_URL/upstreams/test-upstream
```

**Note**: Using upstream provides:
- Better load balancing across multiple targets
- Active health checks
- Easy addition/removal of backend targets
- Circuit breaker functionality

### 3. Production-Ready Hello Service Configuration (Using Upstream)

This example shows how to configure the hello-service using upstream for production:

```bash
# Create upstream for hello-service
curl -X POST $KONG_ADMIN_URL/upstreams \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello-upstream",
    "algorithm": "round-robin",
    "slots": 10000,
    "healthchecks": {
      "active": {
        "type": "http",
        "http_path": "/actuator/health",
        "healthy": {
          "interval": 10,
          "successes": 2,
          "http_statuses": [200, 302]
        },
        "unhealthy": {
          "interval": 10,
          "http_failures": 3,
          "timeouts": 3,
          "http_statuses": [429, 500, 503]
        }
      },
      "passive": {
        "type": "http",
        "healthy": {
          "successes": 5,
          "http_statuses": [200, 201, 202, 203, 204, 205, 206, 207, 208, 226, 300, 301, 302, 303, 304, 305, 306, 307, 308]
        },
        "unhealthy": {
          "http_failures": 5,
          "timeouts": 5,
          "http_statuses": [429, 500, 503]
        }
      }
    }
  }' | jq

# Add hello-service target(s) to upstream
curl -X POST $KONG_ADMIN_URL/upstreams/hello-upstream/targets \
  -H "Content-Type: application/json" \
  -d '{
    "target": "sbxservice.sbxservice.dev.local:8080",
    "weight": 100
  }' | jq

# If you have multiple hello-service instances, add more targets:
# curl -X POST $KONG_ADMIN_URL/upstreams/hello-upstream/targets \
#   -d '{"target": "sbxservice-2.sbxservice.dev.local:8080", "weight": 100}' | jq

# Create service using upstream
curl -X POST $KONG_ADMIN_URL/services \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello-service-upstream",
    "host": "hello-upstream",
    "port": 80,
    "protocol": "http",
    "connect_timeout": 60000,
    "write_timeout": 60000,
    "read_timeout": 60000,
    "retries": 5
  }' | jq

# Create routes
curl -X POST $KONG_ADMIN_URL/services/hello-service-upstream/routes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "hello-route-upstream",
    "paths": ["/hello"],
    "strip_path": false
  }' | jq

curl -X POST $KONG_ADMIN_URL/services/hello-service-upstream/routes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "health-route-upstream",
    "paths": ["/actuator/health"],
    "strip_path": false
  }' | jq

# Verify upstream health
curl $KONG_ADMIN_URL/upstreams/hello-upstream/health | jq

# Test the endpoints
export ALB_URL=$(cd terraform && terraform output -raw alb_custom_domain_url)
curl -s $ALB_URL/hello | jq
curl -s $ALB_URL/actuator/health | jq

# Monitor upstream health and targets
curl $KONG_ADMIN_URL/upstreams/hello-upstream/targets | jq
```

## Traffic Routing Testing

### 1. Test Through Kong Gateway (via ALB)

After running the setup script (`./scripts/kong-setup.sh setup`), the following routes are created:
- `/hello` → hello-service
- `/actuator/health` → hello-service

```bash
export ALB_URL=$(cd terraform && terraform output -raw alb_custom_domain_url)

# Test hello endpoint
curl -v $ALB_URL/hello

# Expected: HTTP 200 with hello message like:
# {"message":"Hello from Spring Boot on ECS!","timestamp":"...","hostname":"..."}

# Test health endpoint
curl -v $ALB_URL/actuator/health

# Expected: HTTP 200 with health status:
# {"status":"UP","groups":["liveness","readiness"]}

# Test with jq for better formatting
curl -s $ALB_URL/hello | jq
curl -s $ALB_URL/actuator/health | jq
```

### 2. Test Kong Proxy Directly

```bash
export KONG_NLB=$(cd terraform && terraform output -raw kong_nlb_dns_name)

# Test through Kong NLB
curl -v http://$KONG_NLB:8000/hello

# Expected: HTTP 200 with hello message
```

### 3. Test Load Balancing

```bash
# Make multiple requests
for i in {1..10}; do
  curl -s $ALB_URL/sbx/api/hello
  echo ""
done

# Check Kong logs for request distribution
aws logs tail /ecs/sbxservice-dev-kong --since 5m
```

## Data Plane Synchronization Testing

### 1. Test Configuration Propagation

```bash
# Add a new route
curl -X POST $KONG_ADMIN_URL/services/hello-service/routes \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sync-test-route",
    "paths": ["/sync-test"]
  }'

# Wait a few seconds for sync
sleep 5

# Test the new route immediately
curl $ALB_URL/sync-test

# Should work without restarting data planes
```

### 2. Test Multiple Data Planes

```bash
# Scale up data planes
cd terraform
terraform apply -var="kong_app_count=3"

# Wait for new tasks to start
aws ecs wait services-stable \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-service

# Check all data planes are connected
curl $KONG_ADMIN_URL/clustering/data-planes | jq '.data | length'

# Expected: 3
```

### 3. Test Configuration Consistency

```bash
# Get config hash from control plane
CP_HASH=$(curl -s $KONG_ADMIN_URL/clustering/data-planes | jq -r '.data[0].config_hash')

# Verify all data planes have same config hash
curl -s $KONG_ADMIN_URL/clustering/data-planes | \
  jq -r ".data[] | select(.config_hash != \"$CP_HASH\") | .hostname"

# Expected: No output (all have same hash)
```

## Plugin Testing

### 1. Test Rate Limiting Plugin

```bash
# Add rate limiting plugin
curl -X POST $KONG_ADMIN_URL/services/hello-service/plugins \
  -d "name=rate-limiting" \
  -d "config.minute=5"

# Test rate limiting
for i in {1..10}; do
  curl -w "\nStatus: %{http_code}\n" $ALB_URL/sbx/api/hello
  sleep 1
done

# Expected: First 5 requests succeed (200), rest fail (429)
```

### 2. Test Request Logging Plugin

```bash
# Add file-log plugin
curl -X POST $KONG_ADMIN_URL/services/hello-service/plugins \
  -d "name=file-log" \
  -d "config.path=/dev/stdout"

# Make a request
curl $ALB_URL/sbx/api/hello

# Check logs for request details
aws logs tail /ecs/sbxservice-dev-kong --since 1m
```

### 3. Test CORS Plugin

```bash
# Add CORS plugin
curl -X POST $KONG_ADMIN_URL/services/hello-service/plugins \
  -H "Content-Type: application/json" \
  -d '{
    "name": "cors",
    "config": {
      "origins": ["*"],
      "methods": ["GET", "POST"],
      "headers": ["Accept", "Content-Type"],
      "exposed_headers": ["X-Auth-Token"],
      "credentials": true,
      "max_age": 3600
    }
  }'

# Test CORS headers
curl -v -H "Origin: http://example.com" $ALB_URL/sbx/api/hello | grep -i "access-control"

# Expected: CORS headers in response
```

## Failure Recovery Testing

### 1. Test Control Plane Restart

```bash
# Stop control plane task
TASK_ARN=$(aws ecs list-tasks \
  --cluster sbxservice-dev-cluster \
  --service-name sbxservice-dev-kong-cp-service \
  --query 'taskArns[0]' --output text)

aws ecs stop-task --cluster sbxservice-dev-cluster --task $TASK_ARN

# Wait for new task to start
aws ecs wait services-stable \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-cp-service

# Verify data planes reconnect
curl $KONG_ADMIN_URL/clustering/data-planes | jq '.data[].status'

# Expected: All "connected"
```

### 2. Test Data Plane Restart

```bash
# Stop a data plane task
TASK_ARN=$(aws ecs list-tasks \
  --cluster sbxservice-dev-cluster \
  --service-name sbxservice-dev-kong-service \
  --query 'taskArns[0]' --output text)

aws ecs stop-task --cluster sbxservice-dev-cluster --task $TASK_ARN

# Traffic should continue through other data planes
while true; do
  curl -s $ALB_URL/sbx/api/hello && echo " - OK"
  sleep 1
done

# Expected: Continuous successful responses
```

### 3. Test Database Connection Loss

```bash
# Stop PostgreSQL task
TASK_ARN=$(aws ecs list-tasks \
  --cluster sbxservice-dev-cluster \
  --service-name sbxservice-dev-postgres-service \
  --query 'taskArns[0]' --output text)

aws ecs stop-task --cluster sbxservice-dev-cluster --task $TASK_ARN

# Data planes should continue serving with cached config
curl $ALB_URL/sbx/api/hello

# Expected: Still works (data planes are DB-less)

# Admin API should fail
curl $KONG_ADMIN_URL/status

# Expected: Database unreachable error

# Wait for PostgreSQL to restart
aws ecs wait services-stable \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-postgres-service

# Admin API should recover
curl $KONG_ADMIN_URL/status

# Expected: Database reachable
```

## Performance Testing

### 1. Basic Load Test

```bash
# Install hey if not available
# go install github.com/rakyll/hey@latest

# Run load test
hey -n 1000 -c 10 $ALB_URL/sbx/api/hello

# Check results:
# - Total requests
# - Success rate
# - Response time distribution
```

### 2. Monitor Kong Performance

```bash
# Watch Kong metrics
watch -n 2 "curl -s $KONG_ADMIN_URL/status | jq '.server'"

# Monitor CloudWatch metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=sbxservice-dev-kong-service \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Average
```

## Monitoring and Observability Testing

### 1. CloudWatch Logs

```bash
# Kong Control Plane logs
aws logs tail /ecs/sbxservice-dev-kong-cp --follow

# Kong Data Plane logs
aws logs tail /ecs/sbxservice-dev-kong --follow

# PostgreSQL logs
aws logs tail /ecs/sbxservice-dev-postgres --follow
```

### 2. ECS Service Metrics

```bash
# Get service details
aws ecs describe-services \
  --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-kong-cp-service sbxservice-dev-kong-service \
  --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount,status:status}'
```

### 3. Load Balancer Health

```bash
# Check ALB target health
ALB_TG_ARN=$(cd terraform && terraform output -raw alb_target_group_arn)
aws elbv2 describe-target-health --target-group-arn $ALB_TG_ARN

# Check Kong NLB target health
KONG_TG_ARN=$(cd terraform && terraform output -raw kong_nlb_target_group_arn)
aws elbv2 describe-target-health --target-group-arn $KONG_TG_ARN
```

## Test Checklist

- [ ] Infrastructure deploys successfully
- [ ] All ECS services are running
- [ ] PostgreSQL is healthy
- [ ] Kong Control Plane is accessible via Admin API
- [ ] Data planes connect to control plane
- [ ] Services can be created via Admin API
- [ ] Routes can be created via Admin API
- [ ] Traffic flows through Kong to hello-service
- [ ] Load balancing works across multiple requests
- [ ] Configuration changes propagate to data planes
- [ ] Plugins can be added and work correctly
- [ ] Control plane restart doesn't affect traffic
- [ ] Data plane restart doesn't cause downtime
- [ ] Logs are available in CloudWatch
- [ ] Metrics are available in CloudWatch

## Troubleshooting Common Issues

### Issue: Kong Control Plane won't start

**Check:**
```bash
# PostgreSQL status
aws ecs describe-services --cluster sbxservice-dev-cluster \
  --services sbxservice-dev-postgres-service

# Control plane logs
aws logs tail /ecs/sbxservice-dev-kong-cp --since 10m
```

**Common causes:**
- PostgreSQL not ready
- Database migrations failed
- Network connectivity issues

### Issue: Data planes not connecting

**Check:**
```bash
# Data plane logs
aws logs tail /ecs/sbxservice-dev-kong --since 10m

# Control plane reachability
curl $KONG_ADMIN_URL/clustering/data-planes
```

**Common causes:**
- Control plane not ready
- Security group blocking ports 8005/8006
- Service discovery DNS issues

### Issue: Routes not working

**Check:**
```bash
# Verify service exists
curl $KONG_ADMIN_URL/services/hello-service

# Verify routes exist
curl $KONG_ADMIN_URL/services/hello-service/routes

# Test Kong directly
KONG_NLB=$(cd terraform && terraform output -raw kong_nlb_dns_name)
curl -v http://$KONG_NLB:8000/hello
```

**Common causes:**
- Service not configured
- Route paths incorrect
- Upstream service not reachable

## Success Criteria

✅ All services deployed and running
✅ Kong Admin API accessible and responsive
✅ Data planes connected to control plane
✅ Hello service accessible through Kong
✅ Configuration changes propagate in real-time
✅ No downtime during component restarts
✅ Logs and metrics available
✅ Load balancing working correctly

## Next Steps After Testing

1. **Production Readiness**
   - Add authentication to Admin API
   - Enable HTTPS with proper certificates
   - Set up monitoring and alerting
   - Configure backup for PostgreSQL

2. **Advanced Features**
   - Add more services and routes
   - Configure advanced plugins
   - Set up custom plugins
   - Implement CI/CD for Kong configuration

3. **Optimization**
   - Tune database performance
   - Optimize data plane count
   - Configure caching
   - Set up CDN if needed

