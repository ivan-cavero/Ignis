# Stage 1: Base image
FROM oven/bun:1-slim AS base
WORKDIR /usr/src/app

# Stage 2: Install dependencies
FROM base AS install
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

# Stage 3: Build the application
FROM base AS build
COPY --from=install /usr/src/app/node_modules ./node_modules
COPY . .
# Uncomment and configure if you have a build step
# RUN bun run build

# Stage 4: Production image
FROM base AS production
ENV NODE_ENV=production

# Install production dependencies
COPY --from=install /usr/src/app/node_modules ./node_modules

# Copy built application
COPY --from=build /usr/src/app/src ./src
COPY --from=build /usr/src/app/package.json ./
COPY --from=build /usr/src/app/tsconfig.json ./

# Run as non-root user for security
RUN chown -R bun:bun /usr/src/app
USER bun

# Expose the port the app runs on
EXPOSE 3000

# Command to run the application
CMD ["bun", "run", "src/index.ts"]
