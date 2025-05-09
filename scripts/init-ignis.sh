#!/bin/bash
# Ignis System Initialization Script
# This script sets up the Ignis ERP system with all required dependencies
# and security configurations.
# 
# Author: v0
# Version: 3.2.0
# License: MIT

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

# Required packages by category
readonly SYSTEM_PACKAGES="curl ca-certificates gnupg unzip git software-properties-common jq"
readonly SECURITY_PACKAGES="ufw fail2ban"
readonly JAVA_PACKAGES="openjdk-17-jre-headless"

# ==================== UTILITY FUNCTIONS ====================

# Pure function to log a message to file if enabled
log_to_file() {
  local message="$1"
  if [ "$LOG_TO_FILE" = true ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
  fi
}

# Pure function to print a formatted message
print_message() {
  local color="$1"
  local message="$2"
  echo -e "${color}${message}${COLOR_RESET}"
  log_to_file "$message"
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
  print_message "$COLOR_SUCCESS" "✅ $1"
}

# Pure function to print a warning message
print_warning() {
  print_message "$COLOR_WARNING" "⚠️ $1"
}

# Pure function to print an error message
print_error() {
  print_message "$COLOR_ERROR" "❌ $1"
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
--help                Show this help message

Example:
$0 --ssh-port=2222 --dir=/home/ignis/Ignis --no-ssh --log-to-file
EOF
}

# Initialize log file if logging is enabled
initialize_log_file() {
  if [ "$LOG_TO_FILE" = true ]; then
    echo "=== IGNIS SYSTEM INITIALIZATION LOG - $(date) ===" > "$LOG_FILE"
    print_message "$COLOR_INFO" "Logging to file: $LOG_FILE"
  fi
}

# ==================== INSTALLATION FUNCTIONS ====================

# Update system packages
update_system() {
  print_section "1" "14" "Updating system packages"

  if [ "$UPDATE_SYSTEM" = true ]; then
    print_message "$COLOR_INFO" "Updating package lists..."
    sudo apt update -y
    
    print_message "$COLOR_INFO" "Upgrading packages..."
    sudo apt upgrade -y
    
    print_success "System packages updated"
  else
    print_message "$COLOR_INFO" "Skipping system update (--no-update flag provided)"
  fi
}

# Install required packages
install_base_packages() {
  print_section "2" "14" "Installing base packages"

  print_message "$COLOR_INFO" "Installing system packages..."
  
  # Install all system packages at once
  sudo apt update -y
  sudo apt install -y $SYSTEM_PACKAGES
  
  # Verify critical commands
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
  
  print_success "All required packages installed and verified"
}

# Create system user
create_system_user() {
  print_section "3" "14" "Setting up system user"

  local user_created=false

  if ! user_exists "$SETUP_USER"; then
    print_message "$COLOR_INFO" "Creating user $SETUP_USER..."
    sudo useradd -m -s /bin/bash "$SETUP_USER"
    
    # Add user to sudo group
    sudo usermod -aG sudo "$SETUP_USER"
    
    # Set a password for the user if password authentication is enabled
    if [ "$ALLOW_PASSWORD_AUTH" = true ]; then
      print_message "$COLOR_INFO" "Setting password for $SETUP_USER..."
      echo "$SETUP_USER:ignis123" | sudo chpasswd
      print_warning "Default password set to 'ignis123'. Please change it immediately after login."
    fi
    
    user_created=true
    print_success "User $SETUP_USER created"
    
    # Set up SSH directory for the new user
    if [ ! -d "/home/$SETUP_USER/.ssh" ]; then
      sudo mkdir -p "/home/$SETUP_USER/.ssh"
      sudo chmod 700 "/home/$SETUP_USER/.ssh"
      sudo touch "/home/$SETUP_USER/.ssh/authorized_keys"
      sudo chmod 600 "/home/$SETUP_USER/.ssh/authorized_keys"
      sudo chown -R "$SETUP_USER:$SETUP_USER" "/home/$SETUP_USER/.ssh"
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
  print_section "4" "14" "Installing NVM and Node.js LTS"

  # Determine the correct home directory
  local USER_HOME
  if [ "$(whoami)" = "$SETUP_USER" ]; then
    USER_HOME="$HOME"
  else
    USER_HOME="/home/$SETUP_USER"
  fi

  if [ ! -d "$USER_HOME/.nvm" ]; then
    print_message "$COLOR_INFO" "Installing NVM..."
    
    # If running as the target user
    if [ "$(whoami)" = "$SETUP_USER" ]; then
      curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash
    else
      # Running as another user (likely root), so use sudo to install for the target user
      sudo -u "$SETUP_USER" bash -c 'curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash'
    fi
  else
    print_success "NVM is already installed"
  fi

  # Load NVM and install Node.js
  if [ "$(whoami)" = "$SETUP_USER" ]; then
    # Running as the target user
    export NVM_DIR="$USER_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    if ! command_exists node; then
      print_message "$COLOR_INFO" "Installing Node.js LTS..."
      nvm install --lts
      nvm use --lts
      nvm alias default lts/*
    else
      print_success "Node.js is already installed: $(node -v)"
    fi
  else
    # Running as another user, use sudo to run commands as the target user
    print_message "$COLOR_INFO" "Installing Node.js LTS for user $SETUP_USER..."
    sudo -u "$SETUP_USER" bash -c "export NVM_DIR=\"$USER_HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm install --lts && nvm use --lts && nvm alias default lts/*"
  fi

  # Create global symlinks for node and npm
  if [ -d "$USER_HOME/.nvm/versions/node" ]; then
    NODE_VERSION=$(ls -1 "$USER_HOME/.nvm/versions/node" | grep -v "versions" | sort -V | tail -n 1)
    if [ -n "$NODE_VERSION" ]; then
      sudo ln -sf "$USER_HOME/.nvm/versions/node/$NODE_VERSION/bin/node" /usr/local/bin/node
      sudo ln -sf "$USER_HOME/.nvm/versions/node/$NODE_VERSION/bin/npm" /usr/local/bin/npm
      print_success "Node.js symlinks created"
    fi
  fi
}

# Install Bun
install_bun() {
  print_section "5" "14" "Installing Bun"

  # Determine the correct home directory
  local USER_HOME
  if [ "$(whoami)" = "$SETUP_USER" ]; then
    USER_HOME="$HOME"
  else
    USER_HOME="/home/$SETUP_USER"
  fi

  if ! command_exists bun; then
    print_message "$COLOR_INFO" "Installing Bun..."
    
    if [ "$(whoami)" = "$SETUP_USER" ]; then
      # Running as the target user
      curl -fsSL https://bun.sh/install | bash
    else
      # Running as another user, use sudo to run commands as the target user
      sudo -u "$SETUP_USER" bash -c 'curl -fsSL https://bun.sh/install | bash'
    fi
    
    # Create global symlink for bun
    print_message "$COLOR_INFO" "Creating global symlink for Bun..."
    sudo ln -sf "$USER_HOME/.bun/bin/bun" /usr/local/bin/bun
  else
    print_success "Bun is already installed: $(bun --version)"
    
    # Check if symlink exists and points to the correct location
    if [ -L "/usr/local/bin/bun" ]; then
      LINK_TARGET=$(readlink -f /usr/local/bin/bun)
      if [ "$LINK_TARGET" != "$USER_HOME/.bun/bin/bun" ]; then
        print_message "$COLOR_INFO" "Updating Bun symlink..."
        sudo rm -f /usr/local/bin/bun
        sudo ln -sf "$USER_HOME/.bun/bin/bun" /usr/local/bin/bun
      fi
    else
      print_message "$COLOR_INFO" "Creating global symlink for Bun..."
      sudo ln -sf "$USER_HOME/.bun/bin/bun" /usr/local/bin/bun
    fi
  fi

  # Verify Bun installation
  if command_exists bun; then
    print_success "Bun installation verified"
  else
    print_error "Bun installation failed"
    exit 1
  fi
}

# Install Java
install_java() {
  print_section "6" "14" "Installing Java"

  if [ "$SETUP_JAVA" != true ]; then
    print_message "$COLOR_INFO" "Skipping Java installation (--no-java flag provided)"
    return
  fi

  if command_exists java; then
    print_success "Java is already installed: $(java -version 2>&1 | head -n 1)"
    return
  fi

  print_message "$COLOR_INFO" "Installing Java..."

  # Install Java packages
  sudo apt update -y
  sudo apt install -y $JAVA_PACKAGES

  # Verify Java installation
  if command_exists java; then
    print_success "Java installed successfully: $(java -version 2>&1 | head -n 1)"
  else
    print_error "Java installation failed"
  fi
}

# Configure firewall
configure_firewall() {
  print_section "7" "14" "Configuring firewall"

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
  sudo apt update -y
  sudo apt install -y ufw

  # Reset UFW to default state
  print_message "$COLOR_INFO" "Resetting UFW to default state..."
  sudo ufw --force reset

  # Configure ports from ALLOWED_PORTS array
  print_message "$COLOR_INFO" "Configuring firewall rules..."
  
  for port_config in "${ALLOWED_PORTS[@]}"; do
    # Split the port configuration into port/protocol and comment
    IFS="|" read -r port_proto comment <<< "$port_config"
    
    # Split port/protocol into port and protocol
    IFS="/" read -r port protocol <<< "$port_proto"
    
    print_message "$COLOR_INFO" "Adding rule: $port/$protocol ($comment)"
    sudo ufw allow "$port/$protocol" comment "$comment"
  done

  # Enable UFW if not already enabled
  print_message "$COLOR_INFO" "Enabling firewall..."
  sudo ufw --force enable

  # Verify UFW is active
  if sudo ufw status | grep -q "Status: active"; then
    print_success "UFW firewall is active and configured"
  else
    print_warning "Failed to enable UFW. Trying again..."
    sudo systemctl restart ufw
    if sudo ufw status | grep -q "Status: active"; then
      print_success "UFW firewall is now active"
    else
      print_warning "Could not enable UFW. Please check configuration manually."
    fi
  fi
}

# Configure iptables
configure_iptables() {
  print_message "$COLOR_INFO" "Configuring iptables firewall..."

  # Install iptables-persistent
  sudo apt update -y
  # Pre-answer the prompt to save current rules
  echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
  echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
  sudo apt install -y iptables-persistent

  # Flush existing rules
  sudo iptables -F
  sudo iptables -X
  sudo iptables -t nat -F
  sudo iptables -t nat -X
  sudo iptables -t mangle -F
  sudo iptables -t mangle -X

  # Set default policies
  sudo iptables -P INPUT DROP
  sudo iptables -P FORWARD DROP
  sudo iptables -P OUTPUT ACCEPT

  # Allow established connections
  sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # Allow loopback
  sudo iptables -A INPUT -i lo -j ACCEPT

  # Configure ports from ALLOWED_PORTS array
  print_message "$COLOR_INFO" "Configuring firewall rules..."
  
  for port_config in "${ALLOWED_PORTS[@]}"; do
    # Split the port configuration into port/protocol and comment
    IFS="|" read -r port_proto comment <<< "$port_config"
    
    # Split port/protocol into port and protocol
    IFS="/" read -r port protocol <<< "$port_proto"
    
    print_message "$COLOR_INFO" "Adding rule: $port/$protocol ($comment)"
    sudo iptables -A INPUT -p "$protocol" --dport "$port" -j ACCEPT
  done

  # Allow Docker bridge network to communicate with host
  sudo iptables -I INPUT -i docker0 -j ACCEPT
  print_message "$COLOR_SUCCESS" "Added iptables rule for Docker bridge"

  # Save rules
  sudo netfilter-persistent save

  print_success "iptables firewall configured"
}

# Configure Fail2Ban
configure_fail2ban() {
  print_section "8" "14" "Configuring Fail2Ban"

  if [ "$SETUP_FAIL2BAN" != true ]; then
    print_message "$COLOR_INFO" "Skipping Fail2Ban configuration (--no-fail2ban flag provided)"
    return
  fi

  # Install Fail2Ban
  print_message "$COLOR_INFO" "Installing Fail2Ban..."
  sudo apt update -y
  sudo apt install -y fail2ban

  print_message "$COLOR_INFO" "Setting up Fail2Ban..."

  # Check if auth log file exists
  AUTH_LOG="/var/log/auth.log"
  if [ ! -f "$AUTH_LOG" ]; then
    print_warning "Auth log file not found at $AUTH_LOG"
    # Create the file if it doesn't exist
    sudo touch "$AUTH_LOG"
    sudo chmod 640 "$AUTH_LOG"
    sudo chown root:adm "$AUTH_LOG"
    print_message "$COLOR_INFO" "Created empty auth log file"
  fi

  # Check permissions of auth log file
  if [ -f "$AUTH_LOG" ] && [ ! -r "$AUTH_LOG" ]; then
    print_warning "Auth log file exists but is not readable. Fixing permissions..."
    sudo chmod 640 "$AUTH_LOG"
    sudo chown root:adm "$AUTH_LOG"
  fi

  # Stop the service if it's running
  sudo systemctl stop fail2ban || true

  # Remove previous configurations that might cause problems
  sudo rm -f /etc/fail2ban/jail.local

  # Create a basic configuration that works even without existing log files
  print_message "$COLOR_INFO" "Creating basic Fail2Ban configuration..."
  sudo tee "/etc/fail2ban/jail.local" > /dev/null << EOF
[DEFAULT]
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
bantime = 86400  # 24 hours
EOF

  # Make sure necessary directories exist
  sudo mkdir -p /var/run/fail2ban
  sudo chmod 755 /var/run/fail2ban

  # Remove socket if it exists
  if [ -S /var/run/fail2ban/fail2ban.sock ]; then
    sudo rm -f /var/run/fail2ban/fail2ban.sock
  fi

  # Check if the sshd filter exists
  if [ ! -f "/etc/fail2ban/filter.d/sshd.conf" ]; then
    print_warning "SSH filter not found. Creating a basic one..."
    sudo mkdir -p /etc/fail2ban/filter.d
    sudo tee "/etc/fail2ban/filter.d/sshd.conf" > /dev/null << EOF
[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?Authentication failure for .* from <HOST>( via \S+)?\s*$
          ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
          ^%(__prefix_line)sFailed \S+ for invalid user .* from <HOST>(?: port \d+)?(?: ssh\d*)?(: (ruser .*|(\S+ ID \S+ \$serial \d+\$ CA )?\S+ %(__md5hex)s(, client user ".*", client host ".*")?))?\s*$
          ^%(__prefix_line)sFailed \S+ for .* from <HOST>(?: port \d+)?(?: ssh\d*)?(: (ruser .*|(\S+ ID \S+ \$serial \d+\$ CA )?\S+ %(__md5hex)s(, client user ".*", client host ".*")?))?\s*$
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

# "maxlines" is number of log lines to buffer for multi-line regex searches
maxlines = 10
EOF
  fi

  # Restart the service
  print_message "$COLOR_INFO" "Starting Fail2Ban service..."
  if ! sudo systemctl restart fail2ban; then
    print_warning "Failed to start Fail2Ban. Checking for errors..."
    
    # Show errors
    sudo journalctl -u fail2ban --no-pager -n 20
    
    # Try a more minimal configuration without log file dependencies
    print_message "$COLOR_INFO" "Trying minimal configuration without log file dependencies..."
    sudo tee "/etc/fail2ban/jail.local" > /dev/null << EOF
[DEFAULT]
banaction = iptables-multiport
bantime = 3600
findtime = 600
maxretry = 5
EOF
    
    # Try to restart again
    if ! sudo systemctl restart fail2ban; then
      print_warning "Fail2Ban could not be started. Security will be reduced."
      print_message "$COLOR_INFO" "You can manually configure Fail2Ban later with:"
      print_message "$COLOR_INFO" "  sudo apt-get install --reinstall fail2ban"
      print_message "$COLOR_INFO" "  sudo systemctl restart fail2ban"
      
      # Disable Fail2Ban to avoid future errors
      sudo systemctl disable fail2ban
      return
    fi
  fi

  # Check if the service is active
  if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban is active and configured"
    
    # Make sure Fail2Ban starts at boot
    sudo systemctl enable fail2ban
  else
    print_warning "Fail2Ban service is not running. Security will be reduced."
    print_message "$COLOR_INFO" "You can try to fix it manually later with:"
    print_message "$COLOR_INFO" "  sudo apt-get install --reinstall fail2ban"
    print_message "$COLOR_INFO" "  sudo systemctl restart fail2ban"
  fi
}

# Configure SSH security
configure_ssh_security() {
  print_section "9" "14" "Configuring SSH security"

  if [ "$SETUP_SSH" != true ]; then
    print_message "$COLOR_INFO" "Skipping SSH configuration (--no-ssh flag provided)"
    return
  fi

  local ssh_config="/etc/ssh/sshd_config"

  print_message "$COLOR_INFO" "Configuring SSH..."

  # Create a backup of the original config
  sudo cp "$ssh_config" "$ssh_config.bak"

  # Update SSH configuration
  sudo tee "$ssh_config" > /dev/null << EOF
# SSH Server Configuration
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
Include /etc/ssh/sshd_config.d/*.conf
EOF

  print_message "$COLOR_INFO" "Restarting SSH service..."
  sudo systemctl restart sshd

  print_success "SSH configured"

  # Only show password message if a new user was created
  if [ "$ALLOW_PASSWORD_AUTH" = true ] && [ "$USER_CREATED" = true ]; then
    print_message "$COLOR_INFO" "SSH password authentication is enabled"
    print_warning "Default password for $SETUP_USER is 'ignis123'. Please change it after login."
  elif [ "$ALLOW_PASSWORD_AUTH" = false ]; then
    print_warning "SSH now only allows public key authentication on port $SSH_PORT"
    print_warning "Make sure you have added your SSH key before logging out"
  else
    print_message "$COLOR_INFO" "SSH password authentication is enabled"
  fi
}

# Install Docker
install_docker() {
  print_section "10" "14" "Installing Docker"

  if [ "$SETUP_DOCKER" != true ]; then
    print_message "$COLOR_INFO" "Skipping Docker installation (--no-docker flag provided)"
    return
  fi

  if command_exists docker && command_exists docker-compose; then
    print_success "Docker is already installed"
    return
  fi

  print_message "$COLOR_INFO" "Installing Docker..."

  # Install Docker prerequisites
  sudo apt install -y \
    ca-certificates \
    gnupg \
    lsb-release

  # Add Docker's official GPG key
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  # Add Docker repository
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  # Install Docker
  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose

  # Add user to docker group
  sudo usermod -aG docker "$SETUP_USER"

  # Configure Docker daemon
  sudo mkdir -p /etc/docker
  echo '{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "features": {
    "buildkit": true
  },
  "experimental": false
}' | sudo tee /etc/docker/daemon.json > /dev/null

  # Configure Docker to host communication
  # Add host.docker.internal DNS entry to /etc/hosts if not already present
  if ! grep -q "host.docker.internal" /etc/hosts; then
    print_message "$COLOR_INFO" "Adding host.docker.internal to /etc/hosts..."
    echo "172.17.0.1 host.docker.internal" | sudo tee -a /etc/hosts > /dev/null
  fi

  # Ensure Docker starts on boot
  sudo systemctl enable docker
  sudo systemctl restart docker

  print_success "Docker installed"
  print_warning "Docker group permissions require a session restart to take effect"
  print_message "$COLOR_INFO" "To use Docker in the current session without logging out, run: newgrp docker"

  # Fix permissions for the current session if running as the target user
  if [ "$(whoami)" = "$SETUP_USER" ]; then
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
  print_section "11" "14" "Setting up Ignis project"

  # Create installation directory if it doesn't exist
  if [ ! -d "$INSTALLATION_DIR" ]; then
    sudo mkdir -p "$INSTALLATION_DIR"
    sudo chown "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR"
  fi

  # Clone repository if requested
  if [ "$CLONE_REPO" = true ]; then
    if [ ! -d "$INSTALLATION_DIR/.git" ]; then
      print_message "$COLOR_INFO" "Cloning repository from $GIT_REPO..."
      
      if [ "$(whoami)" = "$SETUP_USER" ]; then
        # Running as the target user
        git clone -b "$GIT_BRANCH" "$GIT_REPO" "$INSTALLATION_DIR"
      else
        # Running as another user, use sudo to run commands as the target user
        sudo -u "$SETUP_USER" git clone -b "$GIT_BRANCH" "$GIT_REPO" "$INSTALLATION_DIR"
      fi
      
      print_success "Repository cloned successfully"
    else
      print_message "$COLOR_INFO" "Repository already exists, pulling latest changes..."
      
      cd "$INSTALLATION_DIR"
      if [ "$(whoami)" = "$SETUP_USER" ]; then
        git checkout "$GIT_BRANCH"
        git pull
      else
        sudo -u "$SETUP_USER" git checkout "$GIT_BRANCH"
        sudo -u "$SETUP_USER" git pull
      fi
      
      print_success "Repository updated"
    fi
  else
    print_message "$COLOR_INFO" "Skipping repository clone (--no-clone flag provided)"
  fi

  # Create required directories
  mkdir -p "$INSTALLATION_DIR/logs/webhook"
  mkdir -p "$INSTALLATION_DIR/logs/deployments"
  mkdir -p "$INSTALLATION_DIR/logs/certs"
  mkdir -p "$INSTALLATION_DIR/proxy/certs"
  mkdir -p "$INSTALLATION_DIR/proxy/dynamic"
  mkdir -p "$INSTALLATION_DIR/deployments/service"
  
  # Create acme.json file if it doesn't exist
  if [ ! -e "$INSTALLATION_DIR/proxy/acme.json" ]; then
    print_message "$COLOR_INFO" "Creating acme.json file for Let's Encrypt certificates..."
    # Ensure it's created as a file, not a directory
    touch "$INSTALLATION_DIR/proxy/acme.json"
    chmod 600 "$INSTALLATION_DIR/proxy/acme.json"
    print_success "Created acme.json file with proper permissions"
  elif [ -d "$INSTALLATION_DIR/proxy/acme.json" ]; then
    # If it exists as a directory, fix it
    print_warning "acme.json exists as a directory instead of a file, fixing..."
    rm -rf "$INSTALLATION_DIR/proxy/acme.json"
    touch "$INSTALLATION_DIR/proxy/acme.json"
    chmod 600 "$INSTALLATION_DIR/proxy/acme.json"
    print_success "Fixed acme.json (converted from directory to file)"
  fi

  # Create .env file if it doesn't exist
  if [ ! -f "$INSTALLATION_DIR/.env" ]; then
    print_message "$COLOR_INFO" "Creating template .env file..."
    echo "WEBHOOK_SECRET=ignis_webhook_secret_$(date +%s | sha256sum | base64 | head -c 32)" > "$INSTALLATION_DIR/.env"
    echo "ENVIRONMENT=production" >> "$INSTALLATION_DIR/.env"
    echo "WEBHOOK_PORT=3333" >> "$INSTALLATION_DIR/.env"
    echo "WEBHOOK_HOST=0.0.0.0" >> "$INSTALLATION_DIR/.env"
    print_success "Created .env file with a random WEBHOOK_SECRET"
  fi

  # Set proper permissions
  sudo chown -R "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR"

  # Make sure script directories exist and have proper permissions
  if [ -d "$INSTALLATION_DIR/scripts" ]; then
    sudo chmod -R 755 "$INSTALLATION_DIR/scripts"
  fi

  if [ -d "$INSTALLATION_DIR/deployments/scripts" ]; then
    sudo chmod -R 755 "$INSTALLATION_DIR/deployments/scripts"
  fi

  print_success "Ignis project setup completed"
}

# Install and configure services
install_services() {
  print_section "12" "14" "Installing and configuring services"

  if [ "$INSTALL_SERVICES" != true ]; then
    print_message "$COLOR_INFO" "Skipping service installation (--no-install-services flag provided)"
    return
  fi

  # Find all service files
  local service_dir="$INSTALLATION_DIR/deployments/service"
  
  if [ -d "$service_dir" ]; then
    print_message "$COLOR_INFO" "Installing systemd services..."
    
    # Process each service file
    find "$service_dir" -name "*.service" -type f | while read -r src; do
      local service_name
      service_name=$(basename "$src" .service)
      local dst="/etc/systemd/system/${service_name}.service"
      
      print_message "$COLOR_INFO" "Installing service: $service_name"
      sudo cp "$src" "$dst"
      sudo systemctl daemon-reload
      sudo systemctl enable "$service_name"
    done
    
    # Start services if requested
    if [ "$START_SERVICES" = true ]; then
      print_message "$COLOR_INFO" "Starting services..."
      
      # Start ignis-startup service which should handle other services
      if systemctl list-unit-files | grep -q "ignis-startup.service"; then
        sudo systemctl start ignis-startup.service
        print_success "Started ignis-startup service"
      else
        # Start each service individually if ignis-startup doesn't exist
        find "$service_dir" -name "*.service" -type f | while read -r src; do
          local service_name
          service_name=$(basename "$src" .service)
          print_message "$COLOR_INFO" "Starting service: $service_name"
          sudo systemctl start "$service_name"
        done
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
  print_section "13" "14" "Configuring permissions"

  print_message "$COLOR_INFO" "Setting up file permissions..."

  # Set proper permissions for log directories
  sudo chown -R "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR/logs"
  sudo chmod -R 775 "$INSTALLATION_DIR/logs"

  # Set proper permissions for proxy directories
  sudo chown -R "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR/proxy"
  sudo chmod -R 775 "$INSTALLATION_DIR/proxy"

  # Set proper permissions for deployments directories
  sudo chown -R "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR/deployments"
  sudo chmod -R 775 "$INSTALLATION_DIR/deployments"

  # Set proper permissions for acme.json
  sudo chown "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR/proxy/acme.json"
  sudo chmod 600 "$INSTALLATION_DIR/proxy/acme.json"

  # Set proper permissions for .env file
  sudo chown "$SETUP_USER:$SETUP_USER" "$INSTALLATION_DIR/.env"
  sudo chmod 600 "$INSTALLATION_DIR/.env"

  print_success "File permissions setup completed"
}

# Verify installation and permissions
verify_installation() {
  print_section "14" "14" "Verifying installation"

  print_message "$COLOR_INFO" "Performing final verification checks..."
  
  # Check systemd services for NoNewPrivileges
  local services_with_issues=()
  for service_file in /etc/systemd/system/ignis-*.service; do
    if [ -f "$service_file" ] && grep -q "NoNewPrivileges=true" "$service_file"; then
      services_with_issues+=("$service_file")
    fi
  done
  
  if [ ${#services_with_issues[@]} -gt 0 ]; then
    print_warning "Some services still have NoNewPrivileges=true:"
    for service in "${services_with_issues[@]}"; do
      print_message "$COLOR_WARNING" "  - $(basename "$service")"
    done
  else
    print_success "All systemd services have correct NoNewPrivileges setting"
  fi
  
  # Check Docker socket permissions
  if [ -S "/var/run/docker.sock" ]; then
    local socket_perms=$(stat -c "%a" /var/run/docker.sock)
    if [ "$socket_perms" = "666" ] || [ "$socket_perms" = "660" ]; then
      print_success "Docker socket has correct permissions"
    else
      print_warning "Docker socket has incorrect permissions: $socket_perms (should be 666 or 660)"
    fi
  fi
  
  # Check if user is in docker group
  if groups "$SETUP_USER" | grep -q docker; then
    print_success "$SETUP_USER is in the docker group"
  else
    print_warning "$SETUP_USER is not in the docker group"
  fi
  
  print_success "Verification completed"
}

# Generate system summary
generate_summary() {
  print_message "$COLOR_TITLE" "=== IGNIS SYSTEM SUMMARY ==="

  # Check versions
  echo -e "${COLOR_INFO}Software Versions:${COLOR_RESET}"
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

  # Check services
  echo -e "${COLOR_INFO}Services Status:${COLOR_RESET}"
  echo -e "  Docker: $(systemctl is-active docker 2>/dev/null || echo "not installed")"
  
  # Check installed Ignis services
  if [ -d "/etc/systemd/system" ]; then
    echo -e "  Ignis Services:"
    systemctl list-units --type=service --all | grep "ignis" | while read -r line; do
      echo -e "    $line"
    done
  fi

  # Check Fail2Ban status
  if [ "$SETUP_FAIL2BAN" = true ]; then
    if systemctl is-active fail2ban.service >/dev/null 2>&1; then
      echo -e "  Fail2Ban: active"
    else
      echo -e "  Fail2Ban: inactive (optional security feature)"
    fi
  else
    echo -e "  Fail2Ban: not configured (optional security feature)"
  fi

  # Check firewall status
  if [ "$USE_IPTABLES" = true ]; then
    echo -e "${COLOR_INFO}Firewall Status (iptables):${COLOR_RESET}"
    sudo iptables -L -n | grep -E "Chain|ACCEPT|DROP" | head -n 10
  else
    echo -e "${COLOR_INFO}Firewall Status (UFW):${COLOR_RESET}"
    if sudo ufw status | grep -q "Status: active"; then
      echo -e "  UFW: active"
      sudo ufw status | grep -v "(v6)" | head -n 10
    else
      echo -e "  UFW: inactive"
    fi
  fi

  # Installation details
  echo -e "${COLOR_INFO}Installation Details:${COLOR_RESET}"
  echo -e "  Installation Directory: $INSTALLATION_DIR"
  echo -e "  System User: $SETUP_USER"
  echo -e "  SSH Port: $SSH_PORT"
  echo -e "  Password Authentication: $([ "$ALLOW_PASSWORD_AUTH" = true ] && echo "Enabled" || echo "Disabled")"
  echo -e "  TCP Forwarding: $([ "$ALLOW_TCP_FORWARDING" = true ] && echo "Enabled" || echo "Disabled")"
  echo -e "  Logging to File: $([ "$LOG_TO_FILE" = true ] && echo "Enabled ($LOG_FILE)" || echo "Disabled")"

  # Docker permissions reminder
  if command_exists docker; then
    echo -e "${COLOR_WARNING}Docker Permissions:${COLOR_RESET}"
    echo -e "  If you encounter 'permission denied' errors with Docker commands, run:"
    echo -e "  $ newgrp docker"
    echo -e "  Or log out and log back in to apply group changes."
  fi

  # Next steps
  echo -e "${COLOR_WARNING}Next Steps:${COLOR_RESET}"
  if [ "$ALLOW_PASSWORD_AUTH" = true ] && [ "$USER_CREATED" = true ]; then
    echo -e "  1. SSH access command: ssh $SETUP_USER@your-server -p $SSH_PORT"
    echo -e "  2. Default password: ignis123 (change it immediately after login)"
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
  
  # Final verification step
  verify_installation

  # Generate summary
  generate_summary
}

# Execute main function with all arguments
main "$@"
