#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Evolution API Standalone
# Instala: Docker + PostgreSQL + Redis + Evolution API + Nginx + SSL
# Sem n8n - para uso independente
# ============================================================

set -e
export DEBIAN_FRONTEND=noninteractive

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
echo "    FLUX AUTOMATE - Evolution Standalone       "
echo "   Evolution API + PostgreSQL + Redis          "
echo "         Nginx + Certbot (SSL)                 "
echo "=============================================="
echo -e "${NC}"

# ============================================================
# PARSEAR ARGUMENTOS
# ============================================================
EVOLUTION_HOST=""
EMAIL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --evolution) EVOLUTION_HOST="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        *) print_error "Argumento desconhecido: $1"; exit 1 ;;
    esac
done

# ============================================================
# VALIDAR
# ============================================================
if [ -z "$EVOLUTION_HOST" ] || [ -z "$EMAIL" ]; then
    print_error "Argumentos obrigatorios faltando!"
    echo ""
    echo "Uso:"
    echo "  bash install-evolution-standalone.sh \\"
    echo "    --evolution evolution.seudominio.com \\"
    echo "    --email seuemail@email.com"
    exit 1
fi

# Gerar senhas seguras
POSTGRES_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
EVOLUTION_API_KEY=$(openssl rand -hex 24)

print_step "Configuracao:"
echo "  Evolution:  $EVOLUTION_HOST"
echo "  Email SSL:  $EMAIL"
echo ""

# ============================================================
# 1. ATUALIZAR SISTEMA
# ============================================================
print_step "Atualizando sistema..."
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
print_success "Sistema atualizado"

# ============================================================
# 2. INSTALAR DOCKER
# ============================================================
if command -v docker &> /dev/null; then
    print_success "Docker ja instalado ($(docker --version | cut -d' ' -f3 | tr -d ','))"
else
    print_step "Instalando Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    systemctl enable docker
    systemctl start docker
    print_success "Docker instalado"
fi

# ============================================================
# 3. CRIAR ESTRUTURA
# ============================================================
print_step "Criando estrutura..."
mkdir -p /opt/flux-evolution/{postgres,redis,evolution}
docker network create flux_evo_network 2>/dev/null || true
print_success "Estrutura criada"

# ============================================================
# 4. CRIAR .ENV
# ============================================================
print_step "Gerando configuracoes..."
cat > /opt/flux-evolution/.env << ENVEOF
# FLUX AUTOMATE - Evolution Standalone
# Gerado em: $(date)

EVOLUTION_HOST=${EVOLUTION_HOST}
SSL_EMAIL=${EMAIL}

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=evolution

REDIS_PASSWORD=${REDIS_PASSWORD}

EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
ENVEOF

chmod 600 /opt/flux-evolution/.env
print_success "Configuracoes salvas"

# ============================================================
# 5. DOCKER COMPOSE
# ============================================================
print_step "Criando Docker Compose..."

cat > /opt/flux-evolution/docker-compose.yml << COMPOSEEOF
services:

  postgres:
    image: postgres:16-alpine
    container_name: fluxevo_postgres
    restart: unless-stopped
    networks:
      - flux_evo_network
    volumes:
      - /opt/flux-evolution/postgres:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_USER: postgres
      POSTGRES_DB: evolution
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: fluxevo_redis
    restart: unless-stopped
    networks:
      - flux_evo_network
    volumes:
      - /opt/flux-evolution/redis:/data
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --maxmemory-policy allkeys-lru

  evolution:
    image: evoapicloud/evolution-api:v2.3.7
    container_name: fluxevo_evolution
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8080:8080"
    environment:
      SERVER_URL: https://${EVOLUTION_HOST}
      SERVER_PORT: "8080"
      AUTHENTICATION_API_KEY: ${EVOLUTION_API_KEY}
      AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES: "true"
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evolution?schema=public
      DATABASE_CONNECTION_CLIENT_NAME: fluxevo
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
      QRCODE_LIMIT: "10"
      QRCODE_COLOR: "#000000"
      TZ: America/Sao_Paulo
    volumes:
      - /opt/flux-evolution/evolution:/evolution/instances
    networks:
      - flux_evo_network

networks:
  flux_evo_network:
    external: true
COMPOSEEOF

print_success "Docker Compose criado"

# ============================================================
# 6. SUBIR CONTAINERS
# ============================================================
print_step "Subindo containers..."
cd /opt/flux-evolution
docker compose up -d

print_step "Aguardando servicos ficarem prontos (20s)..."
sleep 20
print_success "Containers rodando"

# ============================================================
# 7. INSTALAR NGINX
# ============================================================
print_step "Instalando Nginx..."
apt-get install -y -qq nginx
print_success "Nginx instalado"

# ============================================================
# 8. CONFIGURAR NGINX
# ============================================================
print_step "Configurando Nginx..."

cat > /etc/nginx/sites-available/flux-evolution << NGINXEOF
# Evolution API
server {
    listen 80;
    server_name ${EVOLUTION_HOST};

    location / {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/flux-evolution /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
print_success "Nginx configurado"

# ============================================================
# 9. SSL COM CERTBOT
# ============================================================
print_step "Instalando Certbot e gerando certificado SSL..."
apt-get install -y -qq certbot python3-certbot-nginx

certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "$EMAIL" \
    -d "$EVOLUTION_HOST"

print_success "SSL ativado"

# ============================================================
# 10. FIREWALL
# ============================================================
print_step "Configurando firewall..."
ufw allow 'Nginx Full' 2>/dev/null || true
ufw allow OpenSSH 2>/dev/null || true
print_success "Firewall configurado"

# ============================================================
# 11. VERIFICAR STATUS
# ============================================================
print_step "Verificando status final..."
echo ""

all_ok=true
for svc in fluxevo_postgres fluxevo_redis fluxevo_evolution; do
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
# 12. RESULTADO
# ============================================================
if [ "$all_ok" = true ]; then
    echo -e "${GREEN}"
    echo "=============================================="
    echo "     EVOLUTION STANDALONE - INSTALADA!         "
    echo "=============================================="
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}Acesse:${NC} https://${EVOLUTION_HOST}"
    echo ""
    echo -e "${YELLOW}API Key:${NC} ${EVOLUTION_API_KEY}"
    echo ""
    echo -e "${YELLOW}Credenciais salvas em:${NC} /opt/flux-evolution/.env"
    echo ""
    echo -e "${YELLOW}IMPORTANTE: Anote a API Key acima!${NC}"
    echo ""
    echo -e "${BLUE}Comandos uteis:${NC}"
    echo "  Ver logs:       cd /opt/flux-evolution && docker compose logs -f"
    echo "  Reiniciar:      cd /opt/flux-evolution && docker compose restart"
    echo "  Parar:          cd /opt/flux-evolution && docker compose down"
    echo "  Atualizar:      cd /opt/flux-evolution && docker compose pull evolution && docker compose up -d"
    echo "  Renovar SSL:    certbot renew"
    echo ""
else
    echo -e "${RED}"
    echo "=============================================="
    echo "     ALGUNS SERVICOS COM PROBLEMA             "
    echo "=============================================="
    echo -e "${NC}"
    echo "Verifique os logs: cd /opt/flux-evolution && docker compose logs"
fi
