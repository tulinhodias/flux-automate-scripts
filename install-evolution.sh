#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Script Adicional: Evolution API
# Adiciona Evolution API a uma instalacao Flux existente
# Requisito: install-base.sh ja executado
# ============================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[FLUX]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[X]${NC} $1"; }

echo -e "${GREEN}"
echo "=============================================="
echo "     FLUX AUTOMATE - Evolution API            "
echo "        WhatsApp Nao Oficial                  "
echo "=============================================="
echo -e "${NC}"

EVOLUTION_HOST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --evolution) EVOLUTION_HOST="$2"; shift 2 ;;
        *) print_error "Argumento desconhecido: $1"; exit 1 ;;
    esac
done

if [ -z "$EVOLUTION_HOST" ]; then
    print_error "Argumento obrigatorio faltando!"
    echo "Uso: bash install-evolution.sh --evolution evolution.seudominio.com"
    exit 1
fi

# Verificar instalacao base
print_step "Verificando instalacao base..."
if [ ! -f /opt/flux/docker-compose.yml ] || ! docker network inspect flux_network &>/dev/null; then
    print_error "Instalacao base nao encontrada! Execute primeiro o install-base.sh"
    exit 1
fi
print_success "Instalacao base encontrada"

# Carregar .env existente
print_step "Carregando configuracoes..."
source /opt/flux/.env
print_success "Configuracoes carregadas"

EVOLUTION_API_KEY=$(openssl rand -hex 24)

# Adicionar ao .env
cat >> /opt/flux/.env << ENVEOF

# Evolution API
EVOLUTION_HOST=${EVOLUTION_HOST}
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
ENVEOF

mkdir -p /opt/flux/evolution

# Criar docker-compose da Evolution
print_step "Criando docker-compose da Evolution..."

cat > /opt/flux/docker-compose.evolution.yml << 'COMPOSEEOF'
services:

  evolution:
    image: atendai/evolution-api:latest
    container_name: flux_evolution
    restart: always
    environment:
      SERVER_URL: https://${EVOLUTION_HOST}
      SERVER_PORT: 8080
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?schema=evolution
      DATABASE_CONNECTION_CLIENT_NAME: flux_evolution
      DATABASE_SAVE_DATA_INSTANCE: "true"
      DATABASE_SAVE_DATA_NEW_MESSAGE: "true"
      DATABASE_SAVE_MESSAGE_UPDATE: "true"
      DATABASE_SAVE_DATA_CONTACTS: "true"
      DATABASE_SAVE_DATA_CHATS: "true"
      CACHE_REDIS_ENABLED: "true"
      CACHE_REDIS_URI: redis://default:${REDIS_PASSWORD}@redis:6379/1
      CACHE_REDIS_PREFIX_KEY: evolution
      CACHE_LOCAL_ENABLED: "false"
      LOG_LEVEL: WARN
      DEL_INSTANCE: "false"
      WEBHOOK_GLOBAL_ENABLED: "false"
      WEBHOOK_GLOBAL_URL: ""
      QRCODE_LIMIT: 10
      QRCODE_COLOR: "#000000"
      TZ: America/Sao_Paulo
    volumes:
      - /opt/flux/evolution:/evolution/instances
    networks:
      - flux_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.evolution.rule=Host(`${EVOLUTION_HOST}`)"
      - "traefik.http.routers.evolution.entrypoints=websecure"
      - "traefik.http.routers.evolution.tls.certresolver=letsencrypt"
      - "traefik.http.services.evolution.loadbalancer.server.port=8080"

networks:
  flux_network:
    external: true
COMPOSEEOF

print_success "Docker Compose Evolution criado"

# Subir
print_step "Iniciando Evolution API..."
cd /opt/flux
docker compose -f docker-compose.yml -f docker-compose.evolution.yml --env-file .env up -d evolution

print_step "Aguardando (10s)..."
sleep 10

status=$(docker inspect -f '{{.State.Status}}' flux_evolution 2>/dev/null || echo "not found")
if [ "$status" = "running" ]; then
    echo -e "${GREEN}"
    echo "=============================================="
    echo "     EVOLUTION API INSTALADA COM SUCESSO!     "
    echo "=============================================="
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}Acesse:${NC} https://${EVOLUTION_HOST}"
    echo -e "${YELLOW}API Key:${NC} ${EVOLUTION_API_KEY}"
    echo ""
    echo -e "${YELLOW}IMPORTANTE: Anote a API Key!${NC}"
    echo ""
    echo -e "${BLUE}Comandos uteis:${NC}"
    echo "  Logs:       cd /opt/flux && docker compose -f docker-compose.yml -f docker-compose.evolution.yml logs -f evolution"
    echo "  Reiniciar:  cd /opt/flux && docker compose -f docker-compose.yml -f docker-compose.evolution.yml restart evolution"
    echo "  Atualizar:  cd /opt/flux && docker compose -f docker-compose.yml -f docker-compose.evolution.yml pull evolution && docker compose -f docker-compose.yml -f docker-compose.evolution.yml up -d evolution"
    echo ""
else
    print_error "Evolution nao iniciou. Logs: docker logs flux_evolution"
fi
