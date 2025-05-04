#!/bin/bash
# Ignis Component Deployment Script
# This script selectively deploys a specific component based on changes

# Exit on any error
set -e

# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Get the component to deploy from the first argument
COMPONENT="$1"
ENVIRONMENT="$2"
BRANCH="$3"

# Validate arguments
if [ -z "$COMPONENT" ] || [ -z "$ENVIRONMENT" ] || [ -z "$BRANCH" ]; then
  echo -e "${COLOR_ERROR}Error: Missing required arguments${COLOR_RESET}"
  echo "Usage: $0 <component> <environment> <branch>"
  echo "Example: $0 admin-frontend development dev"
  exit 1
fi

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/deployments"
LOG_FILE="$LOG_DIR/deploy-${COMPONENT}-$(date +%Y%m%d-%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Log function
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
  
  echo -e "${color}[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message${COLOR_RESET}" | tee -a "$LOG_FILE"
}

# Function to deploy a specific component
deploy_component() {
  local component="$1"
  local environment="$2"
  
  log "INFO" "Starting deployment of $component in $environment environment"
  
  # Navigate to project directory
  cd "$PROJECT_ROOT"
  
  # Pull latest changes from the specified branch
  log "INFO" "Pulling latest changes from $BRANCH branch"
  git checkout "$BRANCH" >> "$LOG_FILE" 2>&1
  git pull origin "$BRANCH" >> "$LOG_FILE" 2>&1
  
  # Deploy based on component type
  case "$component" in
    "backend")
      log "INFO" "Deploying backend"
      docker compose up -d --build backend >> "$LOG_FILE" 2>&1
      ;;
      
    "admin-frontend")
      log "INFO" "Deploying admin frontend"
      docker compose up -d --build admin-frontend >> "$LOG_FILE" 2>&1
      ;;
      
    "user-frontend")
      log "INFO" "Deploying user frontend"
      docker compose up -d --build user-frontend >> "$LOG_FILE" 2>&1
      ;;
      
    "landing-frontend")
      log "INFO" "Deploying landing frontend"
      docker compose up -d --build landing-frontend >> "$LOG_FILE" 2>&1
      ;;
      
    "proxy")
      log "INFO" "Deploying proxy configuration"
      docker compose up -d --build traefik >> "$LOG_FILE" 2>&1
      ;;
      
    "infrastructure")
      log "INFO" "Deploying full infrastructure"
      docker compose up -d --build >> "$LOG_FILE" 2>&1
      ;;
      
    *)
      log "ERROR" "Unknown component: $component"
      return 1
      ;;
  esac
  
  # Verify deployment
  if docker ps | grep -q "ignis-$component"; then
    log "SUCCESS" "$component deployed successfully in $environment environment"
    return 0
  else
    log "ERROR" "Failed to deploy $component"
    return 1
  fi
}

# Main function
main() {
  log "INFO" "Deployment process started for $COMPONENT in $ENVIRONMENT environment (branch: $BRANCH)"
  
  # Deploy the component
  if deploy_component "$COMPONENT" "$ENVIRONMENT"; then
    log "SUCCESS" "Deployment completed successfully"
    
    # Extract certificates if needed (for proxy component)
    if [ "$COMPONENT" = "proxy" ] || [ "$COMPONENT" = "infrastructure" ]; then
      log "INFO" "Extracting certificates"
      "$PROJECT_ROOT/deployments/scripts/extract-certs.sh" >> "$LOG_FILE" 2>&1
    fi
    
    exit 0
  else
    log "ERROR" "Deployment failed"
    exit 1
  fi
}

# Execute main function
main
