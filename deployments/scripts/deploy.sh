#!/bin/bash
# Ignis Deployment System
# Simple, functional deployment script for Ignis ERP
#
# Author: v0
# Version: 2.0.0
# License: MIT

# === CONFIGURATION ===
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/deployments"
ENVIRONMENT="production"
BRANCH="main"
COMPONENT=""
FORCE_REBUILD=false
EXTRACT_CERTS=true

# === HELPER FUNCTIONS ===

# Print formatted message
log() {
  local timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
  echo "[${timestamp}] [$1] $2"
}

# Show help message
show_help() {
  cat << EOF
Ignis Deployment Script

USAGE:
  ./deploy.sh [OPTIONS]

OPTIONS:
  --component=NAME       Deploy specific component:
                         backend, user-frontend, admin-frontend, 
                         landing-frontend, proxy, services, infrastructure
  
  --environment=ENV      Set deployment environment (production, development)
                         Default: production
  
  --branch=BRANCH        Set Git branch to deploy
                         Default: main
  
  --force-rebuild        Force rebuild of Docker containers
  
  --no-extract-certs     Skip SSL certificate extraction
  
  --help                 Show this help message

EXAMPLES:
  # Deploy everything
  ./deploy.sh
  
  # Deploy only backend in development environment
  ./deploy.sh --component=backend --environment=development
  
  # Deploy services (systemd services)
  ./deploy.sh --component=services
  
  # Force rebuild of all containers
  ./deploy.sh --force-rebuild
EOF
}

# Check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if a file exists
file_exists() {
  [ -f "$1" ]
}

# Check if a directory exists
dir_exists() {
  [ -d "$1" ]
}

# Check if two files are different
files_differ() {
  ! cmp -s "$1" "$2"
}

# === DEPLOYMENT FUNCTIONS ===

# Update environment variables
update_environment() {
  log "INFO" "Updating environment variables for $ENVIRONMENT"
  
  local env_file="$PROJECT_ROOT/.env"
  
  # Ensure webhook secret exists
  if ! grep -q "WEBHOOK_SECRET=" "$env_file" 2>/dev/null; then
    local secret="ignis_webhook_secret_$(date +%s | sha256sum | base64 | head -c 32)"
    echo "WEBHOOK_SECRET=$secret" >> "$env_file"
  fi
  
  # Update environment setting
  if grep -q "ENVIRONMENT=" "$env_file" 2>/dev/null; then
    sed -i "s/ENVIRONMENT=.*/ENVIRONMENT=$ENVIRONMENT/" "$env_file"
  else
    echo "ENVIRONMENT=$ENVIRONMENT" >> "$env_file"
  fi
  
  log "SUCCESS" "Environment variables updated"
}

# Extract SSL certificates
extract_certificates() {
  if [ "$EXTRACT_CERTS" != true ]; then
    return 0
  fi
  
  local script="$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  if [ -f "$script" ]; then
    log "INFO" "Extracting SSL certificates"
    bash "$script"
  fi
}

# Deploy systemd services
deploy_services() {
  log "INFO" "Deploying systemd services"
  
  local service_dir="$PROJECT_ROOT/deployments/service"
  local updated=false
  
  if ! dir_exists "$service_dir"; then
    log "WARNING" "Service directory not found: $service_dir"
    return 0
  fi
  
  # Find all service files
  local service_files=()
  while IFS= read -r -d '' file; do
    service_files+=("$file")
  done < <(find "$service_dir" -name "*.service" -type f -print0)
  
  if [ ${#service_files[@]} -eq 0 ]; then
    log "INFO" "No service files found"
    return 0
  fi
  
  # Process each service file
  for src in "${service_files[@]}"; do
    local service_name="$(basename "$src" .service)"
    local dst="/etc/systemd/system/${service_name}.service"
    
    if [ ! -f "$dst" ] || files_differ "$src" "$dst"; then
      log "INFO" "Updating service: $service_name"
      sudo cp "$src" "$dst"
      updated=true
      
      # Enable and restart the service
      sudo systemctl enable "$service_name"
      
      # Check if service is already running
      if systemctl is-active --quiet "$service_name"; then
        log "INFO" "Restarting service: $service_name"
        sudo systemctl restart "$service_name"
      else
        log "INFO" "Starting service: $service_name"
        sudo systemctl start "$service_name"
      fi
    fi
  done
  
  if [ "$updated" = true ]; then
    log "INFO" "Reloading systemd daemon"
    sudo systemctl daemon-reload
  fi
  
  log "SUCCESS" "Services deployed"
}

# Deploy a specific component
deploy_component() {
  local component="$1"
  
  log "INFO" "Deploying component: $component"
  
  case "$component" in
    backend|admin-frontend|user-frontend|landing-frontend|proxy)
      cd "$PROJECT_ROOT"
      if [ "$FORCE_REBUILD" = true ]; then
        docker compose up -d --build "$component"
      else
        docker compose up -d "$component"
      fi
      ;;
      
    services)
      deploy_services
      ;;
      
    infrastructure)
      deploy_infrastructure
      ;;
      
    *)
      log "ERROR" "Unknown component: $component"
      return 1
      ;;
  esac
  
  log "SUCCESS" "Component $component deployed"
}

# Deploy full infrastructure
deploy_infrastructure() {
  log "INFO" "Deploying full infrastructure"
  
  cd "$PROJECT_ROOT"
  
  # Create required directories
  mkdir -p "$PROJECT_ROOT/proxy/certs" "$PROJECT_ROOT/logs/webhook" "$PROJECT_ROOT/logs/deployments"
  
  # Create acme.json if it doesn't exist
  if [ ! -f "$PROJECT_ROOT/proxy/acme.json" ]; then
    touch "$PROJECT_ROOT/proxy/acme.json"
    chmod 600 "$PROJECT_ROOT/proxy/acme.json"
  fi
  
  # Update environment variables
  update_environment
  
  # Pull latest changes if git repository exists
  if [ -d "$PROJECT_ROOT/.git" ]; then
    log "INFO" "Pulling latest changes from git"
    git checkout "$BRANCH" && git pull origin "$BRANCH"
  fi
  
  # Determine compose file
  local compose_file="docker-compose.yml"
  local env_file=""
  
  if [ "$ENVIRONMENT" = "development" ]; then
    env_file="docker-compose.development.yml"
  else
    env_file="docker-compose.yml"
  fi
  
  # Start or restart containers
  log "INFO" "Starting Docker infrastructure"
  
  if [ "$FORCE_REBUILD" = true ]; then
    log "INFO" "Forcing rebuild of all containers"
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} down
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} up -d --build
  else
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} up -d
  fi
  
  # Deploy services
  deploy_services
  
  log "SUCCESS" "Infrastructure deployed"
}

# Generate deployment summary
generate_summary() {
  log "INFO" "Deployment summary"
  
  echo "--- Docker Status ---"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "ignis\|traefik"
  
  echo "--- Service Status ---"
  systemctl list-units --type=service --all | grep "ignis"
  
  echo "--- Webhook Status ---"
  if pgrep -f "bun run server.ts" > /dev/null; then
    echo "Webhook server: Running"
  else
    echo "Webhook server: Not running"
  fi
}

# === MAIN FUNCTION ===

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --component=*)
      COMPONENT="${1#*=}"
      shift
      ;;
    --environment=*)
      ENVIRONMENT="${1#*=}"
      shift
      ;;
    --branch=*)
      BRANCH="${1#*=}"
      shift
      ;;
    --force-rebuild)
      FORCE_REBUILD=true
      shift
      ;;
    --no-extract-certs)
      EXTRACT_CERTS=false
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      log "WARNING" "Unknown option: $1"
      shift
      ;;
  esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Log file with timestamp
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "INFO" "Starting deployment"

# Check prerequisites
log "INFO" "Checking prerequisites"
if ! command_exists docker || ! (command_exists docker-compose || docker compose version &> /dev/null); then
  log "ERROR" "Docker or Docker Compose not found"
  exit 1
fi

# Deploy component or full infrastructure
if [ -n "$COMPONENT" ]; then
  deploy_component "$COMPONENT"
else
  deploy_infrastructure
fi

# Extract certificates if enabled
extract_certificates

# Generate summary
generate_summary

log "SUCCESS" "Deployment completed"
echo "Log file: $LOG_FILE"