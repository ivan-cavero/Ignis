FROM oven/bun:1.0

WORKDIR /app

# Install minimal required dependencies
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy package.json and install dependencies
COPY package.json .
RUN bun install

# Copy the server code and scripts
COPY server.ts .
COPY tsconfig.json .

# Create necessary directories
RUN mkdir -p logs/webhook

# Expose the webhook port
EXPOSE 3333

# Run the webhook server
CMD ["bun", "run", "server.ts"]
