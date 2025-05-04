#!/bin/bash
# Ignis Startup Script
# This script is executed at system boot to start the Ignis infrastructure
# 
# Author: v0
# Version: 1.0.0
# License: MIT

# Exit on any error
set -e

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/startup"
LOG_FILE="$LOG_DIR/startup-$(date +%Y%m%d-%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Log function
log() {
  local level="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# Main function
main() {
  log "INFO" "Starting Ignis infrastructure at system boot"
  
  # Wait for Docker to be fully started
  log "INFO" "Waiting for Docker to be ready"
  timeout 10 bash -c 'until docker info &>/dev/null; do sleep 1; done'
  
  # Start Docker infrastructure
  log "INFO" "Starting Docker infrastructure"
  cd "$PROJECT_ROOT"
  docker compose up -d
  
  # Start webhook service
  log "INFO" "Starting webhook service"
  systemctl restart ignis-webhook.service
  
  log "SUCCESS" "Ignis infrastructure started successfully"
}

# Execute main function
main
