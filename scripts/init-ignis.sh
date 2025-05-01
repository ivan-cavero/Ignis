#!/bin/bash
set -e

# === Colors ===
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

# === Variables ===
ADMIN_USER="ignis"
PROJECT_DIR="/home/$ADMIN_USER/Ignis"
ENV_FILE="$PROJECT_DIR/.env"
WEBHOOK_SERVICE="/etc/systemd/system/ignis-webhook.service"

echo -e "${CYAN}🔧 [1/9] Creating user and securing SSH...${RESET}"
adduser --disabled-password --gecos "" $ADMIN_USER
usermod -aG sudo $ADMIN_USER
mkdir -p /home/$ADMIN_USER/.ssh
cp /root/.ssh/authorized_keys /home/$ADMIN_USER/.ssh/
chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.ssh
chmod 700 /home/$ADMIN_USER/.ssh
chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload sshd

echo -e "${CYAN}🛡️ [2/9] Configuring firewall and fail2ban...${RESET}"
apt update -y
apt install -y ufw fail2ban
ufw allow 2222/tcp
ufw allow http
ufw allow https
ufw --force enable

echo -e "${CYAN}🐳 [3/9] Installing Docker...${RESET}"
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  unzip \
  git \
  software-properties-common

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker $ADMIN_USER

echo -e "${CYAN}☕ [4/9] Installing Java, NVM, Node LTS...${RESET}"
apt install -y openjdk-17-jre-headless

su - $ADMIN_USER -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash'
echo 'export NVM_DIR="$HOME/.nvm"' >> /home/$ADMIN_USER/.bashrc
echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /home/$ADMIN_USER/.bashrc
su - $ADMIN_USER -c 'source ~/.bashrc && nvm install --lts && nvm use --lts && nvm alias default lts/*'

echo -e "${CYAN}🍞 [5/9] Installing Bun...${RESET}"
su - $ADMIN_USER -c 'curl -fsSL https://bun.sh/install | bash'
ln -sf /home/$ADMIN_USER/.bun/bin/bun /usr/local/bin/bun

echo -e "${CYAN}🔐 [6/9] Setting file and folder permissions...${RESET}"
# Project-wide permissions
chown -R $ADMIN_USER:$ADMIN_USER $PROJECT_DIR

# Executable scripts
chmod +x $PROJECT_DIR/scripts/*.sh
chmod +x $PROJECT_DIR/scripts/webhook-server.ts

# Secure files
chmod 600 $PROJECT_DIR/proxy/acme.json
chmod 644 $PROJECT_DIR/proxy/traefik.yml
chmod 644 $PROJECT_DIR/proxy/dynamic/*.yml

# Docker Compose
chmod 644 $PROJECT_DIR/docker-compose.yml

echo -e "${CYAN}🧰 [7/9] Creating and enabling systemd webhook service...${RESET}"
cp $PROJECT_DIR/ignis-webhook.service $WEBHOOK_SERVICE
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable ignis-webhook.service
systemctl start ignis-webhook.service

echo -e "${CYAN}🐋 [8/9] Starting Docker containers...${RESET}"
cd $PROJECT_DIR
docker compose up -d

echo -e "${CYAN}📋 [9/9] Verifying services...${RESET}"

# Docker containers
docker_status=$(docker ps --format "{{.Names}}" | grep -E 'traefik|backend|admin|user')
if [ -n "$docker_status" ]; then
  echo -e "${GREEN}✔ Docker containers running:${RESET}"
  echo "$docker_status"
else
  echo -e "${RED}✖ Docker containers are not running properly${RESET}"
fi

# Systemd service
if systemctl is-active --quiet ignis-webhook.service; then
  echo -e "${GREEN}✔ Webhook service is active and running${RESET}"
else
  echo -e "${RED}✖ Webhook service is not running${RESET}"
fi

# Bun version
echo -e "${GREEN}✔ Bun version:$(bun --version)${RESET}"

# Node version
su - $ADMIN_USER -c 'source ~/.bashrc && node -v && npm -v'

echo -e "\n${YELLOW}⚠️ Reminder:${RESET} Ensure .env exists with WEBHOOK_SECRET and certs at /etc/letsencrypt/live/"
echo -e "${GREEN}✅ Setup complete. Your Ignis deployment is ready!${RESET}"
