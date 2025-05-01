#!/bin/bash
set -e

cd /home/ignis/Ignis

echo "🚀 Detecting changes..."
changed=$(git diff --name-only HEAD~1 HEAD)

if echo "$changed" | grep -q '^backend/'; then
  echo "🔁 Rebuilding backend..."
  docker compose build backend
  docker compose up -d backend
fi

if echo "$changed" | grep -q '^frontend/user/'; then
  echo "🔁 Rebuilding user frontend..."
  docker compose build user-frontend
  docker compose up -d user-frontend
fi

if echo "$changed" | grep -q '^frontend/admin/'; then
  echo "🔁 Rebuilding admin frontend..."
  docker compose build admin-frontend
  docker compose up -d admin-frontend
fi

if echo "$changed" | grep -q '^proxy/\|^docker-compose.yml'; then
  echo "⚙️ Infrastructure updated, reloading Traefik..."
  docker compose up -d traefik
fi

echo "✅ Deployment completed."
