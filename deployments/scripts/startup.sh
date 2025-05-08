#!/bin/bash
# Ignis Startup Script
# This script is executed at system boot to start the Ignis infrastructure
# 
# Author: v0
# Version: 3.0.0
# License: MIT

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/startup"
WEBHOOK_DIR="$PROJECT_ROOT/deployments/webhook"

# Create timestamp for log files
create_timestamp() {
  date +"%Y%m%d-%H%M%S"
}

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Log file with timestamp
TIMESTAMP=$(create_timestamp)
LOG_FILE="$LOG_DIR/startup-$TIMESTAMP.log"

# Log function
log() {
  local level="$1"
  local message="$2"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Start webhook server
start_webhook() {
  log "INFO" "Starting webhook server"
  
  # Check if webhook directory exists
  if [ ! -d "$WEBHOOK_DIR" ]; then
    log "ERROR" "Webhook directory not found: $WEBHOOK_DIR"
    return 1
  fi
  
  # Check if server.ts exists
  if [ ! -f "$WEBHOOK_DIR/server.ts" ]; then
    log "ERROR" "Webhook server file not found: $WEBHOOK_DIR/server.ts"
    return 1
  fi
  
  # Check if bun is installed
  if ! command -v bun &> /dev/null; then
    log "ERROR" "Bun is not installed or not in PATH"
    return 1
  fi
  
  # Kill any existing webhook processes to avoid duplicates
  pkill -f "bun run.*server.ts" || true
  sleep 1
  
  # Remove lock file if it exists
  rm -f /tmp/ignis-webhook.lock
  
  # Start webhook server in background
  cd "$WEBHOOK_DIR"
  
  # Set environment variables for the webhook server
  export WEBHOOK_HOST="0.0.0.0"
  export WEBHOOK_PORT="3333"
  
  # Start webhook server with nohup to keep it running after this script exits
  log "INFO" "Launching webhook server process"
  
  # Use full path to bun to avoid PATH issues
  nohup /usr/local/bin/bun run server.ts &
  
  # Store the PID
  WEBHOOK_PID=$!
  log "INFO" "Webhook server started with PID: $WEBHOOK_PID"
  
  # Check if webhook started successfully - wait a bit longer
  sleep 3
  if kill -0 $WEBHOOK_PID 2>/dev/null; then
    log "SUCCESS" "Webhook server started successfully"
    return 0
  else
    log "ERROR" "Failed to start webhook server"
    return 1
  fi
}

# Main function
main() {
  log "INFO" "Starting Ignis infrastructure at system boot"
  
  # Load environment variables
  if [ -f "$PROJECT_ROOT/.env" ]; then
    log "INFO" "Loading environment variables from .env file"
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
  else
    log "WARNING" "No .env file found at $PROJECT_ROOT/.env"
  fi
  
  # Wait for Docker to be fully started
  log "INFO" "Waiting for Docker to be ready"
  timeout 30 bash -c 'until docker info &>/dev/null; do sleep 1; done' || {
    log "WARNING" "Timeout waiting for Docker, continuing anyway"
  }
  
  # Start Docker infrastructure
  log "INFO" "Starting Docker infrastructure"
  cd "$PROJECT_ROOT"
  
  # Determine which compose file to use
  if [ "$ENVIRONMENT" = "development" ]; then
    COMPOSE_FILE="docker-compose.development.yml"
  else
    COMPOSE_FILE="docker-compose.yml"
  fi
  
  # Start Docker containers
  if [ -f "$COMPOSE_FILE" ]; then
    docker compose -f "$COMPOSE_FILE" up -d
    if [ $? -eq 0 ]; then
      log "SUCCESS" "Docker infrastructure started successfully"
    else
      log "ERROR" "Failed to start Docker infrastructure"
    fi
  else
    log "ERROR" "Docker compose file not found: $COMPOSE_FILE"
  fi
  
  # Start webhook server
  start_webhook
  
  # Extract SSL certificates if needed
  if [ -f "$PROJECT_ROOT/deployments/scripts/extract-certs.sh" ]; then
    log "INFO" "Extracting SSL certificates"
    bash "$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  fi
  
  log "SUCCESS" "Ignis infrastructure startup completed"
}

# Execute main function
main
