#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Script Base de Instalacao
# Instala: Traefik + n8n + PostgreSQL + Redis + Portainer
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
echo "       FLUX AUTOMATE - Instalacao Base        "
echo "   n8n + PostgreSQL + Redis + Portainer       "
echo "              + Traefik (SSL)                 "
echo "=============================================="
echo -e "${NC}"

# ============================================================
# PARSEAR ARGUMENTOS
# ============================================================
DOMAIN=""
N8N_HOST=""
WEBHOOK_HOST=""
PORTAINER_HOST=""
EMAIL=""
N8N_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --n8n) N8N_HOST="$2"; shift 2 ;;
        --webhook) WEBHOOK_HOST="$2"; shift 2 ;;
        --portainer) PORTAINER_HOST="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --n8n-password) N8N_PASSWORD="$2"; shift 2 ;;
        *) print_error "Argumento desconhecido: $1"; exit 1 ;;
    esac
done

# ============================================================
# VALIDAR
# ============================================================
if [ -z "$DOMAIN" ] || [ -z "$N8N_HOST" ] || [ -z "$WEBHOOK_HOST" ] || [ -z "$PORTAINER_HOST" ] || [ -z "$EMAIL" ]; then
    print_error "Argumentos obrigatorios faltando!"
    echo ""
    echo "Uso:"
    echo "  bash install-base.sh \\"
    echo "    --domain seudominio.com \\"
    echo "    --n8n n8n.seudominio.com \\"
    echo "    --webhook webhook.seudominio.com \\"
    echo "    --portainer portainer.seudominio.com \\"
    echo "    --email seuemail@email.com"
    exit 1
fi

if [ -z "$N8N_PASSWORD" ]; then
    N8N_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
fi

POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
REDIS_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
N8N_JWT_SECRET=$(openssl rand -hex 32)

print_step "Configuracao:"
echo "  Dominio:    $DOMAIN"
echo "  n8n:        $N8N_HOST"
echo "  Webhook:    $WEBHOOK_HOST"
echo "  Portainer:  $PORTAINER_HOST"
echo "  Email SSL:  $EMAIL"
echo ""

# ============================================================
# 1. ATUALIZAR SISTEMA
# ============================================================
print_step "Atualizando sistema..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"

print_success "Sistema atualizado"

# ============================================================
# 2. INSTALAR DOCKER
# ============================================================
if command -v docker &> /dev/null; then
    print_success "Docker ja instalado ($(docker --version))"
else
    print_step "Instalando Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    print_success "Docker instalado"
fi

# ============================================================
# 3. CRIAR REDE DOCKER
# ============================================================
print_step "Criando rede Docker..."
docker network create flux_network 2>/dev/null || true
print_success "Rede flux_network criada"

# ============================================================
# 4. CRIAR DIRETORIOS
# ============================================================
print_step "Criando diretorios..."
mkdir -p /opt/flux/{traefik,n8n,postgres,redis,portainer}
mkdir -p /opt/flux/traefik/acme
touch /opt/flux/traefik/acme/acme.json
chmod 600 /opt/flux/traefik/acme/acme.json
print_success "Diretorios criados"

# ============================================================
# 5. CRIAR .ENV
# ============================================================
print_step "Gerando configuracoes..."
cat > /opt/flux/.env << ENVEOF
# FLUX AUTOMATE - Configuracoes
# Gerado em: $(date)

DOMAIN=${DOMAIN}
N8N_HOST=${N8N_HOST}
WEBHOOK_HOST=${WEBHOOK_HOST}
PORTAINER_HOST=${PORTAINER_HOST}
LETSENCRYPT_EMAIL=${EMAIL}

POSTGRES_USER=flux_user
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=flux_n8n

REDIS_PASSWORD=${REDIS_PASSWORD}

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_JWT_SECRET}
ENVEOF

chmod 600 /opt/flux/.env
print_success "Configuracoes salvas em /opt/flux/.env"

# ============================================================
# 6. DOCKER COMPOSE
# ============================================================
print_step "Criando Docker Compose..."

cat > /opt/flux/docker-compose.yml << 'COMPOSEEOF'
services:

  traefik:
    image: traefik:v3.1
    container_name: flux_traefik
    restart: always
    command:
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=flux_network"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entrypoint.to=websecure"
      - "--entrypoints.web.http.redirections.entrypoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.email=${LETSENCRYPT_EMAIL}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/acme/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/flux/traefik/acme:/acme
    networks:
      - flux_network

  postgres:
    image: postgres:16-alpine
    container_name: flux_postgres
    restart: always
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - /opt/flux/postgres:/var/lib/postgresql/data
    networks:
      - flux_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: flux_redis
    restart: always
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --maxmemory-policy allkeys-lru
    volumes:
      - /opt/flux/redis:/data
    networks:
      - flux_network
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  n8n:
    image: n8nio/n8n:latest
    container_name: flux_n8n
    restart: always
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      N8N_HOST: ${N8N_HOST}
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://${WEBHOOK_HOST}/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_USER_MANAGEMENT_JWT_SECRET}
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: 168
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_TEMPLATES_ENABLED: "true"
    volumes:
      - /opt/flux/n8n:/home/node/.n8n
    networks:
      - flux_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)"
      - "traefik.http.routers.n8n.entrypoints=websecure"
      - "traefik.http.routers.n8n.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n.loadbalancer.server.port=5678"
      - "traefik.http.routers.n8n-webhook.rule=Host(`${WEBHOOK_HOST}`)"
      - "traefik.http.routers.n8n-webhook.entrypoints=websecure"
      - "traefik.http.routers.n8n-webhook.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n-webhook.loadbalancer.server.port=5678"

  n8n-worker:
    image: n8nio/n8n:latest
    container_name: flux_n8n_worker
    restart: always
    depends_on:
      - n8n
    command: worker
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: 6379
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo
    volumes:
      - /opt/flux/n8n:/home/node/.n8n
    networks:
      - flux_network

  portainer:
    image: portainer/portainer-ce:latest
    container_name: flux_portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/flux/portainer:/data
    networks:
      - flux_network
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(`${PORTAINER_HOST}`)"
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

networks:
  flux_network:
    external: true
COMPOSEEOF

print_success "Docker Compose criado"

# ============================================================
# 7. SUBIR TUDO
# ============================================================
print_step "Iniciando servicos..."
cd /opt/flux
docker compose --env-file .env up -d

print_step "Aguardando servicos (15s)..."
sleep 15

# ============================================================
# 8. VERIFICAR STATUS
# ============================================================
print_step "Verificando status..."
echo ""

all_ok=true
for svc in flux_traefik flux_postgres flux_redis flux_n8n flux_n8n_worker flux_portainer; do
    status=$(docker inspect -f '{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
        print_success "$svc: rodando"
    else
        print_error "$svc: $status"
        all_ok=false
    fi
done

echo ""

# ============================================================
# 9. RESULTADO
# ============================================================
if [ "$all_ok" = true ]; then
    echo -e "${GREEN}"
    echo "=============================================="
    echo "       INSTALACAO CONCLUIDA COM SUCESSO!      "
    echo "=============================================="
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}Acesse seus servicos:${NC}"
    echo "  n8n:        https://${N8N_HOST}"
    echo "  Webhook:    https://${WEBHOOK_HOST}"
    echo "  Portainer:  https://${PORTAINER_HOST}"
    echo ""
    echo -e "${YELLOW}Credenciais salvas em:${NC} /opt/flux/.env"
    echo -e "${YELLOW}Senha inicial n8n:${NC} ${N8N_PASSWORD}"
    echo ""
    echo -e "${YELLOW}IMPORTANTE: Anote a senha acima!${NC}"
    echo ""
    echo -e "${BLUE}Comandos uteis:${NC}"
    echo "  Ver logs:       cd /opt/flux && docker compose logs -f"
    echo "  Reiniciar:      cd /opt/flux && docker compose restart"
    echo "  Parar:          cd /opt/flux && docker compose down"
    echo "  Atualizar n8n:  cd /opt/flux && docker compose pull n8n n8n-worker && docker compose up -d"
    echo ""
else
    echo -e "${RED}"
    echo "=============================================="
    echo "     ALGUNS SERVICOS COM PROBLEMA             "
    echo "=============================================="
    echo -e "${NC}"
    echo "Verifique os logs: cd /opt/flux && docker compose logs"
fi
