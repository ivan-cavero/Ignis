#!/bin/bash
# Script de diagnóstico para el webhook de Ignis
# Verifica la conectividad y configuración del webhook

echo "=== Diagnóstico del Webhook de Ignis ==="
echo "Fecha: $(date)"
echo

# Verificar si el proceso está en ejecución
echo "=== Verificando proceso del webhook ==="
if pgrep -f "bun run server.ts" > /dev/null; then
  echo "✅ El proceso del webhook está en ejecución"
  PID=$(pgrep -f "bun run server.ts")
  echo "   PID: $PID"
else
  echo "❌ El proceso del webhook NO está en ejecución"
fi
echo

# Verificar puertos en escucha
echo "=== Verificando puertos en escucha ==="
if command -v ss > /dev/null; then
  echo "Puertos TCP en escucha:"
  ss -tlnp | grep 3333 || echo "❌ No se encontró ningún proceso escuchando en el puerto 3333"
elif command -v netstat > /dev/null; then
  echo "Puertos TCP en escucha:"
  netstat -tlnp | grep 3333 || echo "❌ No se encontró ningún proceso escuchando en el puerto 3333"
else
  echo "❌ No se encontraron herramientas para verificar puertos (ss o netstat)"
fi
echo

# Verificar conectividad local
echo "=== Verificando conectividad local ==="
if curl -s http://localhost:3333/health > /dev/null; then
  echo "✅ El servidor responde localmente en http://localhost:3333/health"
  echo "   Respuesta: $(curl -s http://localhost:3333/health)"
else
  echo "❌ El servidor NO responde localmente en http://localhost:3333/health"
fi
echo

# Verificar conectividad desde Traefik
echo "=== Verificando conectividad desde Traefik ==="
if docker exec traefik curl -s http://host.docker.internal:3333/health > /dev/null 2>&1; then
  echo "✅ Traefik puede conectarse al webhook usando host.docker.internal"
  echo "   Respuesta: $(docker exec traefik curl -s http://host.docker.internal:3333/health)"
elif docker exec traefik curl -s http://localhost:3333/health > /dev/null 2>&1; then
  echo "✅ Traefik puede conectarse al webhook usando localhost"
  echo "   Respuesta: $(docker exec traefik curl -s http://localhost:3333/health)"
else
  echo "❌ Traefik NO puede conectarse al webhook"
fi
echo

# Verificar configuración de Traefik
echo "=== Verificando configuración de Traefik ==="
if [ -f "/opt/ignis/proxy/dynamic/webhook.yml" ]; then
  echo "✅ El archivo de configuración del webhook existe"
  echo "   Contenido:"
  cat "/opt/ignis/proxy/dynamic/webhook.yml"
else
  echo "❌ El archivo de configuración del webhook NO existe"
fi
echo

# Verificar logs del webhook
echo "=== Verificando logs del webhook ==="
LOG_FILE="/opt/ignis/logs/webhook/webhook-$(date +%Y%m%d).log"
if [ -f "$LOG_FILE" ]; then
  echo "✅ El archivo de log del webhook existe"
  echo "   Últimas 10 líneas:"
  tail -n 10 "$LOG_FILE"
else
  echo "❌ El archivo de log del webhook NO existe"
fi
echo

# Verificar certificados SSL
echo "=== Verificando certificados SSL ==="
CERT_FILE="/opt/ignis/proxy/certs/webhook.ivancavero.com.crt"
KEY_FILE="/opt/ignis/proxy/certs/webhook.ivancavero.com.key"
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  echo "✅ Los certificados SSL existen"
  echo "   Certificado: $CERT_FILE"
  echo "   Clave: $KEY_FILE"
  echo "   Información del certificado:"
  openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates || echo "   No se pudo leer la información del certificado"
else
  echo "❌ Los certificados SSL NO existen"
fi
echo

echo "=== Fin del diagnóstico ==="
