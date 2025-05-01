#!/bin/bash

# init-ignis.sh - Initial setup for Ignis project on Debian 12

set -e

echo "🔧 Starting Ignis initial setup..."

# 1. Update and upgrade system packages
echo "📦 Updating system packages..."
apt update && apt upgrade -y

# 2. Install essential packages
echo "📥 Installing essential packages..."
apt install -y sudo curl git ufw fail2ban vim htop unzip gnupg ca-certificates lsb-release software-properties-common

# 3. Create a new sudo user
read -p "Enter the username for the new admin user: " ADMIN_USER
adduser $ADMIN_USER
usermod -aG sudo $ADMIN_USER

# 4. Set up SSH key authentication for the new user
echo "🔐 Setting up SSH key authentication..."
mkdir -p /home/$ADMIN_USER/.ssh

if [ -f /root/.ssh/authorized_keys ]; then
  echo "📋 Copying root authorized_keys to new user..."
  cp /root/.ssh/authorized_keys /home/$ADMIN_USER/.ssh/
else
  echo "⚠️  No authorized_keys found in /root/.ssh/. Leaving new user's .ssh folder empty."
  touch /home/$ADMIN_USER/.ssh/authorized_keys
fi

chown -R $ADMIN_USER:$ADMIN_USER /home/$ADMIN_USER/.ssh
chmod 700 /home/$ADMIN_USER/.ssh
chmod 600 /home/$ADMIN_USER/.ssh/authorized_keys

# 5. Configure SSH daemon
echo "🛡️ Configuring SSH daemon..."
NEW_SSH_PORT=2222
echo -e "Port $NEW_SSH_PORT\nPermitRootLogin no\nPasswordAuthentication no" > /etc/ssh/sshd_config.d/ignis.conf
systemctl restart ssh

# 6. Configure UFW firewall
echo "🔥 Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow $NEW_SSH_PORT/tcp
ufw allow http
ufw allow https
ufw --force enable

# 7. Configure Fail2Ban
echo "🚫 Configuring Fail2Ban..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sed -i 's/^bantime  = .*$/bantime  = 1h/' /etc/fail2ban/jail.local
sed -i 's/^findtime  = .*$/findtime  = 10m/' /etc/fail2ban/jail.local
sed -i 's/^maxretry = .*$/maxretry = 5/' /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban

# 8. Install Docker
echo "🐳 Installing Docker..."
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update
apt install -y docker-ce docker-ce-cli containerd.io
usermod -aG docker $ADMIN_USER
systemctl enable docker
systemctl start docker

# 9. Install Docker Compose
echo "🔧 Installing Docker Compose..."
DOCKER_COMPOSE_VERSION="2.20.2"
curl -L "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 10. Install Node Version Manager (NVM) and Node.js LTS
echo "🟢 Installing NVM and Node.js LTS..."
su - $ADMIN_USER -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.3/install.sh | bash"
su - $ADMIN_USER -c "source ~/.nvm/nvm.sh && nvm install --lts && nvm use --lts && nvm alias default 'lts/*'"

# 11. Install Bun
echo "🍞 Installing Bun..."
su - $ADMIN_USER -c "curl -fsSL https://bun.sh/install | bash"

# 12. Install OpenJDK 21 (LTS)
echo "☕ Installing OpenJDK 21..."
apt install -y openjdk-21-jdk

# 13. Final verification
echo "✅ Verifying installations..."

echo "Docker version:"
docker --version

echo "Docker Compose version:"
docker-compose --version

echo "Node.js version:"
su - $ADMIN_USER -c "source ~/.nvm/nvm.sh && node -v"

echo "Bun version:"
su - $ADMIN_USER -c "~/.bun/bin/bun -v"

echo "Java version:"
java -version

echo "SSH is now configured to use port $NEW_SSH_PORT."
echo "Please ensure your firewall allows connections on this port."

echo "🎉 Ignis initial setup completed successfully!"
