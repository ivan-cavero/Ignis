#!/bin/bash
# Ignis Deployment System
# Functional deployment script for Ignis ERP with enhanced options
#
# Author: v0
# Version: 3.0.0
# License: MIT

# === CONFIGURATION ===
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly LOG_DIR="$PROJECT_ROOT/logs/deployments"
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Default settings (can be overridden by command line arguments)
ENVIRONMENT="production"
BRANCH="main"
COMPONENT=""
FORCE_REBUILD=false
EXTRACT_CERTS=true
RESTART_SERVICES=true
VERIFY_DOCKER_HOST=true
PULL_CHANGES=true
SKIP_LOGS=false
VERBOSE=false

# === HELPER FUNCTIONS ===

# Pure function to print a formatted message
print_message() {
  local color="$1"
  local level="$2"
  local message="$3"
  local timestamp="$(date "+%Y-%m-%d %H:%M:%S")"
  
  if [ "$SKIP_LOGS" = false ]; then
    echo -e "${color}[${timestamp}] [${level}] ${message}${COLOR_RESET}"
  fi
}

# Pure function to log info message
log_info() {
  print_message "$COLOR_INFO" "INFO" "$1"
}

# Pure function to log success message
log_success() {
  print_message "$COLOR_SUCCESS" "SUCCESS" "$1"
}

# Pure function to log warning message
log_warning() {
  print_message "$COLOR_WARNING" "WARNING" "$1"
}

# Pure function to log error message
log_error() {
  print_message "$COLOR_ERROR" "ERROR" "$1"
}

# Pure function to show help message
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
  
  --no-restart-services  Don't restart systemd services
  
  --no-verify-host       Skip Docker-to-host communication verification
  
  --no-pull              Skip pulling Git changes
  
  --skip-logs            Minimize console output
  
  --verbose              Show verbose output
  
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

# Pure function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Pure function to check if a file exists
file_exists() {
  [ -f "$1" ]
}

# Pure function to check if a directory exists
dir_exists() {
  [ -d "$1" ]
}

# Pure function to check if two files are different
files_differ() {
  ! cmp -s "$1" "$2"
}

# Pure function to parse arguments
parse_arguments() {
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
      --no-restart-services)
        RESTART_SERVICES=false
        shift
        ;;
      --no-verify-host)
        VERIFY_DOCKER_HOST=false
        shift
        ;;
      --no-pull)
        PULL_CHANGES=false
        shift
        ;;
      --skip-logs)
        SKIP_LOGS=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        log_warning "Unknown option: $1"
        shift
        ;;
    esac
  done
}

# === DEPLOYMENT FUNCTIONS ===

# Update environment variables
update_environment() {
  log_info "Updating environment variables for $ENVIRONMENT"
  
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
  
  log_success "Environment variables updated"
}

# Verify Docker-to-host communication
verify_docker_host_communication() {
  if [ "$VERIFY_DOCKER_HOST" != true ]; then
    return 0
  fi
  
  log_info "Verifying Docker-to-host communication"
  
  # Check if host.docker.internal is in /etc/hosts
  if ! grep -q "host.docker.internal" /etc/hosts; then
    log_info "Adding host.docker.internal to /etc/hosts"
    echo "172.17.0.1 host.docker.internal" | sudo tee -a /etc/hosts > /dev/null
    log_success "Added host.docker.internal to /etc/hosts"
  else
    log_success "host.docker.internal already configured in /etc/hosts"
  fi
  
  # Check iptables rules
  if ! sudo iptables -C INPUT -i docker0 -j ACCEPT 2>/dev/null; then
    log_info "Adding iptables rule for Docker bridge"
    sudo iptables -I INPUT -i docker0 -j ACCEPT
    log_success "Added iptables rule for Docker bridge"
  else
    log_success "Iptables rule for Docker bridge already exists"
  fi
  
  # Test connection from Traefik to webhook
  if docker exec traefik curl -s http://host.docker.internal:3333/health --connect-timeout 5 > /dev/null 2>&1; then
    log_success "Traefik can connect to webhook server using host.docker.internal"
  else
    log_warning "Traefik cannot connect to webhook server using host.docker.internal"
    
    # Try with direct IP
    if docker exec traefik curl -s http://172.17.0.1:3333/health --connect-timeout 5 > /dev/null 2>&1; then
      log_success "Traefik can connect to webhook server using direct IP"
      
      # Update webhook.yml to use direct IP
      local webhook_config="$PROJECT_ROOT/proxy/dynamic/webhook.yml"
      if [ -f "$webhook_config" ]; then
        log_info "Updating webhook configuration to use direct IP"
        sed -i 's|url: "http://host.docker.internal:3333"|url: "http://172.17.0.1:3333"|' "$webhook_config"
        
        # Restart Traefik
        log_info "Restarting Traefik"
        docker restart traefik
      fi
    else
      log_error "Traefik cannot connect to webhook server"
    fi
  fi
}

# Extract SSL certificates
extract_certificates() {
  if [ "$EXTRACT_CERTS" != true ]; then
    return 0
  fi
  
  local script="$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  if [ -f "$script" ]; then
    log_info "Extracting SSL certificates"
    bash "$script"
  fi
}

# Deploy systemd services
deploy_services() {
  log_info "Deploying systemd services"
  
  local service_dir="$PROJECT_ROOT/deployments/service"
  local updated=false
  
  if ! dir_exists "$service_dir"; then
    log_warning "Service directory not found: $service_dir"
    return 0
  fi
  
  # Find all service files
  local service_files=()
  while IFS= read -r -d '' file; do
    service_files+=("$file")
  done < <(find "$service_dir" -name "*.service" -type f -print0)
  
  if [ ${#service_files[@]} -eq 0 ]; then
    log_info "No service files found"
    return 0
  fi
  
  # Process each service file
  for src in "${service_files[@]}"; do
    local service_name="$(basename "$src" .service)"
    local dst="/etc/systemd/system/${service_name}.service"
    
    if [ ! -f "$dst" ] || files_differ "$src" "$dst"; then
      log_info "Updating service: $service_name"
      sudo cp "$src" "$dst"
      updated=true
      
      # Enable the service
      sudo systemctl enable "$service_name"
      
      # Restart the service if requested
      if [ "$RESTART_SERVICES" = true ]; then
        # Check if service is already running
        if systemctl is-active --quiet "$service_name"; then
          log_info "Restarting service: $service_name"
          sudo systemctl restart "$service_name"
        else
          log_info "Starting service: $service_name"
          sudo systemctl start "$service_name"
        fi
      fi
    fi
  done
  
  if [ "$updated" = true ]; then
    log_info "Reloading systemd daemon"
    sudo systemctl daemon-reload
  fi
  
  log_success "Services deployed"
}

# Deploy a specific component
deploy_component() {
  local component="$1"
  
  log_info "Deploying component: $component"
  
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
      log_error "Unknown component: $component"
      return 1
      ;;
  esac
  
  log_success "Component $component deployed"
}

# Check and fix acme.json file
check_acme_file() {
  log_info "Checking acme.json file"
  
  local acme_file="$PROJECT_ROOT/proxy/acme.json"
  
  # Check if acme.json exists
  if [ ! -e "$acme_file" ]; then
    log_info "acme.json does not exist, creating it"
    touch "$acme_file"
    chmod 600 "$acme_file"
    log_success "Created acme.json file"
    return 0
  fi
  
  # Check if acme.json is a directory (the issue)
  if [ -d "$acme_file" ]; then
    log_warning "acme.json is a directory instead of a file, fixing..."
    
    # Stop Traefik first to release the mount
    if docker ps | grep -q traefik; then
      log_info "Stopping Traefik container to fix mount issue"
      docker stop traefik
    fi
    
    # Remove the directory
    rm -rf "$acme_file"
    
    # Create the file with proper permissions
    touch "$acme_file"
    chmod 600 "$acme_file"
    
    log_success "Fixed acme.json (converted from directory to file)"
    return 0
  fi
  
  # Check permissions
  if [ "$(stat -c %a "$acme_file")" != "600" ]; then
    log_warning "acme.json has incorrect permissions, fixing..."
    chmod 600 "$acme_file"
    log_success "Fixed acme.json permissions"
  else
    log_success "acme.json exists with correct permissions"
  fi
}

# Deploy full infrastructure
deploy_infrastructure() {
  log_info "Deploying full infrastructure"
  
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
  if [ "$PULL_CHANGES" = true ] && [ -d "$PROJECT_ROOT/.git" ]; then
    log_info "Pulling latest changes from git"
    sudo -u $USER git -C "$PROJECT_ROOT" checkout "$BRANCH" && \
    sudo -u $USER git -C "$PROJECT_ROOT" pull origin "$BRANCH"
  fi
  
  # Verify Docker-to-host communication
  verify_docker_host_communication
  
  # Determine compose file
  local compose_file="docker-compose.yml"
  local env_file=""
  
  if [ "$ENVIRONMENT" = "development" ]; then
    env_file="docker-compose.development.yml"
  else
    env_file="docker-compose.yml"
  fi
  
  # Check and fix acme.json file
  check_acme_file
  
  # Start or restart containers
  log_info "Starting Docker infrastructure"
  
  if [ "$FORCE_REBUILD" = true ]; then
    log_info "Forcing rebuild of all containers"
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} down
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} up -d --build
  else
    docker compose -f "$compose_file" ${env_file:+ -f "$env_file"} up -d
  fi
  
  # Deploy services
  deploy_services
  
  log_success "Infrastructure deployed"
}

# Generate deployment summary
generate_summary() {
  log_info "Deployment summary"
  
  echo "--- Docker Status ---"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "ignis\|traefik"
  
  echo "--- Service Status ---"
  systemctl list-units --type=service --all | grep "ignis"
  
  echo "--- Webhook Status ---"
  if pgrep -f "bun run server.ts" > /dev/null; then
    echo "Webhook server: Running"
    
    # Check if webhook is responding
    if curl -s http://localhost:3333/health > /dev/null 2>&1; then
      echo "Webhook health: OK"
      if [ "$VERBOSE" = true ]; then
        echo "Response: $(curl -s http://localhost:3333/health)"
      fi
    else
      echo "Webhook health: Not responding"
    fi
  else
    echo "Webhook server: Not running"
  fi
  
  # Show Docker-to-host communication status if verbose
  if [ "$VERBOSE" = true ]; then
    echo "--- Docker-to-Host Communication ---"
    if docker exec traefik curl -s http://host.docker.internal:3333/health --connect-timeout 2 > /dev/null 2>&1; then
      echo "Traefik to webhook (host.docker.internal): OK"
    else
      echo "Traefik to webhook (host.docker.internal): Failed"
      
      if docker exec traefik curl -s http://172.17.0.1:3333/health --connect-timeout 2 > /dev/null 2>&1; then
        echo "Traefik to webhook (172.17.0.1): OK"
      else
        echo "Traefik to webhook (172.17.0.1): Failed"
      fi
    fi
  fi
}

# === MAIN FUNCTION ===

main() {
  # Parse arguments
  parse_arguments "$@"
  
  # Create log directory
  mkdir -p "$LOG_DIR"
  
  # Log file with timestamp
  local log_file="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
  
  # Redirect output to log file if not skipping logs
  if [ "$SKIP_LOGS" = false ]; then
    exec > >(tee -a "$log_file") 2>&1
  fi
  
  log_info "Starting deployment"
  
  # Check prerequisites
  log_info "Checking prerequisites"
  if ! command_exists docker || ! (command_exists docker-compose || docker compose version &> /dev/null); then
    log_error "Docker or Docker Compose not found"
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
  
  log_success "Deployment completed"
  
  if [ "$SKIP_LOGS" = false ]; then
    echo "Log file: $log_file"
  fi
}

# Execute main function with all arguments
main "$@"
