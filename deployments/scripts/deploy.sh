#!/bin/bash
# Ignis Unified Deployment Script
# This script handles all deployment operations for the Ignis system
# 
# Author: v0
# Version: 2.0.0
# License: MIT

# Exit on any error
set -e

# ==================== CONFIGURATION ====================
# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Default settings
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly LOG_DIR="$PROJECT_ROOT/logs/deployments"
readonly LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

# Feature flags (can be overridden by command line arguments)
FORCE_REBUILD=false
LOG_TO_FILE=true
COMPONENT=""
ENVIRONMENT="production"
BRANCH="main"
EXTRACT_CERTS=true

# Domain configuration
readonly DOMAIN_CONFIG=(
  # Format: "component:production-domain:development-domain"
  "backend:api.ivancavero.com:dev-api.ivancavero.com"
  "admin-frontend:admin.ivancavero.com:dev-admin.ivancavero.com"
  "user-frontend:app.ivancavero.com:dev-app.ivancavero.com"
  "landing-frontend:ivancavero.com:dev.ivancavero.com"
  "webhook:vps.ivancavero.com:vps.ivancavero.com"
)

# ==================== UTILITY FUNCTIONS ====================

# Pure function to log a message
log() {
  local level="$1"
  local message="$2"
  local color="$COLOR_INFO"
  
  case "$level" in
    "INFO") color="$COLOR_INFO" ;;
    "SUCCESS") color="$COLOR_SUCCESS" ;;
    "WARNING") color="$COLOR_WARNING" ;;
    "ERROR") color="$COLOR_ERROR" ;;
  esac
  
  echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message${COLOR_RESET}"
  
  if [ "$LOG_TO_FILE" = true ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
  fi
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

# Pure function to check if a docker container is running
is_container_running() {
  docker ps --format "{{.Names}}" | grep -q "^$1$"
}

# Pure function to get domain for a component based on environment
get_domain() {
  local component="$1"
  local env="$2"
  local domain=""
  
  for config in "${DOMAIN_CONFIG[@]}"; do
    local comp=$(echo "$config" | cut -d: -f1)
    if [ "$comp" = "$component" ]; then
      if [ "$env" = "production" ]; then
        domain=$(echo "$config" | cut -d: -f2)
      else
        domain=$(echo "$config" | cut -d: -f3)
      fi
      break
    fi
  done
  
  echo "$domain"
}

# Function to parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component=*)
        COMPONENT="${1#*=}"
        ;;
      --environment=*)
        ENVIRONMENT="${1#*=}"
        ;;
      --branch=*)
        BRANCH="${1#*=}"
        ;;
      --force-rebuild)
        FORCE_REBUILD=true
        ;;
      --no-log)
        LOG_TO_FILE=false
        ;;
      --no-extract-certs)
        EXTRACT_CERTS=false
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        log "ERROR" "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
  
  # Validate environment
  if [ "$ENVIRONMENT" != "production" ] && [ "$ENVIRONMENT" != "development" ]; then
    log "ERROR" "Invalid environment: $ENVIRONMENT. Must be 'production' or 'development'"
    exit 1
  fi
  
  # Set default branch based on environment if not specified
  if [ "$BRANCH" = "main" ] && [ "$ENVIRONMENT" = "development" ]; then
    BRANCH="dev"
    log "INFO" "Setting branch to 'dev' for development environment"
  elif [ "$BRANCH" = "dev" ] && [ "$ENVIRONMENT" = "production" ]; then
    BRANCH="main"
    log "INFO" "Setting branch to 'main' for production environment"
  fi
}

# Function to show help
show_help() {
  cat << EOF
Ignis Unified Deployment Script

Usage: $0 [options]

Options:
  --component=NAME      Deploy specific component (backend, admin-frontend, user-frontend, landing-frontend, proxy, webhook, infrastructure)
  --environment=ENV     Set deployment environment (production, development)
  --branch=BRANCH       Set Git branch to deploy (main, dev)
  --force-rebuild       Force rebuild of all containers
  --no-log              Don't write logs to file
  --no-extract-certs    Skip certificate extraction
  --help                Show this help message

Examples:
  $0                                  # Deploy full production infrastructure
  $0 --component=backend              # Deploy only backend in production
  $0 --environment=development        # Deploy full development infrastructure
  $0 --component=backend --environment=development  # Deploy backend in development environment
  $0 --component=backend --force-rebuild  # Rebuild and deploy backend
EOF
}

# Initialize log file
initialize_log_file() {
  if [ "$LOG_TO_FILE" = true ]; then
    mkdir -p "$LOG_DIR"
    echo "=== IGNIS DEPLOYMENT LOG - $(date) ===" > "$LOG_FILE"
    log "INFO" "Logging to file: $LOG_FILE"
  fi
}

# ==================== DEPLOYMENT FUNCTIONS ====================

# Check prerequisites
check_prerequisites() {
  log "INFO" "Checking prerequisites"
  
  local missing_requirements=()
  
  # Check for Docker
  if ! command_exists docker; then
    missing_requirements+=("Docker")
  fi
  
  # Check for Docker Compose
  if ! command_exists docker-compose && ! docker compose version > /dev/null 2>&1; then
    missing_requirements+=("Docker Compose")
  fi
  
  # Check for project directory
  if [ ! -d "$PROJECT_ROOT" ]; then
    missing_requirements+=("Project directory ($PROJECT_ROOT)")
  fi
  
  # Check for docker-compose.yml
  if [ ! -f "$PROJECT_ROOT/docker-compose.yml" ]; then
    missing_requirements+=("docker-compose.yml file")
  fi
  
  # Report missing requirements
  if [ ${#missing_requirements[@]} -gt 0 ]; then
    log "ERROR" "Missing requirements: ${missing_requirements[*]}"
    log "ERROR" "Please run the init-ignis.sh script first to set up the system"
    return 1
  fi
  
  log "SUCCESS" "All prerequisites met"
  return 0
}

# Update environment variables for deployment
update_environment_variables() {
  local env="$1"
  
  log "INFO" "Updating environment variables for $env environment"
  
  # Create or update .env file
  local env_file="$PROJECT_ROOT/.env"
  
  # Ensure WEBHOOK_SECRET exists
  if ! grep -q "WEBHOOK_SECRET=" "$env_file" 2>/dev/null; then
    log "INFO" "Adding WEBHOOK_SECRET to .env file"
    echo "WEBHOOK_SECRET=ignis_webhook_secret_$(date +%s | sha256sum | base64 | head -c 32)" >> "$env_file"
  fi
  
  # Update environment-specific variables
  if [ "$env" = "development" ]; then
    # Set development-specific variables
    if ! grep -q "ENVIRONMENT=" "$env_file" 2>/dev/null; then
      echo "ENVIRONMENT=development" >> "$env_file"
    else
      sed -i "s/ENVIRONMENT=.*/ENVIRONMENT=development/" "$env_file"
    fi
  else
    # Set production-specific variables
    if ! grep -q "ENVIRONMENT=" "$env_file" 2>/dev/null; then
      echo "ENVIRONMENT=production" >> "$env_file"
    else
      sed -i "s/ENVIRONMENT=.*/ENVIRONMENT=production/" "$env_file"
    fi
  fi
  
  log "SUCCESS" "Environment variables updated for $env environment"
}

# Extract certificates from acme.json
extract_certificates() {
  if [ "$EXTRACT_CERTS" != true ]; then
    log "INFO" "Skipping certificate extraction (--no-extract-certs flag provided)"
    return 0
  fi
  
  log "INFO" "Extracting certificates from acme.json"
  
  # Check if extract-certs.sh exists
  local extract_script="$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  
  if [ ! -f "$extract_script" ]; then
    log "ERROR" "Certificate extraction script not found at $extract_script"
    return 1
  fi
  
  # Run the extraction script
  bash "$extract_script"
  
  return 0
}

# Deploy full infrastructure
deploy_full_infrastructure() {
  local env="$1"
  
  log "INFO" "Deploying full infrastructure for $env environment"
  
  # Navigate to project directory
  cd "$PROJECT_ROOT"
  
  # Create required directories if they don't exist
  mkdir -p "$PROJECT_ROOT/proxy/certs"
  mkdir -p "$PROJECT_ROOT/logs/webhook"
  mkdir -p "$PROJECT_ROOT/logs/deployments"
  
  # Create acme.json file if it doesn't exist
  if [ ! -f "$PROJECT_ROOT/proxy/acme.json" ]; then
    log "INFO" "Creating acme.json file"
    touch "$PROJECT_ROOT/proxy/acme.json"
    chmod 600 "$PROJECT_ROOT/proxy/acme.json"
  fi
  
  # Update environment variables
  update_environment_variables "$env"
  
  # Pull latest changes if git repository exists
  if [ -d "$PROJECT_ROOT/.git" ]; then
    log "INFO" "Pulling latest changes from $BRANCH branch"
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
  fi
  
  # Use the appropriate compose file based on environment
  local compose_file="docker-compose.yml"
  local env_file=""
  
  if [ "$env" = "development" ]; then
    env_file="docker-compose.development.yml"
  else
    env_file="docker-compose.production.yml"
  fi
  
  # Deploy with or without rebuild
  if [ "$FORCE_REBUILD" = true ]; then
    log "INFO" "Forcing rebuild of all containers"
    if [ -f "$PROJECT_ROOT/$env_file" ]; then
      docker compose -f "$compose_file" -f "$env_file" down
      docker compose -f "$compose_file" -f "$env_file" up -d --build
    else
      docker compose -f "$compose_file" down
      docker compose -f "$compose_file" up -d --build
    fi
  else
    log "INFO" "Starting containers"
    if [ -f "$PROJECT_ROOT/$env_file" ]; then
      docker compose -f "$compose_file" -f "$env_file" up -d
    else
      docker compose -f "$compose_file" up -d
    fi
  fi
  
  # Check if containers are running
  local containers=("traefik" "ignis-backend" "ignis-admin-frontend" "ignis-user-frontend" "ignis-landing" "ignis-webhook")
  local failed_containers=()
  
  for container in "${containers[@]}"; do
    if ! is_container_running "$container"; then
      failed_containers+=("$container")
    fi
  done
  
  if [ ${#failed_containers[@]} -gt 0 ]; then
    log "WARNING" "Some containers failed to start: ${failed_containers[*]}"
    log "INFO" "Checking Docker logs for failed containers"
    
    for container in "${failed_containers[@]}"; do
      log "INFO" "Logs for $container:"
      docker logs "$container" 2>&1 | tail -n 20 >> "$LOG_FILE"
    done
    
    log "WARNING" "Infrastructure deployment partially completed"
    return 1
  else
    log "SUCCESS" "All containers started successfully"
    return 0
  fi
}

# Deploy specific component
deploy_component() {
  local component="$1"
  local env="$2"
  local branch="$3"
  
  log "INFO" "Deploying component: $component (environment: $env, branch: $branch)"
  
  # Get domain for component
  local domain=$(get_domain "$component" "$env")
  log "INFO" "Using domain: $domain"
  
  # Navigate to project directory
  cd "$PROJECT_ROOT"
  
  # Update environment variables
  update_environment_variables "$env"
  
  # Pull latest changes if git repository exists
  if [ -d "$PROJECT_ROOT/.git" ]; then
    log "INFO" "Pulling latest changes from $branch branch"
    git checkout "$branch"
    git pull origin "$branch"
  fi
  
  # Use the appropriate compose file based on environment
  local compose_file="docker-compose.yml"
  local env_file=""
  
  if [ "$env" = "development" ]; then
    env_file="docker-compose.development.yml"
  else
    env_file="docker-compose.production.yml"
  fi
  
  # Deploy based on component type
  case "$component" in
    "backend")
      log "INFO" "Deploying backend"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build backend
      else
        docker compose -f "$compose_file" up -d --build backend
      fi
      ;;
      
    "admin-frontend")
      log "INFO" "Deploying admin frontend"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build admin-frontend
      else
        docker compose -f "$compose_file" up -d --build admin-frontend
      fi
      ;;
      
    "user-frontend")
      log "INFO" "Deploying user frontend"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build user-frontend
      else
        docker compose -f "$compose_file" up -d --build user-frontend
      fi
      ;;
      
    "landing-frontend")
      log "INFO" "Deploying landing frontend"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build landing-frontend
      else
        docker compose -f "$compose_file" up -d --build landing-frontend
      fi
      ;;
      
    "proxy")
      log "INFO" "Deploying proxy configuration"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build traefik
      else
        docker compose -f "$compose_file" up -d --build traefik
      fi
      ;;
      
    "webhook")
      log "INFO" "Deploying webhook server"
      if [ -f "$PROJECT_ROOT/$env_file" ]; then
        docker compose -f "$compose_file" -f "$env_file" up -d --build webhook
      else
        docker compose -f "$compose_file" up -d --build webhook
      fi
      ;;
      
    "infrastructure")
      log "INFO" "Deploying full infrastructure"
      deploy_full_infrastructure "$env"
      return $?
      ;;
      
    *)
      log "ERROR" "Unknown component: $component"
      return 1
      ;;
  esac
  
  # Verify deployment
  local container_name=""
  case "$component" in
    "backend") container_name="ignis-backend" ;;
    "admin-frontend") container_name="ignis-admin-frontend" ;;
    "user-frontend") container_name="ignis-user-frontend" ;;
    "landing-frontend") container_name="ignis-landing" ;;
    "proxy") container_name="traefik" ;;
    "webhook") container_name="ignis-webhook" ;;
  esac
  
  if [ -n "$container_name" ] && is_container_running "$container_name"; then
    log "SUCCESS" "$component deployed successfully for $env environment"
    return 0
  else
    log "ERROR" "Failed to deploy $component"
    return 1
  fi
}

# Generate system summary
generate_summary() {
  log "INFO" "Generating system summary"
  
  echo -e "${COLOR_INFO}=== IGNIS DEPLOYMENT SUMMARY ===${COLOR_RESET}"
  
  # Environment info
  echo -e "${COLOR_INFO}Environment:${COLOR_RESET}"
  echo -e "  Environment: $ENVIRONMENT"
  echo -e "  Branch: $BRANCH"
  
  # Docker containers status
  echo -e "${COLOR_INFO}Docker Containers:${COLOR_RESET}"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "ignis\|traefik"
  
  # Certificate status
  echo -e "${COLOR_INFO}Certificate Status:${COLOR_RESET}"
  
  # Check for certificates in the certs directory
  local cert_dir="$PROJECT_ROOT/proxy/certs"
  if [ -d "$cert_dir" ]; then
    echo -e "  Available certificates:"
    for cert in "$cert_dir"/*.crt; do
      if [ -f "$cert" ]; then
        local domain=$(basename "$cert" .crt)
        local expiry=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
        echo -e "    - $domain (expires: $expiry)"
      fi
    done
  else
    echo -e "  No certificates found"
  fi
  
  # Domain information
  echo -e "${COLOR_INFO}Domain Configuration:${COLOR_RESET}"
  for config in "${DOMAIN_CONFIG[@]}"; do
    local comp=$(echo "$config" | cut -d: -f1)
    local prod_domain=$(echo "$config" | cut -d: -f2)
    local dev_domain=$(echo "$config" | cut -d: -f3)
    
    if [ "$ENVIRONMENT" = "production" ]; then
      echo -e "  $comp: $prod_domain"
    else
      echo -e "  $comp: $dev_domain"
    fi
  done
  
  # Next steps
  echo -e "${COLOR_WARNING}Next Steps:${COLOR_RESET}"
  echo -e "  1. Configure your GitHub repository to send webhooks to:"
  echo -e "     https://vps.ivancavero.com:3333/webhook"
  echo -e "  2. Set the webhook secret in your GitHub repository settings"
  echo -e "  3. Push changes to your repository to trigger deployments"
  
  log "SUCCESS" "Deployment completed"
}

# ==================== MAIN FUNCTION ====================
main() {
  log "INFO" "Starting Ignis deployment"
  
  # Parse command line arguments
  parse_arguments "$@"
  
  # Initialize log file
  initialize_log_file
  
  # Check prerequisites
  if ! check_prerequisites; then
    log "ERROR" "Prerequisites check failed"
    exit 1
  fi
  
  # Deploy infrastructure or specific component
  if [ -n "$COMPONENT" ]; then
    # Deploy specific component
    if ! deploy_component "$COMPONENT" "$ENVIRONMENT" "$BRANCH"; then
      log "ERROR" "Component deployment failed"
      exit 1
    fi
  else
    # Deploy full infrastructure
    if ! deploy_full_infrastructure "$ENVIRONMENT"; then
      log "WARNING" "Infrastructure deployment had issues"
      # Continue anyway, as partial deployments might still work
    fi
  fi
  
  # Extract certificates from acme.json
  extract_certificates
  
  # Generate summary
  generate_summary
}

# Execute main function with all arguments
main "$@"
