#!/bin/bash
# Ignis System Initialization Script
# This script sets up the Ignis ERP system with all required dependencies
# and security configurations.
# 
# Author: v0
# Version: 4.0.0
# License: MIT

# Fail fast on errors
set -e

# ==================== CONFIGURATION ====================
# Colors for output
readonly COLOR_RESET="\033[0m"
readonly COLOR_INFO="\033[1;36m"    # Cyan
readonly COLOR_SUCCESS="\033[1;32m" # Green
readonly COLOR_WARNING="\033[1;33m" # Yellow
readonly COLOR_ERROR="\033[1;31m"   # Red
readonly COLOR_TITLE="\033[1;35m"   # Magenta

# Default settings (can be overridden by command line arguments)
SSH_PORT=49622                                      # Secure non-standard port
INSTALLATION_DIR="/opt/ignis"                       # Default installation directory
GIT_REPO="https://github.com/ivan-cavero/Ignis.git" # Git repository URL
GIT_BRANCH="main"                                   # Default branch
SETUP_USER="ignis"                                  # Default system user
LOG_FILE="ignis-setup.log"                          # Log file name
VERBOSITY=1                                         # Default verbosity level (0=quiet, 1=normal, 2=verbose)
DRY_RUN=false                                       # Dry run mode
UNINSTALL=false                                     # Uninstall mode
CACHE_DIR="/var/cache/ignis-setup"                  # Cache directory for downloads

# Port configurations - format: "port/protocol|comment"
readonly ALLOWED_PORTS=(
  "$SSH_PORT/tcp|SSH"
  "3333/tcp|Ignis Webhook"
  "80/tcp|HTTP"
  "443/tcp|HTTPS"
)

# Feature flags (can be overridden by command line arguments)
SETUP_SSH=true                                              # Configure SSH security
SETUP_DOCKER=true                                           # Install Docker
SETUP_JAVA=true                                             # Install Java
SETUP_FAIL2BAN=true                                         # Configure Fail2Ban
CLONE_REPO=true                                             # Clone Git repository
UPDATE_SYSTEM=true                                          # Update system packages
ALLOW_PASSWORD_AUTH=true                                    # Allow password authentication
ALLOW_TCP_FORWARDING=true                                   # Allow TCP forwarding for remote development
USE_IPTABLES=false                                          # Use iptables instead of ufw
LOG_TO_FILE=false                                           # Write logs to file
INSTALL_SERVICES=true                                       # Install systemd services
START_SERVICES=true                                         # Start services after installation
PARALLEL_INSTALL=true                                       # Install packages in parallel when possible

# Required packages by category
readonly SYSTEM_PACKAGES="curl ca-certificates gnupg unzip git software-properties-common jq"
readonly SECURITY_PACKAGES="ufw fail2ban"
readonly JAVA_PACKAGES="openjdk-17-jre-headless"

# ==================== UTILITY FUNCTIONS ====================

# Set up cleanup trap for graceful exit
cleanup() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    print_error "Script execution failed with exit code $exit_code"
    print_message "$COLOR_INFO" "Check the log file for details: $LOG_FILE"
  fi
  
  # Remove temporary files
  if [ -d "/tmp/ignis-setup-$$" ]; then
    rm -rf "/tmp/ignis-setup-$$"
  fi
  
  exit $exit_code
}

# Set up trap for cleanup on exit
trap cleanup EXIT INT TERM

# Set up trap for error handling
error_handler() {
  local line=$1
  local command=$2
  local code=$3
  print_error "Command '$command' failed with exit code $code at line $line"
  
  # Provide helpful context based on where the error occurred
  case $line in
    *update_system*)
      print_message "$COLOR_INFO" "System update failed. Try manually with: sudo apt update && sudo apt upgrade -y"
      ;;
    *install_docker*)
      print_message "$COLOR_INFO" "Docker installation failed. Check https://docs.docker.com/engine/install/ for manual installation"
      ;;
    *configure_firewall*)
      print_message "$COLOR_INFO" "Firewall configuration failed. Make sure ufw or iptables is installed"
      ;;
    *)
      print_message "$COLOR_INFO" "Check system requirements and try again"
      ;;
  esac
}

trap 'error_handler ${LINENO} "${BASH_COMMAND}" $?' ERR

# Set appropriate umask for security
umask 027

# Pure function to log a message to file if enabled
log_to_file() {
  local level=$1
  local message=$2
  
  if [ "$LOG_TO_FILE" = true ] && [ $VERBOSITY -ge $level ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $message" >> "$LOG_FILE"
  fi
}

# Pure function to print a formatted message
print_message() {
  local color="$1"
  local message="$2"
  local level=${3:-1}  # Default level is 1
  
  if [ $VERBOSITY -ge $level ]; then
    echo -e "${color}${message}${COLOR_RESET}"
  fi
  
  log_to_file $level "$message"
}

# Pure function to print a section header
print_section() {
  local number="$1"
  local total="$2"
  local title="$3"
  print_message "$COLOR_INFO" "[$number/$total] $title"
}

# Pure function to print a success message
print_success() {
  local message="$1"
  local level=${2:-1}  # Default level is 1
  print_message "$COLOR_SUCCESS" "✅ $message" $level
}

# Pure function to print a warning message
print_warning() {
  local message="$1"
  local level=${2:-1}  # Default level is 1
  print_message "$COLOR_WARNING" "⚠️ $message" $level
}

# Pure function to print an error message
print_error() {
  local message="$1"
  local level=${2:-0}  # Default level is 0 (always show errors)
  print_message "$COLOR_ERROR" "❌ $message" $level
}

# Pure function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Pure function to check if a service is active
is_service_active() {
  systemctl is-active --quiet "$1"
}

# Pure function to check if a file exists
file_exists() {
  [ -f "$1" ]
}

# Pure function to check if a directory exists
dir_exists() {
  [ -d "$1" ]
}

# Pure function to check if a user exists
user_exists() {
  id -u "$1" >/dev/null 2>&1
}

# Pure function to check if a port is in use
is_port_in_use() {
  ss -tuln | grep -q ":$1 "
}

# Pure function to check if a docker container is running
is_container_running() {
  docker ps --format "{{.Names}}" | grep -q "^$1$"
}

# Pure function to execute a command in dry run mode
execute_cmd() {
  local cmd="$1"
  local description="$2"
  local level=${3:-2}  # Default verbosity level for commands is 2
  
  if [ $VERBOSITY -ge $level ]; then
    print_message "$COLOR_INFO" "Executing: $cmd" $level
  fi
  
  if [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "[DRY RUN] Would execute: $cmd" 1
    return 0
  else
    log_to_file 2 "Executing: $cmd"
    eval "$cmd"
    local status=$?
    log_to_file 2 "Command exited with status: $status"
    return $status
  fi
}

# Pure function to validate URL accessibility
validate_url() {
  local url="$1"
  local timeout=${2:-5}
  
  if [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "[DRY RUN] Would validate URL: $url" 2
    return 0
  fi
  
  if curl --output /dev/null --silent --head --fail --max-time $timeout "$url"; then
    return 0
  else
    return 1
  fi
}

# Pure function to check available disk space
check_disk_space() {
  local required_mb="$1"
  local path="$2"
  
  # Get available space in MB
  local available_mb
  available_mb=$(df -m "$path" | awk 'NR==2 {print $4}')
  
  if [ "$available_mb" -lt "$required_mb" ]; then
    return 1
  else
    return 0
  fi
}

# Function to parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-port=*)
        SSH_PORT="${1#*=}"
        ;;
      --dir=*)
        INSTALLATION_DIR="${1#*=}"
        ;;
      --repo=*)
        GIT_REPO="${1#*=}"
        ;;
      --branch=*)
        GIT_BRANCH="${1#*=}"
        ;;
      --user=*)
        SETUP_USER="${1#*=}"
        ;;
      --log-file=*)
        LOG_FILE="${1#*=}"
        ;;
      --no-ssh)
        SETUP_SSH=false
        ;;
      --no-docker)
        SETUP_DOCKER=false
        ;;
      --no-java)
        SETUP_JAVA=false
        ;;
      --no-clone)
        CLONE_REPO=false
        ;;
      --no-update)
        UPDATE_SYSTEM=false
        ;;
      --no-password-auth)
        ALLOW_PASSWORD_AUTH=false
        ;;
      --no-fail2ban)
        SETUP_FAIL2BAN=false
        ;;
      --no-tcp-forwarding)
        ALLOW_TCP_FORWARDING=false
        ;;
      --use-iptables)
        USE_IPTABLES=true
        ;;
      --log-to-file)
        LOG_TO_FILE=true
        ;;
      --no-install-services)
        INSTALL_SERVICES=false
        ;;
      --no-start-services)
        START_SERVICES=false
        ;;
      --dry-run)
        DRY_RUN=true
        print_message "$COLOR_INFO" "Running in DRY RUN mode - no changes will be made"
        ;;
      --uninstall)
        UNINSTALL=true
        print_message "$COLOR_INFO" "Running in UNINSTALL mode"
        ;;
      --verbose)
        VERBOSITY=2
        print_message "$COLOR_INFO" "Verbose mode enabled"
        ;;
      --quiet)
        VERBOSITY=0
        ;;
      --no-parallel)
        PARALLEL_INSTALL=false
        ;;
      --cache-dir=*)
        CACHE_DIR="${1#*=}"
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        print_error "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
}

# Function to show help
show_help() {
  cat << EOF
Ignis System Initialization Script

Usage: $0 [options]

Options:
--ssh-port=PORT       Set custom SSH port (default: 49622)
--dir=PATH            Set installation directory (default: /opt/ignis)
--repo=URL            Set Git repository URL
--branch=BRANCH       Set Git branch (default: main)
--user=USERNAME       Set system user (default: ignis)
--log-file=FILE       Set log file name (default: ignis-setup.log)
--no-ssh              Skip SSH security configuration
--no-docker           Skip Docker installation
--no-java             Skip Java installation
--no-clone            Skip Git repository cloning
--no-update           Skip system package updates
--no-password-auth    Disable password authentication for SSH (default: enabled)
--no-fail2ban         Skip Fail2Ban installation and configuration
--no-tcp-forwarding   Disable TCP forwarding (will break VS Code Remote)
--use-iptables        Use iptables instead of ufw for firewall
--log-to-file         Write logs to file
--no-install-services Skip installation of systemd services
--no-start-services   Skip starting services after installation
--dry-run             Show what would be done without making changes
--uninstall           Remove Ignis installation
--verbose             Show more detailed output
--quiet               Show minimal output
--no-parallel         Disable parallel installation of packages
--cache-dir=DIR       Set cache directory for downloads (default: /var/cache/ignis-setup)
--help                Show this help message

Example:
$0 --ssh-port=2222 --dir=/home/ignis/Ignis --no-ssh --log-to-file
EOF
}

# Initialize log file if logging is enabled
initialize_log_file() {
  if [ "$LOG_TO_FILE" = true ]; then
    echo "=== IGNIS SYSTEM INITIALIZATION LOG - $(date) ===" > "$LOG_FILE"
    echo "Command: $0 $*" >> "$LOG_FILE"
    echo "System: $(uname -a)" >> "$LOG_FILE"
    echo "Distribution: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')" >> "$LOG_FILE"
    echo "=== CONFIGURATION ===" >> "$LOG_FILE"
    echo "SSH_PORT=$SSH_PORT" >> "$LOG_FILE"
    echo "INSTALLATION_DIR=$INSTALLATION_DIR" >> "$LOG_FILE"
    echo "GIT_REPO=$GIT_REPO" >> "$LOG_FILE"
    echo "GIT_BRANCH=$GIT_BRANCH" >> "$LOG_FILE"
    echo "SETUP_USER=$SETUP_USER" >> "$LOG_FILE"
    echo "DRY_RUN=$DRY_RUN" >> "$LOG_FILE"
    echo "UNINSTALL=$UNINSTALL" >> "$LOG_FILE"
    echo "VERBOSITY=$VERBOSITY" >> "$LOG_FILE"
    echo "===================" >> "$LOG_FILE"
    
    print_message "$COLOR_INFO" "Logging to file: $LOG_FILE"
  fi
}

# ==================== VALIDATION FUNCTIONS ====================

# Validate system requirements
validate_system_requirements() {
  print_section "1" "15" "Validating system requirements"
  
  # Check OS
  if [ ! -f /etc/os-release ]; then
    print_error "Unsupported operating system: /etc/os-release not found"
    exit 1
  fi
  
  # Check if running on Debian-based system
  if ! grep -q "ID=debian\|ID=ubuntu\|ID_LIKE=debian" /etc/os-release; then
    print_warning "This script is designed for Debian-based systems. Your system may not be fully compatible."
  fi
  
  # Check if running as root or with sudo privileges
  if [ "$(id -u)" -ne 0 ]; then
    if ! sudo -v >/dev/null 2>&1; then
      print_error "This script requires root privileges or sudo access"
      exit 1
    fi
  fi
  
  # Check Bash version
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    print_error "Bash version 4.0 or higher is required. You have ${BASH_VERSION}"
    exit 1
  fi
  
  # Check disk space (need at least 2GB free)
  if ! check_disk_space 2048 "/"; then
    print_error "Insufficient disk space. At least 2GB free space is required."
    exit 1
  fi
  
  # Check if required commands are available
  local missing_commands=()
  for cmd in curl grep awk sed; do
    if ! command_exists "$cmd"; then
      missing_commands+=("$cmd")
    fi
  done
  
  if [ ${#missing_commands[@]} -gt 0 ]; then
    print_error "Required commands not found: ${missing_commands[*]}"
    print_error "Please install these commands and try again"
    exit 1
  fi
  
  # Validate repository URL if cloning is enabled
  if [ "$CLONE_REPO" = true ]; then
    print_message "$COLOR_INFO" "Validating repository URL..." 2
    if ! validate_url "$GIT_REPO"; then
      print_error "Repository URL is not accessible: $GIT_REPO"
      print_message "$COLOR_INFO" "Check your internet connection or repository URL" 1
      exit 1
    fi
  fi
  
  print_success "System requirements validated"
}

# ==================== INSTALLATION FUNCTIONS ====================

# Update system packages
update_system() {
  print_section "2" "15" "Updating system packages"

  if [ "$UPDATE_SYSTEM" = true ]; then
    print_message "$COLOR_INFO" "Updating package lists..."
    execute_cmd "sudo apt update -y"
    
    print_message "$COLOR_INFO" "Upgrading packages..."
    execute_cmd "sudo apt upgrade -y"
    
    print_success "System packages updated"
  else
    print_message "$COLOR_INFO" "Skipping system update (--no-update flag provided)"
  fi
}

# Install required packages
install_base_packages() {
  print_section "3" "15" "Installing base packages"

  print_message "$COLOR_INFO" "Installing system packages..."
  
  # Create cache directory if it doesn't exist
  if [ ! -d "$CACHE_DIR" ] && [ "$DRY_RUN" = false ]; then
    execute_cmd "sudo mkdir -p $CACHE_DIR"
  fi
  
  # Install all system packages at once
  execute_cmd "sudo apt update -y"
  
  if [ "$PARALLEL_INSTALL" = true ]; then
    # Install packages in parallel
    local packages=($SYSTEM_PACKAGES)
    local install_commands=()
    
    for pkg in "${packages[@]}"; do
      install_commands+=("sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR $pkg")
    done
    
    if [ "$DRY_RUN" = false ]; then
      print_message "$COLOR_INFO" "Installing packages in parallel..." 2
      # Use GNU Parallel if available, otherwise fall back to sequential installation
      if command_exists parallel; then
        printf "%s\n" "${install_commands[@]}" | parallel -j$(nproc) || {
          print_warning "Parallel installation failed, falling back to sequential installation"
          execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR $SYSTEM_PACKAGES"
        }
      else
        execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR $SYSTEM_PACKAGES"
      fi
    else
      print_message "$COLOR_INFO" "[DRY RUN] Would install packages: $SYSTEM_PACKAGES" 1
    fi
  else
    # Install packages sequentially
    execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR $SYSTEM_PACKAGES"
  fi
  
  # Verify critical commands
  if [ "$DRY_RUN" = false ]; then
    local missing_commands=()
    for cmd in curl git jq; do
      if ! command_exists "$cmd"; then
        missing_commands+=("$cmd")
      fi
    done
    
    if [ ${#missing_commands[@]} -gt 0 ]; then
      print_error "Required commands not found: ${missing_commands[*]}"
      print_error "Installation failed. Please check your system configuration."
      exit 1
    fi
  fi
  
  print_success "All required packages installed and verified"
}

# Create system user
create_system_user() {
  print_section "4" "15" "Setting up system user"

  local user_created=false

  if ! user_exists "$SETUP_USER"; then
    print_message "$COLOR_INFO" "Creating user $SETUP_USER..."
    execute_cmd "sudo useradd -m -s /bin/bash $SETUP_USER"
    
    # Add user to sudo group
    execute_cmd "sudo usermod -aG sudo $SETUP_USER"
    
    # Set a password for the user if password authentication is enabled
    if [ "$ALLOW_PASSWORD_AUTH" = true ]; then
      print_message "$COLOR_INFO" "Setting password for $SETUP_USER..."
      # Generate a secure random password if not in dry run mode
      if [ "$DRY_RUN" = false ]; then
        local password
        password=$(openssl rand -base64 12)
        echo "$SETUP_USER:$password" | sudo chpasswd
        print_warning "Generated password for $SETUP_USER: $password"
        print_warning "Please change this password immediately after login."
      else
        print_message "$COLOR_INFO" "[DRY RUN] Would set a random password for $SETUP_USER" 1
      fi
    fi
    
    user_created=true
    print_success "User $SETUP_USER created"
    
    # Set up SSH directory for the new user
    if [ ! -d "/home/$SETUP_USER/.ssh" ] || [ "$DRY_RUN" = true ]; then
      execute_cmd "sudo mkdir -p /home/$SETUP_USER/.ssh"
      execute_cmd "sudo chmod 700 /home/$SETUP_USER/.ssh"
      execute_cmd "sudo touch /home/$SETUP_USER/.ssh/authorized_keys"
      execute_cmd "sudo chmod 600 /home/$SETUP_USER/.ssh/authorized_keys"
      execute_cmd "sudo chown -R $SETUP_USER:$SETUP_USER /home/$SETUP_USER/.ssh"
    fi
    
    if [ "$ALLOW_PASSWORD_AUTH" = false ]; then
      print_warning "Remember to add your SSH public key to /home/$SETUP_USER/.ssh/authorized_keys"
    fi
  else
    print_success "User $SETUP_USER already exists"
  fi

  # Export the user_created variable for later use
  export USER_CREATED=$user_created
}

# Install NVM and Node.js
install_node() {
  print_section "5" "15" "Installing NVM and Node.js LTS"

  # Determine the correct home directory
  local USER_HOME
  if [ "$(whoami)" = "$SETUP_USER" ]; then
    USER_HOME="$HOME"
  else
    USER_HOME="/home/$SETUP_USER"
  fi

  if [ ! -d "$USER_HOME/.nvm" ] || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Installing NVM..."
    
    # If running as the target user
    if [ "$(whoami)" = "$SETUP_USER" ]; then
      execute_cmd "curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash"
    else
      # Running as another user (likely root), so use sudo to install for the target user
      execute_cmd "sudo -u $SETUP_USER bash -c 'curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash'"
    fi
  else
    print_success "NVM is already installed"
  fi

  # Load NVM and install Node.js
  if [ "$DRY_RUN" = false ]; then
    if [ "$(whoami)" = "$SETUP_USER" ]; then
      # Running as the target user
      export NVM_DIR="$USER_HOME/.nvm"
      [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
      
      if ! command_exists node; then
        print_message "$COLOR_INFO" "Installing Node.js LTS..."
        execute_cmd "nvm install --lts"
        execute_cmd "nvm use --lts"
        execute_cmd "nvm alias default lts/*"
      else
        print_success "Node.js is already installed: $(node -v)"
      fi
    else
      # Running as another user, use sudo to run commands as the target user
      print_message "$COLOR_INFO" "Installing Node.js LTS for user $SETUP_USER..."
      execute_cmd "sudo -u $SETUP_USER bash -c \"export NVM_DIR='$USER_HOME/.nvm' && [ -s '\$NVM_DIR/nvm.sh' ] && . '\$NVM_DIR/nvm.sh' && nvm install --lts && nvm use --lts && nvm alias default lts/*\""
    fi
  else
    print_message "$COLOR_INFO" "[DRY RUN] Would install Node.js LTS" 1
  fi

  # Create global symlinks for node and npm
  if [ -d "$USER_HOME/.nvm/versions/node" ] || [ "$DRY_RUN" = true ]; then
    if [ "$DRY_RUN" = false ]; then
      NODE_VERSION=$(ls -1 "$USER_HOME/.nvm/versions/node" | grep -v "versions" | sort -V | tail -n 1)
      if [ -n "$NODE_VERSION" ]; then
        execute_cmd "sudo ln -sf $USER_HOME/.nvm/versions/node/$NODE_VERSION/bin/node /usr/local/bin/node"
        execute_cmd "sudo ln -sf $USER_HOME/.nvm/versions/node/$NODE_VERSION/bin/npm /usr/local/bin/npm"
      fi
    else
      print_message "$COLOR_INFO" "[DRY RUN] Would create Node.js symlinks" 1
    fi
    print_success "Node.js symlinks created"
  fi
}

# Install Bun
install_bun() {
  print_section "6" "15" "Installing Bun"

  # Determine the correct home directory
  local USER_HOME
  if [ "$(whoami)" = "$SETUP_USER" ]; then
    USER_HOME="$HOME"
  else
    USER_HOME="/home/$SETUP_USER"
  fi

  if ! command_exists bun || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Installing Bun..."
    
    if [ "$(whoami)" = "$SETUP_USER" ] && [ "$DRY_RUN" = false ]; then
      # Running as the target user
      execute_cmd "curl -fsSL https://bun.sh/install | bash"
    elif [ "$DRY_RUN" = false ]; then
      # Running as another user, use sudo to run commands as the target user
      execute_cmd "sudo -u $SETUP_USER bash -c 'curl -fsSL https://bun.sh/install | bash'"
    else
      print_message "$COLOR_INFO" "[DRY RUN] Would install Bun" 1
    fi
    
    # Create global symlink for bun
    print_message "$COLOR_INFO" "Creating global symlink for Bun..."
    execute_cmd "sudo ln -sf $USER_HOME/.bun/bin/bun /usr/local/bin/bun"
  else
    print_success "Bun is already installed: $(bun --version)"
    
    # Check if symlink exists and points to the correct location
    if [ -L "/usr/local/bin/bun" ] && [ "$DRY_RUN" = false ]; then
      LINK_TARGET=$(readlink -f /usr/local/bin/bun)
      if [ "$LINK_TARGET" != "$USER_HOME/.bun/bin/bun" ]; then
        print_message "$COLOR_INFO" "Updating Bun symlink..."
        execute_cmd "sudo rm -f /usr/local/bin/bun"
        execute_cmd "sudo ln -sf $USER_HOME/.bun/bin/bun /usr/local/bin/bun"
      fi
    else
      print_message "$COLOR_INFO" "Creating global symlink for Bun..."
      execute_cmd "sudo ln -sf $USER_HOME/.bun/bin/bun /usr/local/bin/bun"
    fi
  fi

  # Verify Bun installation
  if command_exists bun || [ "$DRY_RUN" = true ]; then
    print_success "Bun installation verified"
  else
    print_error "Bun installation failed"
    exit 1
  fi
}

# Install Java
install_java() {
  print_section "7" "15" "Installing Java"

  if [ "$SETUP_JAVA" != true ]; then
    print_message "$COLOR_INFO" "Skipping Java installation (--no-java flag provided)"
    return
  fi

  if command_exists java && [ "$DRY_RUN" = false ]; then
    print_success "Java is already installed: $(java -version 2>&1 | head -n 1)"
    return
  fi

  print_message "$COLOR_INFO" "Installing Java..."

  # Install Java packages
  execute_cmd "sudo apt update -y"
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR $JAVA_PACKAGES"

  # Verify Java installation
  if command_exists java || [ "$DRY_RUN" = true ]; then
    if [ "$DRY_RUN" = false ]; then
      print_success "Java installed successfully: $(java -version 2>&1 | head -n 1)"
    else
      print_success "Java would be installed successfully"
    fi
  else
    print_error "Java installation failed"
  fi
}

# Configure firewall
configure_firewall() {
  print_section "8" "15" "Configuring firewall"

  if [ "$USE_IPTABLES" = true ]; then
    configure_iptables
  else
    configure_ufw
  fi
}

# Configure UFW
configure_ufw() {
  print_message "$COLOR_INFO" "Configuring UFW firewall..."

  # Install UFW
  execute_cmd "sudo apt update -y"
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR ufw"

  # Reset UFW to default state
  print_message "$COLOR_INFO" "Resetting UFW to default state..."
  execute_cmd "sudo ufw --force reset"

  # Configure ports from ALLOWED_PORTS array
  print_message "$COLOR_INFO" "Configuring firewall rules..."
  
  for port_config in "${ALLOWED_PORTS[@]}"; do
    # Split the port configuration into port/protocol and comment
    IFS="|" read -r port_proto comment <<< "$port_config"
    
    # Split port/protocol into port and protocol
    IFS="/" read -r port protocol <<< "$port_proto"
    
    print_message "$COLOR_INFO" "Adding rule: $port/$protocol ($comment)" 2
    execute_cmd "sudo ufw allow $port/$protocol comment \"$comment\""
  done

  # Enable UFW if not already enabled
  print_message "$COLOR_INFO" "Enabling firewall..."
  execute_cmd "sudo ufw --force enable"

  # Verify UFW is active
  if [ "$DRY_RUN" = false ]; then
    if sudo ufw status | grep -q "Status: active"; then
      print_success "UFW firewall is active and configured"
    else
      print_warning "Failed to enable UFW. Trying again..."
      execute_cmd "sudo systemctl restart ufw"
      if sudo ufw status | grep -q "Status: active"; then
        print_success "UFW firewall is now active"
      else
        print_warning "Could not enable UFW. Please check configuration manually."
      fi
    fi
  else
    print_success "UFW firewall would be configured"
  fi
}

# Configure iptables
configure_iptables() {
  print_message "$COLOR_INFO" "Configuring iptables firewall..."

  # Install iptables-persistent
  execute_cmd "sudo apt update -y"
  # Pre-answer the prompt to save current rules
  execute_cmd "echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections"
  execute_cmd "echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections"
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR iptables-persistent"

  # Flush existing rules
  execute_cmd "sudo iptables -F"
  execute_cmd "sudo iptables -X"
  execute_cmd "sudo iptables -t nat -F"
  execute_cmd "sudo iptables -t nat -X"
  execute_cmd "sudo iptables -t mangle -F"
  execute_cmd "sudo iptables -t mangle -X"

  # Set default policies
  execute_cmd "sudo iptables -P INPUT DROP"
  execute_cmd "sudo iptables -P FORWARD DROP"
  execute_cmd "sudo iptables -P OUTPUT ACCEPT"

  # Allow established connections
  execute_cmd "sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"

  # Allow loopback
  execute_cmd "sudo iptables -A INPUT -i lo -j ACCEPT"

  # Configure ports from ALLOWED_PORTS array
  print_message "$COLOR_INFO" "Configuring firewall rules..."
  
  for port_config in "${ALLOWED_PORTS[@]}"; do
    # Split the port configuration into port/protocol and comment
    IFS="|" read -r port_proto comment <<< "$port_config"
    
    # Split port/protocol into port and protocol
    IFS="/" read -r port protocol <<< "$port_proto"
    
    print_message "$COLOR_INFO" "Adding rule: $port/$protocol ($comment)" 2
    execute_cmd "sudo iptables -A INPUT -p $protocol --dport $port -j ACCEPT"
  done

  # Allow Docker bridge network to communicate with host
  execute_cmd "sudo iptables -I INPUT -i docker0 -j ACCEPT"
  print_message "$COLOR_SUCCESS" "Added iptables rule for Docker bridge"

  # Save rules
  execute_cmd "sudo netfilter-persistent save"

  print_success "iptables firewall configured"
}

# Configure Fail2Ban
configure_fail2ban() {
  print_section "9" "15" "Configuring Fail2Ban"

  if [ "$SETUP_FAIL2BAN" != true ]; then
    print_message "$COLOR_INFO" "Skipping Fail2Ban configuration (--no-fail2ban flag provided)"
    return
  fi

  # Install Fail2Ban
  print_message "$COLOR_INFO" "Installing Fail2Ban..."
  execute_cmd "sudo apt update -y"
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR fail2ban"

  print_message "$COLOR_INFO" "Setting up Fail2Ban..."

  # Check if auth log file exists
  AUTH_LOG="/var/log/auth.log"
  if [ ! -f "$AUTH_LOG" ] && [ "$DRY_RUN" = false ]; then
    print_warning "Auth log file not found at $AUTH_LOG"
    # Create the file if it doesn't exist
    execute_cmd "sudo touch $AUTH_LOG"
    execute_cmd "sudo chmod 640 $AUTH_LOG"
    execute_cmd "sudo chown root:adm $AUTH_LOG"
    print_message "$COLOR_INFO" "Created empty auth log file"
  fi

  # Check permissions of auth log file
  if [ -f "$AUTH_LOG" ] && [ ! -r "$AUTH_LOG" ] && [ "$DRY_RUN" = false ]; then
    print_warning "Auth log file exists but is not readable. Fixing permissions..."
    execute_cmd "sudo chmod 640 $AUTH_LOG"
    execute_cmd "sudo chown root:adm $AUTH_LOG"
  fi

  # Stop the service if it's running
  execute_cmd "sudo systemctl stop fail2ban || true"

  # Remove previous configurations that might cause problems
  execute_cmd "sudo rm -f /etc/fail2ban/jail.local"

  # Create a basic configuration that works even without existing log files
  print_message "$COLOR_INFO" "Creating basic Fail2Ban configuration..."
  
  local fail2ban_config="[DEFAULT]
# Incremental ban time
bantime.increment = true
bantime.rndtime = 300
bantime.formula = ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)
bantime.multipliers = 1 2 4 8 16 32 64
bantime.factor = 1

# Ban IP/hosts for 1 hour by default
bantime = 3600

# Check for new failed attempts every 10 minutes
findtime = 600

# Ban after 5 failed attempts
maxretry = 5

# Use iptables for banning
banaction = iptables-multiport

# Enable sshd protection
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400  # 24 hours

# Create a custom filter for SSH that's more tolerant of missing log files
[sshd-custom]
enabled = true
port = $SSH_PORT
filter = sshd
# Use multiple possible log paths to increase chances of finding logs
logpath = /var/log/auth.log
       /var/log/secure
       /var/log/sshd.log
maxretry = 3
bantime = 86400  # 24 hours"

  execute_cmd "sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
$fail2ban_config
EOF"

  # Make sure necessary directories exist
  execute_cmd "sudo mkdir -p /var/run/fail2ban"
  execute_cmd "sudo chmod 755 /var/run/fail2ban"

  # Remove socket if it exists
  if [ -S "/var/run/fail2ban/fail2ban.sock" ] && [ "$DRY_RUN" = false ]; then
    execute_cmd "sudo rm -f /var/run/fail2ban/fail2ban.sock"
  fi

  # Check if the sshd filter exists
  if [ ! -f "/etc/fail2ban/filter.d/sshd.conf" ] || [ "$DRY_RUN" = true ]; then
    print_warning "SSH filter not found. Creating a basic one..."
    execute_cmd "sudo mkdir -p /etc/fail2ban/filter.d"
    
    local sshd_filter="[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?Authentication failure for .* from <HOST>( via \S+)?\s*$
          ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
          ^%(__prefix_line)sFailed \S+ for invalid user .* from <HOST>(?: port \d+)?(?: ssh\d*)?(: (ruser .*|(\S+ ID \S+ \$serial \d+\$ CA )?\S+ %(__md5hex)s(, client user \".*\", client host \".*\")?))?\s*$
          ^%(__prefix_line)sFailed \S+ for .* from <HOST>(?: port \d+)?(?: ssh\d*)?(: (ruser .*|(\S+ ID \S+ \$serial \d+\$ CA )?\S+ %(__md5hex)s(, client user \".*\", client host \".*\")?))?\s*$
          ^%(__prefix_line)sROOT LOGIN REFUSED.* FROM <HOST>\s*$
          ^%(__prefix_line)s[iI](?:llegal|nvalid) user .* from <HOST>\s*$
          ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers\s*$
          ^%(__prefix_line)sUser .+ from <HOST> not allowed because listed in DenyUsers\s*$
          ^%(__prefix_line)sUser .+ from <HOST> not allowed because not in any group\s*$
          ^%(__prefix_line)srefused connect from \S+ \$<HOST>\$\s*$
          ^%(__prefix_line)sReceived disconnect from <HOST>: 3: \S+: Auth fail$
          ^%(__prefix_line)sUser .+ from <HOST> not allowed because a group is listed in DenyGroups\s*$
          ^%(__prefix_line)sUser .+ from <HOST> not allowed because none of user's groups are listed in AllowGroups\s*$
          ^(?P<__prefix>%(__prefix_line)s)User .+ not allowed because account is locked$
          ^(?P<__prefix>%(__prefix_line)s)User .+ not allowed because not listed in AllowUsers$
          ^(?P<__prefix>%(__prefix_line)s)User .+ not allowed because listed in DenyUsers$
          ^(?P<__prefix>%(__prefix_line)s)Authentication refused: bad ownership or modes for directory \S+$

ignoreregex = 

# \"maxlines\" is number of log lines to buffer for multi-line regex searches
maxlines = 10"

    execute_cmd "sudo tee /etc/fail2ban/filter.d/sshd.conf > /dev/null << 'EOF'
$sshd_filter
EOF"
  fi

  # Restart the service
  print_message "$COLOR_INFO" "Starting Fail2Ban service..."
  if ! execute_cmd "sudo systemctl restart fail2ban"; then
    print_warning "Failed to start Fail2Ban. Checking for errors..."
    
    # Show errors
    if [ "$DRY_RUN" = false ]; then
      execute_cmd "sudo journalctl -u fail2ban --no-pager -n 20"
    fi
    
    # Try a more minimal configuration without log file dependencies
    print_message "$COLOR_INFO" "Trying minimal configuration without log file dependencies..."
    
    local minimal_config="[DEFAULT]
banaction = iptables-multiport
bantime = 3600
findtime = 600
maxretry = 5"

    execute_cmd "sudo tee /etc/fail2ban/jail.local > /dev/null << 'EOF'
$minimal_config
EOF"
    
    # Try to restart again
    if ! execute_cmd "sudo systemctl restart fail2ban"; then
      print_warning "Fail2Ban could not be started. Security will be reduced."
      print_message "$COLOR_INFO" "You can manually configure Fail2Ban later with:"
      print_message "$COLOR_INFO" "  sudo apt-get install --reinstall fail2ban"
      print_message "$COLOR_INFO" "  sudo systemctl restart fail2ban"
      
      # Disable Fail2Ban to avoid future errors
      execute_cmd "sudo systemctl disable fail2ban"
      return
    fi
  fi

  # Check if the service is active
  if [ "$DRY_RUN" = false ]; then
    if systemctl is-active --quiet fail2ban; then
      print_success "Fail2Ban is active and configured"
      
      # Make sure Fail2Ban starts at boot
      execute_cmd "sudo systemctl enable fail2ban"
    else
      print_warning "Fail2Ban service is not running. Security will be reduced."
      print_message "$COLOR_INFO" "You can try to fix it manually later with:"
      print_message "$COLOR_INFO" "  sudo apt-get install --reinstall fail2ban"
      print_message "$COLOR_INFO" "  sudo systemctl restart fail2ban"
    fi
  else
    print_success "Fail2Ban would be configured"
  fi
}

# Configure SSH security
configure_ssh_security() {
  print_section "10" "15" "Configuring SSH security"

  if [ "$SETUP_SSH" != true ]; then
    print_message "$COLOR_INFO" "Skipping SSH configuration (--no-ssh flag provided)"
    return
  fi

  local ssh_config="/etc/ssh/sshd_config"

  print_message "$COLOR_INFO" "Configuring SSH..."

  # Create a backup of the original config
  execute_cmd "sudo cp $ssh_config $ssh_config.bak"

  # Update SSH configuration
  local ssh_config_content="# SSH Server Configuration
Port $SSH_PORT
Protocol 2

# Authentication
PermitRootLogin no
PasswordAuthentication $([ "$ALLOW_PASSWORD_AUTH" = true ] && echo "yes" || echo "no")
PubkeyAuthentication yes
$([ "$ALLOW_PASSWORD_AUTH" = false ] && echo "AuthenticationMethods publickey" || echo "# Password authentication is enabled")
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Security
X11Forwarding no
AllowTcpForwarding $([ "$ALLOW_TCP_FORWARDING" = true ] && echo "yes" || echo "no")
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
SyslogFacility AUTH
LogLevel VERBOSE

# Allow only specific users (customize as needed)
AllowUsers $SETUP_USER

# Include other configuration files
Include /etc/ssh/sshd_config.d/*.conf"

  execute_cmd "sudo tee $ssh_config > /dev/null << 'EOF'
$ssh_config_content
EOF"

  print_message "$COLOR_INFO" "Restarting SSH service..."
  execute_cmd "sudo systemctl restart sshd"

  print_success "SSH configured"

  # Only show password message if a new user was created
  if [ "$ALLOW_PASSWORD_AUTH" = true ] && [ "$USER_CREATED" = true ]; then
    print_message "$COLOR_INFO" "SSH password authentication is enabled"
    if [ "$DRY_RUN" = false ]; then
      print_warning "Remember to change the password for $SETUP_USER after login."
    fi
  elif [ "$ALLOW_PASSWORD_AUTH" = false ]; then
    print_warning "SSH now only allows public key authentication on port $SSH_PORT"
    print_warning "Make sure you have added your SSH key before logging out"
  else
    print_message "$COLOR_INFO" "SSH password authentication is enabled"
  fi
}

# Install Docker
install_docker() {
  print_section "11" "15" "Installing Docker"

  if [ "$SETUP_DOCKER" != true ]; then
    print_message "$COLOR_INFO" "Skipping Docker installation (--no-docker flag provided)"
    return
  fi

  if command_exists docker && command_exists docker-compose && [ "$DRY_RUN" = false ]; then
    print_success "Docker is already installed"
    return
  fi

  print_message "$COLOR_INFO" "Installing Docker..."

  # Install Docker prerequisites
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR ca-certificates gnupg lsb-release"

  # Add Docker's official GPG key
  execute_cmd "sudo install -m 0755 -d /etc/apt/keyrings"
  execute_cmd "curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  execute_cmd "sudo chmod a+r /etc/apt/keyrings/docker.gpg"

  # Add Docker repository
  local docker_repo="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
  execute_cmd "echo \"$docker_repo\" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"

  # Install Docker
  execute_cmd "sudo apt update -y"
  execute_cmd "sudo apt install -y -o Dir::Cache::Archives=$CACHE_DIR docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose"

  # Add user to docker group
  execute_cmd "sudo usermod -aG docker $SETUP_USER"

  # Configure Docker daemon
  execute_cmd "sudo mkdir -p /etc/docker"
  
  local docker_daemon_config='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "features": {
    "buildkit": true
  },
  "experimental": false
}'

  execute_cmd "echo '$docker_daemon_config' | sudo tee /etc/docker/daemon.json > /dev/null"

  # Configure Docker to host communication
  # Add host.docker.internal DNS entry to /etc/hosts if not already present
  if ! grep -q "host.docker.internal" /etc/hosts && [ "$DRY_RUN" = false ]; then
    print_message "$COLOR_INFO" "Adding host.docker.internal to /etc/hosts..."
    execute_cmd "echo '172.17.0.1 host.docker.internal' | sudo tee -a /etc/hosts > /dev/null"
  fi

  # Ensure Docker starts on boot
  execute_cmd "sudo systemctl enable docker"
  execute_cmd "sudo systemctl restart docker"

  print_success "Docker installed"
  print_warning "Docker group permissions require a session restart to take effect"
  print_message "$COLOR_INFO" "To use Docker in the current session without logging out, run: newgrp docker"

  # Fix permissions for the current session if running as the target user
  if [ "$(whoami)" = "$SETUP_USER" ] && [ "$DRY_RUN" = false ]; then
    print_message "$COLOR_INFO" "Applying Docker group permissions to current session..."
    # Create a subshell with the new group
    sg docker -c "docker ps > /dev/null 2>&1"
    # Check if the command succeeded
    if [ $? -eq 0 ]; then
      print_success "Docker permissions applied to current session"
    else
      print_warning "Could not apply Docker permissions to current session"
      print_message "$COLOR_INFO" "Please run 'newgrp docker' or log out and back in"
    fi
  fi
}

# Clone repository and set up project
setup_project() {
  print_section "12" "15" "Setting up Ignis project"

  # Create installation directory if it doesn't exist
  if [ ! -d "$INSTALLATION_DIR" ] || [ "$DRY_RUN" = true ]; then
    execute_cmd "sudo mkdir -p $INSTALLATION_DIR"
    execute_cmd "sudo chown $SETUP_USER:$SETUP_USER $INSTALLATION_DIR"
  fi

  # Clone repository if requested
  if [ "$CLONE_REPO" = true ]; then
    if [ ! -d "$INSTALLATION_DIR/.git" ] || [ "$DRY_RUN" = true ]; then
      print_message "$COLOR_INFO" "Cloning repository from $GIT_REPO..."
      
      if [ "$(whoami)" = "$SETUP_USER" ]; then
        # Running as the target user
        execute_cmd "git clone -b $GIT_BRANCH $GIT_REPO $INSTALLATION_DIR"
      else
        # Running as another user, use sudo to run commands as the target user
        execute_cmd "sudo -u $SETUP_USER git clone -b $GIT_BRANCH $GIT_REPO $INSTALLATION_DIR"
      fi
      
      print_success "Repository cloned successfully"
    else
      print_message "$COLOR_INFO" "Repository already exists, pulling latest changes..."
      
      if [ "$DRY_RUN" = false ]; then
        cd "$INSTALLATION_DIR" || {
          print_error "Could not change to installation directory: $INSTALLATION_DIR"
          exit 1
        }
        
        if [ "$(whoami)" = "$SETUP_USER" ]; then
          execute_cmd "git checkout $GIT_BRANCH"
          execute_cmd "git pull"
        else
          execute_cmd "sudo -u $SETUP_USER git checkout $GIT_BRANCH"
          execute_cmd "sudo -u $SETUP_USER git pull"
        fi
      else
        print_message "$COLOR_INFO" "[DRY RUN] Would update repository in $INSTALLATION_DIR" 1
      fi
      
      print_success "Repository updated"
    fi
  else
    print_message "$COLOR_INFO" "Skipping repository clone (--no-clone flag provided)"
  fi

  # Create required directories
  execute_cmd "mkdir -p $INSTALLATION_DIR/logs/webhook"
  execute_cmd "mkdir -p $INSTALLATION_DIR/logs/deployments"
  execute_cmd "mkdir -p $INSTALLATION_DIR/logs/certs"
  execute_cmd "mkdir -p $INSTALLATION_DIR/proxy/certs"
  execute_cmd "mkdir -p $INSTALLATION_DIR/proxy/dynamic"
  execute_cmd "mkdir -p $INSTALLATION_DIR/deployments/service"
  
  # Create acme.json file if it doesn't exist
  if [ ! -e "$INSTALLATION_DIR/proxy/acme.json" ] || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Creating acme.json file for Let's Encrypt certificates..."
    # Ensure it's created as a file, not a directory
    execute_cmd "touch $INSTALLATION_DIR/proxy/acme.json"
    execute_cmd "chmod 600 $INSTALLATION_DIR/proxy/acme.json"
    print_success "Created acme.json file with proper permissions"
  elif [ -d "$INSTALLATION_DIR/proxy/acme.json" ] && [ "$DRY_RUN" = false ]; then
    # If it exists as a directory, fix it
    print_warning "acme.json exists as a directory instead of a file, fixing..."
    execute_cmd "rm -rf $INSTALLATION_DIR/proxy/acme.json"
    execute_cmd "touch $INSTALLATION_DIR/proxy/acme.json"
    execute_cmd "chmod 600 $INSTALLATION_DIR/proxy/acme.json"
    print_success "Fixed acme.json (converted from directory to file)"
  fi

  # Create .env file if it doesn't exist
  if [ ! -f "$INSTALLATION_DIR/.env" ] || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Creating template .env file..."
    
    # Generate a secure webhook secret
    local webhook_secret
    if [ "$DRY_RUN" = false ]; then
      webhook_secret=$(openssl rand -hex 16)
    else
      webhook_secret="ignis_webhook_secret_PLACEHOLDER"
    fi
    
    local env_content="WEBHOOK_SECRET=$webhook_secret
ENVIRONMENT=production
WEBHOOK_PORT=3333
WEBHOOK_HOST=0.0.0.0"

    execute_cmd "echo '$env_content' > $INSTALLATION_DIR/.env"
    print_success "Created .env file with a random WEBHOOK_SECRET"
  fi

  # Set proper permissions
  execute_cmd "sudo chown -R $SETUP_USER:$SETUP_USER $INSTALLATION_DIR"

  # Make sure script directories exist and have proper permissions
  if [ -d "$INSTALLATION_DIR/scripts" ] || [ "$DRY_RUN" = true ]; then
    execute_cmd "sudo chmod -R 755 $INSTALLATION_DIR/scripts"
  fi

  if [ -d "$INSTALLATION_DIR/deployments/scripts" ] || [ "$DRY_RUN" = true ]; then
    execute_cmd "sudo chmod -R 755 $INSTALLATION_DIR/deployments/scripts"
  fi

  print_success "Ignis project setup completed"
}

# Install and configure services
install_services() {
  print_section "13" "15" "Installing and configuring services"

  if [ "$INSTALL_SERVICES" != true ]; then
    print_message "$COLOR_INFO" "Skipping service installation (--no-install-services flag provided)"
    return
  fi

  # Find all service files
  local service_dir="$INSTALLATION_DIR/deployments/service"
  
  if [ -d "$service_dir" ] || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Installing systemd services..."
    
    # Process each service file
    if [ "$DRY_RUN" = false ]; then
      find "$service_dir" -name "*.service" -type f | while read -r src; do
        local service_name
        service_name=$(basename "$src" .service)
        local dst="/etc/systemd/system/${service_name}.service"
        
        print_message "$COLOR_INFO" "Installing service: $service_name" 2
        execute_cmd "sudo cp $src $dst"
        execute_cmd "sudo systemctl daemon-reload"
        execute_cmd "sudo systemctl enable $service_name"
        
        # Verify NoNewPrivileges is set
        if grep -q "NoNewPrivileges=" "$src"; then
          print_success "Service $service_name has NoNewPrivileges set" 2
        else
          print_warning "Service $service_name does not have NoNewPrivileges set" 2
          print_message "$COLOR_INFO" "Consider adding 'NoNewPrivileges=true' to the [Service] section" 2
        fi
      done
    else
      print_message "$COLOR_INFO" "[DRY RUN] Would install systemd services from $service_dir" 1
    fi
    
    # Start services if requested
    if [ "$START_SERVICES" = true ]; then
      print_message "$COLOR_INFO" "Starting services..."
      
      # Start ignis-startup service which should handle other services
      if [ "$DRY_RUN" = false ] && systemctl list-unit-files | grep -q "ignis-startup.service"; then
        execute_cmd "sudo systemctl start ignis-startup.service"
        print_success "Started ignis-startup service"
      elif [ "$DRY_RUN" = true ]; then
        print_message "$COLOR_INFO" "[DRY RUN] Would start ignis-startup service" 1
      else
        # Start each service individually if ignis-startup doesn't exist
        if [ "$DRY_RUN" = false ]; then
          find "$service_dir" -name "*.service" -type f | while read -r src; do
            local service_name
            service_name=$(basename "$src" .service)
            print_message "$COLOR_INFO" "Starting service: $service_name" 2
            execute_cmd "sudo systemctl start $service_name"
          done
        else
          print_message "$COLOR_INFO" "[DRY RUN] Would start individual services" 1
        fi
      fi
    else
      print_message "$COLOR_INFO" "Skipping service startup (--no-start-services flag provided)"
      print_message "$COLOR_INFO" "You can start services manually with: sudo systemctl start ignis-startup.service"
    fi
  else
    print_warning "Service directory not found: $service_dir"
  fi
  
  print_success "Services installed and configured"
}

# Configure permissions
configure_permissions() {
  print_section "14" "15" "Configuring permissions"

  print_message "$COLOR_INFO" "Setting up file permissions..."

  # Set proper permissions for log directories
  execute_cmd "sudo chown -R $SETUP_USER:$SETUP_USER $INSTALLATION_DIR/logs"
  execute_cmd "sudo chmod -R 775 $INSTALLATION_DIR/logs"

  # Set proper permissions for proxy directories
  execute_cmd "sudo chown -R $SETUP_USER:$SETUP_USER $INSTALLATION_DIR/proxy"
  execute_cmd "sudo chmod -R 775 $INSTALLATION_DIR/proxy"

  # Set proper permissions for deployments directories
  execute_cmd "sudo chown -R $SETUP_USER:$SETUP_USER $INSTALLATION_DIR/deployments"
  execute_cmd "sudo chmod -R 775 $INSTALLATION_DIR/deployments"

  # Set proper permissions for acme.json
  execute_cmd "sudo chown $SETUP_USER:$SETUP_USER $INSTALLATION_DIR/proxy/acme.json"
  execute_cmd "sudo chmod 600 $INSTALLATION_DIR/proxy/acme.json"

  # Set proper permissions for .env file
  execute_cmd "sudo chown $SETUP_USER:$SETUP_USER $INSTALLATION_DIR/.env"
  execute_cmd "sudo chmod 600 $INSTALLATION_DIR/.env"
  
  # Configure Docker socket permissions
  if [ -S "/var/run/docker.sock" ] || [ "$DRY_RUN" = true ]; then
    print_message "$COLOR_INFO" "Configuring Docker socket permissions..."
    execute_cmd "sudo chmod 666 /var/run/docker.sock || sudo chmod 660 /var/run/docker.sock"
    
    # Add user to docker group if not already
    if ! groups "$SETUP_USER" | grep -q docker && [ "$DRY_RUN" = false ]; then
      print_message "$COLOR_INFO" "Adding $SETUP_USER to docker group..."
      execute_cmd "sudo usermod -aG docker $SETUP_USER"
      print_warning "You'll need to log out and back in for the group changes to take effect."
    elif [ "$DRY_RUN" = true ]; then
      print_message "$COLOR_INFO" "[DRY RUN] Would add $SETUP_USER to docker group" 1
    fi
  fi

  print_success "File permissions and Docker setup completed"
}

# Uninstall Ignis
uninstall_ignis() {
  print_section "1" "1" "Uninstalling Ignis"

  if [ "$UNINSTALL" != true ]; then
    print_error "Uninstall flag not set. Use --uninstall to confirm uninstallation."
    exit 1
  fi

  print_warning "This will remove all Ignis files, services, and configurations."
  print_warning "This action cannot be undone."
  
  if [ "$DRY_RUN" = false ]; then
    # Prompt for confirmation
    read -p "Are you sure you want to uninstall Ignis? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_error "Uninstallation cancelled."
      exit 1
    fi
    
    print_message "$COLOR_INFO" "Stopping Ignis services..."
    # Find and stop all Ignis services
    systemctl list-units --type=service --all | grep "ignis" | awk '{print $1}' | while read -r service; do
      execute_cmd "sudo systemctl stop $service"
      execute_cmd "sudo systemctl disable $service"
      execute_cmd "sudo rm -f /etc/systemd/system/$service"
    done
    execute_cmd "sudo systemctl daemon-reload"
    
    # Remove installation directory
    print_message "$COLOR_INFO" "Removing Ignis installation directory..."
    execute_cmd "sudo rm -rf $INSTALLATION_DIR"
    
    # Remove user if created by this script
    if [ "$USER_CREATED" = true ]; then
      print_message "$COLOR_INFO" "Removing user $SETUP_USER..."
      execute_cmd "sudo userdel -r $SETUP_USER"
    fi
    
    # Remove Docker containers related to Ignis
    if command_exists docker; then
      print_message "$COLOR_INFO" "Removing Docker containers related to Ignis..."
      docker ps -a | grep "ignis" | awk '{print $1}' | while read -r container; do
        execute_cmd "sudo docker stop $container"
        execute_cmd "sudo docker rm $container"
      done
      
      # Remove Docker images related to Ignis
      print_message "$COLOR_INFO" "Removing Docker images related to Ignis..."
      docker images | grep "ignis" | awk '{print $3}' | while read -r image; do
        execute_cmd "sudo docker rmi $image"
      done
    fi
    
    # Remove cache directory
    if [ -d "$CACHE_DIR" ]; then
      print_message "$COLOR_INFO" "Removing cache directory..."
      execute_cmd "sudo rm -rf $CACHE_DIR"
    fi
    
    print_success "Ignis has been uninstalled successfully."
  else
    print_message "$COLOR_INFO" "[DRY RUN] Would uninstall Ignis from $INSTALLATION_DIR" 1
    print_message "$COLOR_INFO" "[DRY RUN] Would stop and remove all Ignis services" 1
    print_message "$COLOR_INFO" "[DRY RUN] Would remove Docker containers and images related to Ignis" 1
  fi
  
  exit 0
}

# Generate system summary
generate_summary() {
  print_section "15" "15" "Generating system summary"
  
  print_message "$COLOR_TITLE" "=== IGNIS SYSTEM SUMMARY ==="

  # Check versions
  echo -e "${COLOR_INFO}Software Versions:${COLOR_RESET}"
  if [ "$DRY_RUN" = false ]; then
    if command_exists node; then
      echo -e "  Node.js: $(node -v)"
    else
      echo -e "  Node.js: Not installed"
    fi

    if command_exists npm; then
      echo -e "  NPM: $(npm -v)"
    else
      echo -e "  NPM: Not installed"
    fi

    if command_exists bun; then
      echo -e "  Bun: $(bun --version)"
    else
      echo -e "  Bun: Not installed"
    fi

    if command_exists docker; then
      echo -e "  Docker: $(docker --version)"
    else
      echo -e "  Docker: Not installed"
    fi

    if command_exists java; then
      echo -e "  Java: $(java -version 2>&1 | head -n 1)"
    else
      echo -e "  Java: Not installed"
    fi
  else
    echo -e "  [DRY RUN] Would check installed software versions"
  fi

  # Check services
  echo -e "${COLOR_INFO}Services Status:${COLOR_RESET}"
  if [ "$DRY_RUN" = false ]; then
    echo -e "  Docker: $(systemctl is-active docker 2>/dev/null || echo "not installed")"
    
    # Check installed Ignis services
    if [ -d "/etc/systemd/system" ]; then
      echo -e "  Ignis Services:"
      systemctl list-units --type=service --all | grep "ignis" | while read -r line; do
        echo -e "    $line"
      done
    fi
  else
    echo -e "  [DRY RUN] Would check service status"
  fi

  # Check Fail2Ban status
  if [ "$SETUP_FAIL2BAN" = true ] && [ "$DRY_RUN" = false ]; then
    if systemctl is-active fail2ban.service >/dev/null 2>&1; then
      echo -e "  Fail2Ban: active"
    else
      echo -e "  Fail2Ban: inactive (optional security feature)"
    fi
  elif [ "$SETUP_FAIL2BAN" = true ]; then
    echo -e "  Fail2Ban: would be configured"
  else
    echo -e "  Fail2Ban: not configured (optional security feature)"
  fi

  # Check firewall status
  if [ "$USE_IPTABLES" = true ] && [ "$DRY_RUN" = false ]; then
    echo -e "${COLOR_INFO}Firewall Status (iptables):${COLOR_RESET}"
    sudo iptables -L -n | grep -E "Chain|ACCEPT|DROP" | head -n 10
  elif [ "$USE_IPTABLES" = true ]; then
    echo -e "${COLOR_INFO}Firewall Status (iptables):${COLOR_RESET}"
    echo -e "  [DRY RUN] Would configure iptables firewall"
  elif [ "$DRY_RUN" = false ]; then
    echo -e "${COLOR_INFO}Firewall Status (UFW):${COLOR_RESET}"
    if sudo ufw status | grep -q "Status: active"; then
      echo -e "  UFW: active"
      sudo ufw status | grep -v "(v6)" | head -n 10
    else
      echo -e "  UFW: inactive"
    fi
  else
    echo -e "${COLOR_INFO}Firewall Status (UFW):${COLOR_RESET}"
    echo -e "  [DRY RUN] Would configure UFW firewall"
  fi

  # Installation details
  echo -e "${COLOR_INFO}Installation Details:${COLOR_RESET}"
  echo -e "  Installation Directory: $INSTALLATION_DIR"
  echo -e "  System User: $SETUP_USER"
  echo -e "  SSH Port: $SSH_PORT"
  echo -e "  Password Authentication: $([ "$ALLOW_PASSWORD_AUTH" = true ] && echo "Enabled" || echo "Disabled")"
  echo -e "  TCP Forwarding: $([ "$ALLOW_TCP_FORWARDING" = true ] && echo "Enabled" || echo "Disabled")"
  echo -e "  Logging to File: $([ "$LOG_TO_FILE" = true ] && echo "Enabled ($LOG_FILE)" || echo "Disabled")"
  echo -e "  Dry Run Mode: $([ "$DRY_RUN" = true ] && echo "Enabled" || echo "Disabled")"

  # Docker permissions reminder
  if command_exists docker || [ "$DRY_RUN" = true ]; then
    echo -e "${COLOR_WARNING}Docker Permissions:${COLOR_RESET}"
    echo -e "  If you encounter 'permission denied' errors with Docker commands, run:"
    echo -e "  $ newgrp docker"
    echo -e "  Or log out and log back in to apply group changes."
  fi

  # Next steps
  echo -e "${COLOR_WARNING}Next Steps:${COLOR_RESET}"
  if [ "$ALLOW_PASSWORD_AUTH" = true ] && [ "$USER_CREATED" = true ] && [ "$DRY_RUN" = false ]; then
    echo -e "  1. SSH access command: ssh $SETUP_USER@your-server -p $SSH_PORT"
    echo -e "  2. Change the default password immediately after login"
  elif [ "$ALLOW_PASSWORD_AUTH" = true ]; then
    echo -e "  1. SSH access command: ssh $SETUP_USER@your-server -p $SSH_PORT"
  else
    echo -e "  1. Add your SSH public key to /home/$SETUP_USER/.ssh/authorized_keys"
    echo -e "  2. SSH access command: ssh $SETUP_USER@your-server -p $SSH_PORT"
  fi
  echo -e "  3. Configure GitHub webhooks to point to your server: https://your-server:3333/webhook"
  
  if [ "$START_SERVICES" != true ]; then
    echo -e "  4. Start services manually: sudo systemctl start ignis-startup.service"
  fi

  print_message "$COLOR_TITLE" "=== SETUP COMPLETE ==="
}

# ==================== MAIN FUNCTION ====================
main() {
  print_message "$COLOR_TITLE" "=== IGNIS SYSTEM INITIALIZATION ==="
  print_message "$COLOR_INFO" "Starting setup process..."

  # Parse command line arguments
  parse_arguments "$@"
  
  # Initialize log file if logging is enabled
  initialize_log_file
  
  # Handle uninstall mode
  if [ "$UNINSTALL" = true ]; then
    uninstall_ignis
    exit 0
  fi
  
  # Validate system requirements
  validate_system_requirements

  # Run installation steps
  update_system
  install_base_packages
  create_system_user
  install_node
  install_bun
  install_java
  configure_firewall
  configure_fail2ban
  configure_ssh_security
  install_docker
  setup_project
  install_services
  configure_permissions

  # Generate summary
  generate_summary
}

# Execute main function with all arguments
main "$@"