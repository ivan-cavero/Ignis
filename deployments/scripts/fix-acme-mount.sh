#!/bin/bash
# Script to fix acme.json mount issues with Traefik
# This script properly removes and recreates the acme.json file
# and ensures Docker mounts it correctly

# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Log functions
log_info() {
  echo -e "${COLOR_INFO}[INFO] $1${COLOR_RESET}"
}

log_success() {
  echo -e "${COLOR_SUCCESS}[SUCCESS] $1${COLOR_RESET}"
}

log_warning() {
  echo -e "${COLOR_WARNING}[WARNING] $1${COLOR_RESET}"
}

log_error() {
  echo -e "${COLOR_ERROR}[ERROR] $1${COLOR_RESET}"
}

# Main function
main() {
  log_info "Starting acme.json mount fix"
  
  # Path to acme.json
  local acme_file="/opt/ignis/proxy/acme.json"
  
  # 1. Stop all containers that might be using the mount
  log_info "Stopping Traefik and related containers"
  docker stop traefik || true
  
  # 2. Check if acme.json exists and what type it is
  if [ -e "$acme_file" ]; then
    if [ -d "$acme_file" ]; then
      log_warning "acme.json is a directory, removing it"
      rm -rf "$acme_file"
    elif [ -f "$acme_file" ]; then
      log_info "acme.json is a file, removing it to recreate with proper permissions"
      rm -f "$acme_file"
    else
      log_warning "acme.json exists but is neither a file nor directory, removing"
      rm -rf "$acme_file"
    fi
  else
    log_info "acme.json does not exist, will create it"
  fi
  
  # 3. Create the acme.json file with proper permissions
  log_info "Creating acme.json file with proper permissions"
  touch "$acme_file"
  chmod 600 "$acme_file"
  
  # 4. Verify the file was created correctly
  if [ -f "$acme_file" ] && [ "$(stat -c %a "$acme_file")" = "600" ]; then
    log_success "acme.json created successfully with correct permissions"
  else
    log_error "Failed to create acme.json properly"
    exit 1
  fi
  
  # 5. Prune Docker system to clear any cached mounts
  log_info "Pruning Docker system to clear cached mounts"
  docker system prune -f
  
  # 6. Restart Docker service to clear all caches
  log_info "Restarting Docker service"
  sudo systemctl restart docker
  sleep 5
  
  # 7. Start Traefik container
  log_info "Starting Traefik container"
  cd /opt/ignis
  docker compose up -d traefik
  
  # 8. Check if Traefik started successfully
  sleep 5
  if docker ps | grep -q traefik; then
    log_success "Traefik container started successfully"
  else
    log_error "Failed to start Traefik container"
    docker logs traefik
    exit 1
  fi
  
  log_success "acme.json mount fix completed successfully"
}

# Run the main function
main "$@"
