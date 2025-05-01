#!/bin/bash
set -e

# Colors for output
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

PROJECT_DIR="$HOME/Ignis"
WEBHOOK_SERVICE="/etc/systemd/system/ignis-webhook.service"

if [ "$(id -un)" != "ignis" ]; then
  echo -e "${RED}❌ Use user 'ignis'. Use 'su - ignis' to change user.${RESET}"
  exit 1
fi

echo -e "${CYAN}☕ [1/9] Installing Java, NVM, Node.js LTS...${RESET}"

# Install Java
sudo apt update -y
sudo apt install -y openjdk-17-jre-headless

# Install NVM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash

# Load NVM and install Node.js LTS
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install --lts
nvm use --lts
nvm alias default lts/*

# Symlink node and npm
sudo ln -sf "$NVM_DIR/versions/node/$(nvm version)/bin/node" /usr/local/bin/node
sudo ln -sf "$NVM_DIR/versions/node/$(nvm version)/bin/npm" /usr/local/bin/npm

echo -e "${CYAN}🍞 [2/9] Installing Bun...${RESET}"

# Install Bun
curl -fsSL https://bun.sh/install | bash

# Symlink Bun
sudo ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun

echo -e "${CYAN}🛡️ [3/9] Configuring firewall and Fail2Ban...${RESET}"

# Install UFW and Fail2Ban
sudo apt install -y ufw fail2ban

# Configure UFW
sudo ufw allow 2222/tcp
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

echo -e "${CYAN}🐳 [4/9] Installing Docker...${RESET}"

# Install Docker
sudo apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  unzip \
  git \
  software-properties-common

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian \
$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update -y
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER

echo -e "${CYAN}🔐 [5/9] Setting file and folder permissions...${RESET}"

# Set permissions for project directory
chmod +x $PROJECT_DIR/scripts/*.sh
chmod +x $PROJECT_DIR/scripts/webhook-server.ts
chmod 600 $PROJECT_DIR/proxy/acme.json
chmod 644 $PROJECT_DIR/proxy/traefik.yml
chmod 644 $PROJECT_DIR/proxy/dynamic/*.yml
chmod 644 $PROJECT_DIR/docker-compose.yml

echo -e "${CYAN}🧰 [6/9] Creating and enabling systemd webhook service...${RESET}"

# Copy systemd service file
sudo cp $PROJECT_DIR/ignis-webhook.service $WEBHOOK_SERVICE
sudo systemctl daemon-reload
sudo systemctl enable ignis-webhook.service
sudo systemctl start ignis-webhook.service

echo -e "${CYAN}🐋 [7/9] Starting Docker containers...${RESET}"

# Start Docker containers
cd $PROJECT_DIR
docker compose up -d

echo -e "${CYAN}📋 [8/9] Verifying services...${RESET}"

# Check Docker containers
docker_status=$(docker ps --format "{{.Names}}" | grep -E 'traefik|backend|admin|user')
if [ -n "$docker_status" ]; then
  echo -e "${GREEN}✔ Docker containers running:${RESET}"
  echo "$docker_status"
else
  echo -e "${RED}✖ Docker containers are not running properly${RESET}"
fi

# Check systemd service
if systemctl is-active --quiet ignis-webhook.service; then
  echo -e "${GREEN}✔ Webhook service is active and running${RESET}"
else
  echo -e "${RED}✖ Webhook service is not running${RESET}"
fi

# Check Bun version
echo -e "${GREEN}✔ Bun version:$(bun --version)${RESET}"

# Check Node.js and npm versions
node -v
npm -v

echo -e "\n${YELLOW}⚠️ Reminder:${RESET} Ensure .env exists with WEBHOOK_SECRET and certs at /etc/letsencrypt/live/"
echo -e "${GREEN}✅ Setup complete. Your Ignis deployment is ready!${RESET}"
