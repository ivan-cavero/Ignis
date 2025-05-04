#!/bin/bash
# Bridge script for the webhook
# This script is called by the webhook and executes the deployment script on the host

# Configuration
LOG_DIR="/opt/ignis/logs/webhook-bridge"
LOG_FILE="$LOG_DIR/bridge-$(date +%Y%m%d-%H%M%S).log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Get arguments
COMPONENT="$1"
ENVIRONMENT="$2"
BRANCH="$3"

# Validate arguments
if [ -z "$COMPONENT" ] || [ -z "$ENVIRONMENT" ] || [ -z "$BRANCH" ]; then
  log "ERROR: Missing required arguments"
  log "Usage: $0 <component> <environment> <branch>"
  exit 1
fi

# Log start
log "Starting deployment of $COMPONENT in $ENVIRONMENT environment (branch: $BRANCH)"

# Execute the deployment script
cd /opt/ignis
log "Executing: bash deployments/scripts/deploy.sh --component=$COMPONENT --environment=$ENVIRONMENT --branch=$BRANCH"
bash deployments/scripts/deploy.sh --component="$COMPONENT" --environment="$ENVIRONMENT" --branch="$BRANCH" >> "$LOG_FILE" 2>&1

# Check result
if [ $? -eq 0 ]; then
  log "Deployment completed successfully"
  exit 0
else
  log "ERROR: Deployment failed"
  exit 1
fi
