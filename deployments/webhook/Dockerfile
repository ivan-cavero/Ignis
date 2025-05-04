FROM oven/bun:1.0

WORKDIR /app

# Copy package.json and install dependencies
COPY package.json .
RUN bun install

# Copy the server code and scripts
COPY server.ts .
COPY tsconfig.json .

# Copy deployment scripts to the expected location
COPY ../scripts /app/deployments/scripts

# Create necessary directories
RUN mkdir -p logs/webhook

# Expose the webhook port
EXPOSE 3333

# Run the webhook server
CMD ["bun", "run", "server.ts"]