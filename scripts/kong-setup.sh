#!/bin/bash
set -e

# Kong Gateway Management Script
# This script helps configure Kong Gateway with hello-service routing

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if KONG_ADMIN_URL is set
if [ -z "$KONG_ADMIN_URL" ]; then
    print_error "KONG_ADMIN_URL environment variable is not set"
    print_info "Please set it to your Kong Admin API endpoint:"
    print_info "  export KONG_ADMIN_URL=http://your-kong-admin-nlb:8001"
    exit 1
fi

print_info "Using Kong Admin API: $KONG_ADMIN_URL"

# Function to check Kong health
check_kong_health() {
    print_info "Checking Kong Control Plane health..."
    if curl -s -f "$KONG_ADMIN_URL/status" > /dev/null; then
        print_info "Kong Control Plane is healthy"
        return 0
    else
        print_error "Kong Control Plane is not responding"
        return 1
    fi
}

# Function to create a service
create_service() {
    local service_name=$1
    local service_url=$2
    
    print_info "Creating service: $service_name"
    
    response=$(curl -s -w "\n%{http_code}" -X POST "$KONG_ADMIN_URL/services" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$service_name\",
            \"url\": \"$service_url\"
        }")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "409" ]; then
        print_info "Service '$service_name' created or already exists"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 0
    else
        print_error "Failed to create service (HTTP $http_code)"
        echo "$body"
        return 1
    fi
}

# Function to create a route
create_route() {
    local service_name=$1
    local route_path=$2
    local route_name=$3
    
    print_info "Creating route: $route_name for service: $service_name"
    
    response=$(curl -s -w "\n%{http_code}" -X POST "$KONG_ADMIN_URL/services/$service_name/routes" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$route_name\",
            \"paths\": [\"$route_path\"],
            \"strip_path\": false
        }")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "409" ]; then
        print_info "Route '$route_name' created or already exists"
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
        return 0
    else
        print_error "Failed to create route (HTTP $http_code)"
        echo "$body"
        return 1
    fi
}

# Function to list all services
list_services() {
    print_info "Listing all services..."
    curl -s "$KONG_ADMIN_URL/services" | jq '.' 2>/dev/null || curl -s "$KONG_ADMIN_URL/services"
}

# Function to list all routes
list_routes() {
    print_info "Listing all routes..."
    curl -s "$KONG_ADMIN_URL/routes" | jq '.' 2>/dev/null || curl -s "$KONG_ADMIN_URL/routes"
}

# Function to setup hello-service
setup_hello_service() {
    local hello_service_url=${1:-"http://sbxservice.sbxservice.dev.local:8080"}
    
    print_info "Setting up hello-service with Kong Gateway"
    print_info "Service URL: $hello_service_url"
    
    # Create service
    create_service "hello-service" "$hello_service_url"
    
    # Create routes
    create_route "hello-service" "/hello" "hello-route"
    create_route "hello-service" "/actuator/health" "health-route"
    
    print_info "Hello-service setup complete!"
}

# Function to setup booth-arrival-service
# Implemented in repository: sbxservice-booth-arrival
setup_booth_arrival_service() {
    local booth_arrival_service_url=${1:-"http://booth-arrival.sbxservice.dev.local:8080"}
    
    print_info "Setting up booth-arrival-service with Kong Gateway"
    print_info "Service URL: $booth_arrival_service_url"
    
    # Create service
    create_service "booth-arrival-service" "$booth_arrival_service_url"
    
    # Create routes
    create_route "booth-arrival-service" "/booth-arrival/customer-search-method" "booth-arrival-customer-search-method-route"
    
    print_info "Booth-arrival-service setup complete!"
}

# Main script
main() {
    print_info "=== Kong Gateway Setup Script ==="
    
    # Check Kong health
    if ! check_kong_health; then
        print_error "Cannot proceed without healthy Kong Control Plane"
        exit 1
    fi
    
    # Parse command
    case "${1:-setup}" in
        setup)
            setup_hello_service "$2"
            ;;
        setup-booth-arrival)
            setup_booth_arrival_service "$2"
            ;;
        list-services)
            list_services
            ;;
        list-routes)
            list_routes
            ;;
        health)
            check_kong_health
            ;;
        *)
            print_info "Usage: $0 {setup|setup-booth-arrival|list-services|list-routes|health} [service-url]"
            print_info ""
            print_info "Commands:"
            print_info "  setup [url]                - Setup hello-service with Kong (default URL: http://sbxservice.sbxservice.dev.local:8080)"
            print_info "  setup-booth-arrival [url]  - Setup booth-arrival-service with Kong (default URL: http://booth-arrival.sbxservice.dev.local:8080)"
            print_info "                               Implements: /booth-arrival/customer-search-method (repo: sbxservice-booth-arrival)"
            print_info "  list-services              - List all Kong services"
            print_info "  list-routes                - List all Kong routes"
            print_info "  health                     - Check Kong Control Plane health"
            print_info ""
            print_info "Environment Variables:"
            print_info "  KONG_ADMIN_URL    - Kong Admin API endpoint (required)"
            exit 1
            ;;
    esac
}

main "$@"

