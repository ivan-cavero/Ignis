#!/bin/bash
set -e

# Colors for output
GREEN="\033[1;32m"
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

ADMIN_USER="ignis"
PROJECT_NAME="Ignis"
REPO_URL="https://github.com/ivan-cavero/Ignis"
PROJECT_DIR="/home/$ADMIN_USER/$PROJECT_NAME"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ This script is for root. Use 'sudo ./init-ignis-base.sh'${RESET}"
  exit 1
fi

echo -e "${CYAN}🔧 [1/4] Creating user '$ADMIN_USER'...${RESET}"

# Create user if it doesn't exist
if id "$ADMIN_USER" &>/dev/null; then
  echo -e "${YELLOW}⚠️ User '$ADMIN_USER' already exists. Skipping creation.${RESET}"
else
  adduser $ADMIN_USER
  usermod -aG sudo $ADMIN_USER
  echo -e "${GREEN}✔ User '$ADMIN_USER' created and added to sudo group.${RESET}"
fi

echo -e "${CYAN}🔐 [2/4] Setting up SSH for '$ADMIN_USER'...${RESET}"

# Setup SSH directory
mkdir -p /home/$ADMIN_USER/.ssh
chmod 700 /home/$ADMIN_USER/.ssh
touch /home/$ADMIN_USER/.ssh/authorized_keys
chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys
chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.ssh

echo -e "${CYAN}📦 [3/4] Cloning project repository...${RESET}"

if ! command -v git &>/dev/null; then
  echo -e "${YELLOW}🔍 Git is not installed. Installing Git...${RESET}"
  apt update -y
  apt install -y git
  echo -e "${GREEN}✔️ Git installed.${RESET}"
fi

# Clone repository if not already present
if [ -d "$PROJECT_DIR" ]; then
  echo -e "${YELLOW}⚠️ Project directory already exists. Skipping clone.${RESET}"
else
  su - $ADMIN_USER -c "git clone $REPO_URL $PROJECT_DIR"
  echo -e "${GREEN}✔ Repository cloned to $PROJECT_DIR.${RESET}"
fi

echo -e "${CYAN}🔧 [4/4] Setting permissions for project directory...${RESET}"

# Set ownership
chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER

echo -e "${GREEN}✅ Base setup complete. Please switch to user '$ADMIN_USER' and run 'init-ignis.sh'.${RESET}"
echo -e "${CYAN}👉 To switch to the 'ignis' user, run:${RESET}"
echo -e "${YELLOW}   su - ignis${RESET}"
