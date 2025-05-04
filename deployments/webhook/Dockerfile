FROM oven/bun:1.0

WORKDIR /app

# Instalar dependencias del sistema, Docker CLI y Docker Compose
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Copy package.json and install dependencies
COPY package.json .
RUN bun install

# Copy the server code and scripts
COPY server.ts .
COPY tsconfig.json .

# Create necessary directories
RUN mkdir -p logs/webhook logs/deployments

# Expose the webhook port
EXPOSE 3333

# Run the webhook server
CMD ["bun", "run", "server.ts"]
