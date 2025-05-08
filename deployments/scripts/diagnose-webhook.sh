#!/bin/bash
# Script de diagnóstico para el webhook de Ignis
# Identifica y soluciona problemas comunes

# Colores para salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Diagnóstico del Webhook de Ignis ===${NC}"

# Verificar estructura de directorios
echo -e "\n${BLUE}Verificando estructura de directorios...${NC}"
DIRS_TO_CHECK=(
  "/opt/ignis/deployments/webhook"
  "/opt/ignis/logs/webhook"
)

for dir in "${DIRS_TO_CHECK[@]}"; do
  if [ -d "$dir" ]; then
    echo -e "${GREEN}✓ Directorio $dir existe${NC}"
  else
    echo -e "${RED}✗ Directorio $dir no existe${NC}"
    echo -e "${YELLOW}Creando directorio $dir...${NC}"
    mkdir -p "$dir"
  fi
done

# Verificar archivos necesarios
echo -e "\n${BLUE}Verificando archivos necesarios...${NC}"
FILES_TO_CHECK=(
  "/opt/ignis/deployments/webhook/server.ts"
  "/opt/ignis/deployments/webhook/logger.ts"
  "/opt/ignis/deployments/scripts/deploy.sh"
  "/etc/systemd/system/ignis-webhook.service"
)

for file in "${FILES_TO_CHECK[@]}"; do
  if [ -f "$file" ]; then
    echo -e "${GREEN}✓ Archivo $file existe${NC}"
  else
    echo -e "${RED}✗ Archivo $file no existe${NC}"
  fi
done

# Verificar permisos
echo -e "\n${BLUE}Verificando permisos...${NC}"
if id "ignis" &>/dev/null; then
  echo -e "${GREEN}✓ Usuario ignis existe${NC}"
  
  # Verificar permisos de directorios
  for dir in "${DIRS_TO_CHECK[@]}"; do
    if [ -d "$dir" ]; then
      if sudo -u ignis [ -r "$dir" ] && sudo -u ignis [ -w "$dir" ]; then
        echo -e "${GREEN}✓ Usuario ignis tiene permisos en $dir${NC}"
      else
        echo -e "${RED}✗ Usuario ignis no tiene permisos en $dir${NC}"
        echo -e "${YELLOW}Corrigiendo permisos...${NC}"
        chown -R ignis:ignis "$dir"
        chmod -R 755 "$dir"
      fi
    fi
  done
else
  echo -e "${RED}✗ Usuario ignis no existe${NC}"
fi

# Verificar Bun
echo -e "\n${BLUE}Verificando instalación de Bun...${NC}"
if command -v bun &> /dev/null; then
  BUN_VERSION=$(bun --version)
  echo -e "${GREEN}✓ Bun está instalado (versión $BUN_VERSION)${NC}"
  
  # Verificar si el usuario ignis puede ejecutar bun
  if sudo -u ignis command -v bun &> /dev/null; then
    echo -e "${GREEN}✓ Usuario ignis puede ejecutar bun${NC}"
  else
    echo -e "${RED}✗ Usuario ignis no puede ejecutar bun${NC}"
    echo -e "${YELLOW}Verificando PATH para usuario ignis...${NC}"
    IGNIS_PATH=$(sudo -u ignis echo $PATH)
    echo "PATH para ignis: $IGNIS_PATH"
  fi
else
  echo -e "${RED}✗ Bun no está instalado${NC}"
  echo -e "${YELLOW}Puedes instalar Bun con: curl -fsSL https://bun.sh/install | bash${NC}"
fi

# Verificar servicio systemd
echo -e "\n${BLUE}Verificando servicio systemd...${NC}"
if systemctl list-unit-files | grep -q ignis-webhook.service; then
  echo -e "${GREEN}✓ Servicio ignis-webhook.service está instalado${NC}"
  
  # Verificar estado del servicio
  if systemctl is-active --quiet ignis-webhook.service; then
    echo -e "${GREEN}✓ Servicio ignis-webhook está activo${NC}"
  else
    echo -e "${RED}✗ Servicio ignis-webhook no está activo${NC}"
    echo -e "${YELLOW}Estado del servicio:${NC}"
    systemctl status ignis-webhook.service --no-pager | head -n 15
  fi
else
  echo -e "${RED}✗ Servicio ignis-webhook.service no está instalado${NC}"
fi

# Verificar variables de entorno
echo -e "\n${BLUE}Verificando variables de entorno...${NC}"
if [ -f "/opt/ignis/.env" ]; then
  echo -e "${GREEN}✓ Archivo .env existe${NC}"
  
  # Verificar WEBHOOK_SECRET
  if grep -q "WEBHOOK_SECRET=" "/opt/ignis/.env"; then
    echo -e "${GREEN}✓ Variable WEBHOOK_SECRET está definida${NC}"
  else
    echo -e "${RED}✗ Variable WEBHOOK_SECRET no está definida${NC}"
    echo -e "${YELLOW}Generando WEBHOOK_SECRET...${NC}"
    echo "WEBHOOK_SECRET=ignis_webhook_secret_$(date +%s | sha256sum | base64 | head -c 32)" >> "/opt/ignis/.env"
  fi
else
  echo -e "${RED}✗ Archivo .env no existe${NC}"
fi

# Intentar reiniciar el servicio
echo -e "\n${BLUE}Intentando reiniciar el servicio...${NC}"
sudo systemctl daemon-reload
sudo systemctl restart ignis-webhook.service
sleep 2

if systemctl is-active --quiet ignis-webhook.service; then
  echo -e "${GREEN}✓ Servicio reiniciado correctamente${NC}"
else
  echo -e "${RED}✗ No se pudo reiniciar el servicio${NC}"
  echo -e "${YELLOW}Mostrando logs recientes:${NC}"
  journalctl -u ignis-webhook.service --no-pager -n 20
fi

echo -e "\n${BLUE}Diagnóstico completado.${NC}"