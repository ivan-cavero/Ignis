#!/bin/bash

# === CONFIGURACION GENERAL ===
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs/deployments"
LOG_FILE="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"

ENVIRONMENT="production"
BRANCH="main"
COMPONENT=""
FORCE_REBUILD=false
EXTRACT_CERTS=true
LOG_TO_FILE=true

# === FUNCIONES DE LOG ===
log() {
  local level="$1"
  local message="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

command_exists() {
  command -v "$1" &> /dev/null
}

is_container_running() {
  docker ps -q -f name="$1" | grep -q .
}

# === FUNCIONES DE PREPARACION ===
initialize_log_file() {
  if [ "$LOG_TO_FILE" = true ]; then
    mkdir -p "$LOG_DIR"
    echo "=== IGNIS DEPLOYMENT LOG - $(date) ===" > "$LOG_FILE"
    log "INFO" "Logging to file: $LOG_FILE"
  fi
}

check_prerequisites() {
  log "INFO" "Checking prerequisites"
  local missing=()

  command_exists docker || missing+=("Docker")
  (command_exists docker-compose || docker compose version &> /dev/null) || missing+=("Docker Compose")
  [ -d "$PROJECT_ROOT" ] || missing+=("Project directory")
  [ -f "$PROJECT_ROOT/docker-compose.yml" ] || missing+=("docker-compose.yml")

  if [ ${#missing[@]} -gt 0 ]; then
    log "ERROR" "Missing: ${missing[*]}"
    return 1
  fi

  log "SUCCESS" "All prerequisites met"
  return 0
}

update_environment_variables() {
  local env="$1"
  log "INFO" "Updating .env"
  local env_file="$PROJECT_ROOT/.env"

  grep -q "WEBHOOK_SECRET=" "$env_file" 2>/dev/null || echo "WEBHOOK_SECRET=ignis_webhook_secret_$(date +%s | sha256sum | base64 | head -c 32)" >> "$env_file"

  if [ "$env" = "development" ]; then
    sed -i "s/ENVIRONMENT=.*/ENVIRONMENT=development/" "$env_file" 2>/dev/null || echo "ENVIRONMENT=development" >> "$env_file"
  else
    sed -i "s/ENVIRONMENT=.*/ENVIRONMENT=production/" "$env_file" 2>/dev/null || echo "ENVIRONMENT=production" >> "$env_file"
  fi
  log "SUCCESS" ".env updated"
}

extract_certificates() {
  [ "$EXTRACT_CERTS" != true ] && return 0
  local script="$PROJECT_ROOT/deployments/scripts/extract-certs.sh"
  [ -f "$script" ] && bash "$script"
}

register_systemd_services() {
  log "INFO" "Registering systemd services"
  local SERVICE_DIR="$PROJECT_ROOT/deployments/service"
  local SYSTEMD_DIR="/etc/systemd/system"
  local SERVICES=("ignis-startup.service" "ignis-webhook.service")
  local updated=false

  for s in "${SERVICES[@]}"; do
    local src="$SERVICE_DIR/$s"
    local dst="$SYSTEMD_DIR/$s"
    if [ ! -f "$src" ]; then
      log "WARNING" "$src not found"
      continue
    fi
    if ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      updated=true
      log "INFO" "Copied updated $s"
    fi
    systemctl enable "$s"
  done

  [ "$updated" = true ] && systemctl daemon-reexec
  log "SUCCESS" "Systemd services enabled"
}

# === DESPLIEGUES ===
deploy_full_infrastructure() {
  local env="$1"
  log "INFO" "Deploying full infrastructure for $env"

  cd "$PROJECT_ROOT"
  mkdir -p "$PROJECT_ROOT/proxy/certs" "$PROJECT_ROOT/logs/webhook" "$PROJECT_ROOT/logs/deployments"
  [ -f "$PROJECT_ROOT/proxy/acme.json" ] || { touch "$PROJECT_ROOT/proxy/acme.json" && chmod 600 "$PROJECT_ROOT/proxy/acme.json"; }

  update_environment_variables "$env"
  [ -d "$PROJECT_ROOT/.git" ] && git checkout "$BRANCH" && git pull origin "$BRANCH"

  local compose_file="docker-compose.yml"
  local env_file=""
  [ "$env" = "development" ] && env_file="docker-compose.development.yml" || env_file="docker-compose.production.yml"

  if [ "$FORCE_REBUILD" = true ]; then
    docker compose -f "$compose_file"${env_file:+ -f "$env_file"} down
    docker compose -f "$compose_file"${env_file:+ -f "$env_file"} up -d --build
  else
    docker compose -f "$compose_file"${env_file:+ -f "$env_file"} up -d
  fi

  register_systemd_services
  deploy_component "webhook" "$env" "$BRANCH"

  log "SUCCESS" "Full infrastructure deployed"
}

deploy_component() {
  local component="$1"; local env="$2"; local branch="$3"
  log "INFO" "Deploying component: $component"

  case "$component" in
    backend|admin-frontend|user-frontend|landing-frontend|proxy)
      docker compose up -d --build "$component"
      ;;
    webhook)
      [ -d "$PROJECT_ROOT/.git" ] && git checkout "$branch" && git pull origin "$branch"
      if command_exists bun && [ -f "$PROJECT_ROOT/deployments/webhook/server.ts" ]; then
        cd "$PROJECT_ROOT/deployments/webhook" && bun install
        systemctl daemon-reexec
        systemctl restart ignis-webhook.service
        systemctl status ignis-webhook.service --no-pager >> "$LOG_FILE"
        log "SUCCESS" "Webhook service restarted"
      else
        log "ERROR" "Cannot deploy webhook"
        return 1
      fi
      ;;
    infrastructure)
      deploy_full_infrastructure "$env"
      return $?
      ;;
    *)
      log "ERROR" "Unknown component: $component"
      return 1
      ;;
  esac
  return 0
}

generate_summary() {
  log "INFO" "Generating deployment summary"
  echo "--- Docker Status ---"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "ignis\|traefik"
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --component=*) COMPONENT="${1#*=}" ; shift ;;
      --environment=*) ENVIRONMENT="${1#*=}" ; shift ;;
      --branch=*) BRANCH="${1#*=}" ; shift ;;
      --force-rebuild) FORCE_REBUILD=true ; shift ;;
      --no-extract-certs) EXTRACT_CERTS=false ; shift ;;
      *) log "WARNING" "Unknown option: $1" ; shift ;;
    esac
  done
}

# === MAIN ===
main() {
  parse_arguments "$@"
  initialize_log_file
  check_prerequisites || exit 1

  if [ -n "$COMPONENT" ]; then
    deploy_component "$COMPONENT" "$ENVIRONMENT" "$BRANCH" || exit 1
  else
    deploy_full_infrastructure "$ENVIRONMENT" || log "WARNING" "Partial infra deploy"
  fi

  extract_certificates
  generate_summary
}

main "$@"
