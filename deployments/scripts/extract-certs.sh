#!/bin/bash
# Certificate extraction script for Ignis
# Extracts SSL certificates from acme.json for use by the webhook server

# Exit on any error
set -e

# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CERT_DIR="$PROJECT_ROOT/proxy/certs"
ACME_JSON="$PROJECT_ROOT/proxy/acme.json"
LOG_DIR="$PROJECT_ROOT/logs/certs"
LOG_FILE="$LOG_DIR/extract-$(date +%Y%m%d-%H%M%S).log"

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

# Add this new helper function above the main function:
process_certificate() {
  local cert64="$1"
  
  cert_json=$(echo "$cert64" | base64 -d)
  domain=$(echo "$cert_json" | jq -r '.domain.main')
  cert_pem=$(echo "$cert_json" | jq -r '.certificate' | base64 -d)
  key_pem=$(echo "$cert_json" | jq -r '.key' | base64 -d)
  
  if [ -z "$domain" ] || [ -z "$cert_pem" ] || [ -z "$key_pem" ] || [ "$domain" = "null" ]; then
    log "WARNING" "Skipping invalid or incomplete cert block"
    return
  fi
  
  CERT_PATH="$CERT_DIR/$domain.crt"
  KEY_PATH="$CERT_DIR/$domain.key"
  
  echo "$cert_pem" > "$CERT_PATH"
  echo "$key_pem" > "$KEY_PATH"
  
  # Set proper permissions
  chmod 644 "$CERT_PATH"
  chmod 600 "$KEY_PATH"
  
  log "SUCCESS" "Saved cert for $domain -> $CERT_PATH and $KEY_PATH"
}

# Main function
main() {
  log "INFO" "Starting certificate extraction"
  
  # Check if acme.json exists
  if [ ! -f "$ACME_JSON" ]; then
    log "ERROR" "acme.json file not found at $ACME_JSON"
    exit 1
  fi
  
  # Check if acme.json has proper permissions
  if [ "$(stat -c %a "$ACME_JSON")" != "600" ]; then
    log "WARNING" "acme.json has incorrect permissions. Setting to 600"
    chmod 600 "$ACME_JSON"
  fi
  
  # Create certificate directory if it doesn't exist
  mkdir -p "$CERT_DIR"
  
  # Create temporary directory
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  
  # Check if acme.json is empty or invalid
  if [ ! -s "$ACME_JSON" ] || ! jq empty "$ACME_JSON" 2>/dev/null; then
    log "WARNING" "acme.json is empty or invalid JSON"
    return 1
  fi
  
  log "INFO" "Parsing acme.json for certificates"
  
  # First, try to extract certificates using the original method
  jq -r '.[]?.Certificates?[]? | @base64' "$ACME_JSON" 2>/dev/null | while read -r cert64; do
    if [ -z "$cert64" ]; then
      continue
    fi
    
    process_certificate "$cert64"
  done
  
  # Check if any certificates were extracted
  if [ -z "$(ls -A "$CERT_DIR" 2>/dev/null)" ]; then
    log "WARNING" "No certificates extracted with primary method, trying alternative method"
    
    # Try alternative method for different JSON structure
    jq -r '.letsencrypt.Certificates[]? | @base64' "$ACME_JSON" 2>/dev/null | while read -r cert64; do
      if [ -z "$cert64" ]; then
        continue
      fi
      
      process_certificate "$cert64"
    done
  fi
  
  # Check if any certificates were extracted after both attempts
  if [ -z "$(ls -A "$CERT_DIR" 2>/dev/null)" ]; then
    log "WARNING" "No certificates were extracted from acme.json"
    log "INFO" "Dumping acme.json structure for debugging:"
    jq -r 'keys[]' "$ACME_JSON" 2>/dev/null | log "INFO" "Root keys: $(cat)"
    jq -r '.letsencrypt | keys[]' "$ACME_JSON" 2>/dev/null | log "INFO" "letsencrypt keys: $(cat)"
    return 1
  else
    log "SUCCESS" "Certificate extraction completed"
    return 0
  fi
}

# Execute main function
main
