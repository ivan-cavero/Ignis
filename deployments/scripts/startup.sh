#!/bin/bash
# Ignis Startup Script
# Functional script executed at system boot to start the Ignis infrastructure
# 
# Author: v0
# Version: 3.0.0
# License: MIT

# === CONFIGURATION ===
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly LOG_DIR="$PROJECT_ROOT/logs/startup"
readonly WEBHOOK_DIR="$PROJECT_ROOT/deployments/webhook"
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Default settings (can be overridden by command line arguments)
START_DOCKER=true
START_WEBHOOK=true
EXTRACT_CERTS=true
VERIFY_DOCKER_HOST=true
WAIT_FOR_NETWORK=true
VERBOSE=false
SKIP_LOGS=false

# === HELPER FUNCTIONS ===

# Pure function to create a timestamp for file names
create_timestamp() {
  date +"%Y%m%d-%H%M%S"
}

# Pure function to print a formatted message
print_message() {
  local color="$1"
  local level="$2"
  local message="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  
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

# Pure function to show help message
show_help() {
  cat << EOF
Ignis Startup Script

USAGE:
  ./startup.sh [OPTIONS]

OPTIONS:
  --no-docker           Don't start Docker containers
  --no-webhook          Don't start webhook server
  --no-extract-certs    Don't extract SSL certificates
  --no-verify-host      Skip Docker-to-host communication verification
  --no-wait-network     Don't wait for network to be ready
  --verbose             Show verbose output
  --skip-logs           Minimize console output
  --help                Show this help message

EXAMPLES:
  # Start everything
  ./startup.sh
  
  # Start only webhook server
  ./startup.sh --no-docker
  
  # Start only Docker containers
  ./startup.sh --no-webhook
EOF
}

# Pure function to parse arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --no-docker)
        START_DOCKER=false
        shift
        ;;
      --no-webhook)
        START_WEBHOOK=false
        shift
        ;;
      --no-extract-certs)
        EXTRACT_CERTS=false
        shift
        ;;
      --no-verify-host)
        VERIFY_DOCKER_HOST=false
        shift
        ;;
      --no-wait-network)
        WAIT_FOR_NETWORK=false
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --skip-logs)
        SKIP_LOGS=true
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
}

# Start webhook server
start_webhook() {
  if [ "$START_WEBHOOK" != true ]; then
    log_info "Skipping webhook server startup (--no-webhook flag provided)"
    return 0
  fi
  
  log_info "Starting webhook server"
  
  # Check if webhook directory exists
  if ! dir_exists "$WEBHOOK_DIR"; then
    log_error "Webhook directory not found: $WEBHOOK_DIR"
    return 1
  fi
  
  # Check if server.ts exists
  if ! file_exists "$WEBHOOK_DIR/server.ts"; then
    log_error "Webhook server file not found: $WEBHOOK_DIR/server.ts"
    return 1
  fi
  
  # Check if bun is installed
  if ! command_exists bun; then
    log_error "Bun is not installed or not in PATH"
    return 1
  fi
  
  # Kill any existing webhook processes to avoid duplicates
  pkill -f "bun run.*server.ts" || true
  sleep 1
  
  # Remove lock file if it exists
  if file_exists "/tmp/ignis-webhook.lock"; then
    rm -f "/tmp/ignis-webhook.lock"
  fi
  
  # Start webhook server in background
  cd "$WEBHOOK_DIR"
  
  # Set environment variables for the webhook server
  export WEBHOOK_HOST="0.0.0.0"  # Listen on all interfaces
  export WEBHOOK_PORT="3333"
  
  # Start webhook server with nohup to keep it running after this script exits
  log_info "Launching webhook server process"
  
  # Use full path to bun to avoid PATH issues
  nohup /usr/local/bin/bun run server.ts &
  
  # Store the PID
  WEBHOOK_PID=$!
  log_info "Webhook server started with PID: $WEBHOOK_PID"
  
  # Check if webhook started successfully - wait a bit longer
  sleep 3
  if kill -0 $WEBHOOK_PID 2>/dev/null; then
    log_success "Webhook server started successfully"
    
    # Verify that the server is listening
    if ss -tlnp | grep -q "0.0.0.0:3333"; then
      log_success "Webhook server is listening on all interfaces"
    else
      log_warning "Webhook server may not be listening on all interfaces"
    fi
    
    # Verify that the server responds to health checks
    if curl -s http://localhost:3333/health > /dev/null; then
      log_success "Webhook server is responding to health checks"
      
      if [ "$VERBOSE" = true ]; then
        log_info "Health check response: $(curl -s http://localhost:3333/health)"
      fi
    else
      log_warning "Webhook server is not responding to health checks"
    fi
    
    return 0
  else
    log_error "Failed to start webhook server"
    return 1
  fi
}

# Start Docker infrastructure
start_docker() {
  if [ "$START_DOCKER" != true ]; then
    log_info "Skipping Docker infrastructure startup (--no-docker flag provided)"
    return 0
  fi
  
  log_info "Starting Docker infrastructure"
  
  # Determine which compose file to use
  local compose_file="docker-compose.yml"
  
  if [ "$ENVIRONMENT" = "development" ]; then
    compose_file="docker-compose.development.yml"
  fi
  
  # Start Docker containers
  if file_exists "$PROJECT_ROOT/$compose_file"; then
    cd "$PROJECT_ROOT"
    docker compose -f "$compose_file" up -d
    
    if [ $? -eq 0 ]; then
      log_success "Docker infrastructure started successfully"
    else
      log_error "Failed to start Docker infrastructure"
      return 1
    fi
  else
    log_error "Docker compose file not found: $compose_file"
    return 1
  fi
  
  return 0
}

# Extract SSL certificates
extract_certificates() {
  if [ "$EXTRACT_CERTS" != true ]; then
    return 0
  fi
  
  local script="$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  if file_exists "$script"; then
    log_info "Extracting SSL certificates"
    bash "$script"
  fi
}

# Test connection from Traefik to webhook
test_traefik_connection() {
  if [ "$START_DOCKER" != true ] || [ "$START_WEBHOOK" != true ]; then
    return 0
  fi
  
  log_info "Testing connection from Traefik to webhook"
  
  # Wait for Traefik to be fully started
  sleep 5
  
  if docker exec traefik curl -s http://host.docker.internal:3333/health --connect-timeout 5 > /dev/null 2>&1; then
    log_success "Traefik can connect to webhook server using host.docker.internal"
  else
    log_warning "Traefik cannot connect to webhook server using host.docker.internal"
    
    # Try with direct IP
    if docker exec traefik curl -s http://172.17.0.1:3333/health --connect-timeout 5 > /dev/null 2>&1; then
      log_success "Traefik can connect to webhook server using direct IP"
      
      # Update webhook.yml to use direct IP
      local webhook_config="$PROJECT_ROOT/proxy/dynamic/webhook.yml"
      if file_exists "$webhook_config"; then
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

# Wait for Traefik to generate certificates
wait_for_certificates() {
  if [ "$START_DOCKER" != true ]; then
    return 0
  fi
  
  log_info "Waiting for Traefik to generate certificates..."
  
  # Check if acme.json exists and has content
  local acme_file="$PROJECT_ROOT/proxy/acme.json"
  
  if ! file_exists "$acme_file"; then
    log_error "acme.json file not found at $acme_file"
    return 1
  fi
  
  # Check if file is empty
  if [ ! -s "$acme_file" ]; then
    log_info "acme.json is empty, waiting for Traefik to generate certificates..."
    
    # Wait for up to 2 minutes for certificates to be generated
    local timeout=120
    local start_time=$(date +%s)
    local current_time
    
    while true; do
      current_time=$(date +%s)
      if [ $((current_time - start_time)) -gt $timeout ]; then
        log_warning "Timeout waiting for certificates. This is normal for the first run."
        log_info "Certificates will be generated when the first HTTPS request is received."
        break
      fi
      
      if [ -s "$acme_file" ]; then
        log_success "Certificates have been generated by Traefik"
        break
      fi
      
      log_info "Still waiting for certificates... ($(($timeout - (current_time - start_time))) seconds remaining)"
      sleep 10
    done
  else
    log_success "acme.json already contains certificate data"
  fi
}

# Generate startup summary
generate_summary() {
  log_info "Startup summary"
  
  echo "--- Docker Status ---"
  if [ "$START_DOCKER" = true ]; then
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "ignis\|traefik"
  else
    echo "Docker containers not started (--no-docker flag provided)"
  fi
  
  echo "--- Webhook Status ---"
  if [ "$START_WEBHOOK" = true ]; then
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
  else
    echo "Webhook server not started (--no-webhook flag provided)"
  fi
  
  # Show Docker-to-host communication status if verbose
  if [ "$VERBOSE" = true ] && [ "$START_DOCKER" = true ] && [ "$START_WEBHOOK" = true ]; then
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
    rm -rf "$acme_file"
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

# === MAIN FUNCTION ===

main() {
  # Parse arguments
  parse_arguments "$@"
  
  # Create logs directory if it doesn't exist
  mkdir -p "$LOG_DIR"
  
  # Log file with timestamp
  local timestamp=$(create_timestamp)
  local log_file="$LOG_DIR/startup-$timestamp.log"
  
  # Redirect output to log file if not skipping logs
  if [ "$SKIP_LOGS" = false ]; then
    exec > >(tee -a "$log_file") 2>&1
  fi
  
  log_info "Starting Ignis infrastructure at system boot"
  
  # Load environment variables
  if file_exists "$PROJECT_ROOT/.env"; then
    log_info "Loading environment variables from .env file"
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
  else
    log_warning "No .env file found at $PROJECT_ROOT/.env"
  fi
  
  # Wait for network to be ready if requested
  if [ "$WAIT_FOR_NETWORK" = true ]; then
    log_info "Waiting for network to be ready"
    timeout 30 bash -c 'until ping -c1 google.com &>/dev/null; do sleep 1; done' || {
      log_warning "Timeout waiting for network, continuing anyway"
    }
  fi
  
  # Wait for Docker to be fully started if starting Docker
  if [ "$START_DOCKER" = true ]; then
    log_info "Waiting for Docker to be ready"
    timeout 30 bash -c 'until docker info &>/dev/null; do sleep 1; done' || {
      log_warning "Timeout waiting for Docker, continuing anyway"
    }
  fi
  
  # Verify Docker-to-host communication
  verify_docker_host_communication
  
  # Check and fix acme.json file
  check_acme_file
  
  # Start Docker infrastructure
  start_docker
  
  # Start webhook server
  start_webhook
  
  # Extract SSL certificates if needed
  extract_certificates
  
  # Test connection from Traefik to webhook
  test_traefik_connection
  
  # Wait for certificates to be generated
  wait_for_certificates
  
  # Generate summary
  generate_summary
  
  log_success "Ignis infrastructure startup completed"
  
  if [ "$SKIP_LOGS" = false ]; then
    echo "Log file: $log_file"
  fi
}

# Execute main function with all arguments
main "$@"
