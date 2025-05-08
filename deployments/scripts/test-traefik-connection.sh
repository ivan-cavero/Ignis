#!/bin/bash
# Script para probar la conectividad desde Traefik al webhook

echo "=== Prueba de conectividad desde Traefik al webhook ==="
echo "Fecha: $(date)"
echo

# Obtener la IP del host en la red Docker
HOST_IP=$(ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [ -z "$HOST_IP" ]; then
  echo "❌ No se pudo determinar la IP del host en la red Docker"
  HOST_IP="172.17.0.1"  # IP por defecto de la red Docker bridge
  echo "   Usando IP por defecto: $HOST_IP"
else
  echo "✅ IP del host en la red Docker: $HOST_IP"
fi

# Actualizar la configuración de Traefik
CONFIG_FILE="/opt/ignis/proxy/dynamic/webhook.yml"
if [ -f "$CONFIG_FILE" ]; then
  echo "✅ Actualizando la configuración de Traefik"
  # Hacer una copia de seguridad
  cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
  
  # Actualizar la URL del servidor
  sed -i "s|url: \"http://[^\"]*\"|url: \"http://${HOST_IP}:3333\"|" "$CONFIG_FILE"
  
  echo "   Nueva configuración:"
  cat "$CONFIG_FILE"
else
  echo "❌ No se encontró el archivo de configuración de Traefik"
fi

# Probar la conectividad desde Traefik
echo
echo "=== Probando conectividad desde Traefik ==="
if docker exec traefik curl -s "http://${HOST_IP}:3333/health" > /dev/null 2>&1; then
  echo "✅ Traefik puede conectarse al webhook usando ${HOST_IP}"
  echo "   Respuesta: $(docker exec traefik curl -s "http://${HOST_IP}:3333/health")"
else
  echo "❌ Traefik NO puede conectarse al webhook usando ${HOST_IP}"
  
  # Probar con diferentes IPs
  echo
  echo "=== Probando con diferentes IPs ==="
  
  # Obtener todas las IPs del host
  echo "IPs del host:"
  ip -4 addr | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | while read -r IP; do
    echo "   Probando $IP..."
    if docker exec traefik curl -s "http://${IP}:3333/health" --connect-timeout 2 > /dev/null 2>&1; then
      echo "   ✅ Traefik puede conectarse al webhook usando $IP"
      echo "      Respuesta: $(docker exec traefik curl -s "http://${IP}:3333/health")"
      
      # Actualizar la configuración con esta IP
      sed -i "s|url: \"http://[^\"]*\"|url: \"http://${IP}:3333\"|" "$CONFIG_FILE"
      echo "      Configuración actualizada con $IP"
      break
    else
      echo "   ❌ Traefik NO puede conectarse al webhook usando $IP"
    fi
  done
fi

echo
echo "=== Reiniciando Traefik ==="
docker restart traefik
echo "✅ Traefik reiniciado"

echo
echo "=== Fin de la prueba ==="
