# 🔥 Ignis Backend

Backend service for the Ignis platform, built with Hono and Bun. This is a modern, fast, and scalable backend service designed to power the Ignis platform.

## 🏗️ Project Structure

```
backend/
├── src/
│   ├── __tests__/     # Test files
│   ├── config/        # Configuration and environment variables
│   ├── controllers/   # Request handlers
│   ├── middleware/    # Custom middleware (auth, logging, etc.)
│   ├── models/        # Database models and schemas
│   ├── routes/        # Route definitions
│   ├── services/      # Business logic
│   ├── types/         # TypeScript type definitions
│   ├── utils/         # Utility functions and helpers
│   └── index.ts       # Application entry point
├── .dockerignore      # Files to ignore in Docker builds
├── .env.example       # Example environment variables
├── docker-compose.yml # Docker Compose configuration
├── Dockerfile         # Production Dockerfile
├── package.json       # Project dependencies and scripts
└── tsconfig.json     # TypeScript configuration
```

## 🚀 Prerequisites

- [Bun](https://bun.sh/) (v1.0.0 or later)
- [Docker](https://www.docker.com/) (for containerization)
- [Node.js](https://nodejs.org/) (v18 or later, if not using Bun)

## 🛠️ Getting Started

1. **Clone the repository**
   ```bash
   git clone https://github.com/your-username/ignis-backend.git
   cd ignis-backend
   ```

2. **Install dependencies**
   ```bash
   # Using Bun (recommended)
   bun install
   ```

3. **Set up environment variables**
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

4. **Start the development server**
   ```bash
   bun run dev
   ```

   The server will be available at `http://localhost:3000`

## 🧪 Running Tests

```bash
# Run all tests
bun test

# Run tests in watch mode
bun test --watch

# Run specific test file
bun test src/__tests__/app.test.ts
```

## 🐳 Docker Development

### Using Docker Compose (Recommended)

```bash
# Start all services in detached mode
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

### Building the Docker Image

```bash
# Build the image
docker build -t ignis-backend .

# Run the container
docker run -p 3000:3000 ignis-backend
```

## 🔧 Environment Variables

Copy `.env.example` to `.env` and update the values:

```env
# Server Configuration
NODE_ENV=development
PORT=3000
HOST=0.0.0.0

# Database (example)
# DATABASE_URL=postgresql://user:password@localhost:5432/ignis

# Authentication (example)
# JWT_SECRET=your_jwt_secret
# JWT_EXPIRES_IN=1d

# CORS (example)
# ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173
```

## 📚 API Documentation

API documentation is available at `/docs` when running in development mode.

## 🏗️ Project Structure Details

- **`src/config/`**: Configuration files, environment variables, and constants.
- **`src/controllers/`**: Request handlers that process incoming requests.
- **`src/middleware/`**: Custom middleware for authentication, logging, etc.
- **`src/models/`**: Database models and schemas.
- **`src/routes/`**: Route definitions that map URLs to controllers.
- **`src/services/`**: Business logic and external service integrations.
- **`src/types/`**: TypeScript type definitions.
- **`src/utils/`**: Utility functions and helpers.

## 🤝 Contributing

1. Fork the repository
2. Create a new branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [Hono](https://hono.dev/) - Fast, lightweight web framework
- [Bun](https://bun.sh/) - Fast JavaScript runtime
- [TypeScript](https://www.typescriptlang.org/) - Type-safe JavaScript
- [Docker](https://www.docker.com/) - Containerization platform
