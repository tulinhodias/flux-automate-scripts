#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Script Base de Instalacao v3
# Baseado no script original que ja funcionava
# Instala: Docker + n8n + PostgreSQL + Redis + Portainer
# Proxy: Nginx direto no servidor + Certbot (SSL)
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
echo "      FLUX AUTOMATE - Instalacao Base v3      "
echo "   n8n + PostgreSQL + Redis + Portainer       "
echo "         Nginx + Certbot (SSL)                "
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

while [[ $# -gt 0 ]]; do
    case $1 in
        --domain) DOMAIN="$2"; shift 2 ;;
        --n8n) N8N_HOST="$2"; shift 2 ;;
        --webhook) WEBHOOK_HOST="$2"; shift 2 ;;
        --portainer) PORTAINER_HOST="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
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

# Gerar senhas seguras
POSTGRES_PASSWORD=$(openssl rand -hex 16)
REDIS_PASSWORD=$(openssl rand -hex 16)
N8N_ENCRYPTION_KEY=$(openssl rand -base64 32)
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
# 3. CRIAR DIRETORIOS E REDE
# ============================================================
print_step "Criando estrutura..."
mkdir -p /opt/flux/{n8n,postgres,redis,portainer}
chown -R 1000:1000 /opt/flux/n8n
docker network create flux_network 2>/dev/null || true
print_success "Estrutura criada"

# ============================================================
# 4. CRIAR .ENV
# ============================================================
print_step "Gerando configuracoes..."
cat > /opt/flux/.env << ENVEOF
# FLUX AUTOMATE - Configuracoes
# Gerado em: $(date)

DOMAIN=${DOMAIN}
N8N_HOST=${N8N_HOST}
WEBHOOK_HOST=${WEBHOOK_HOST}
PORTAINER_HOST=${PORTAINER_HOST}
SSL_EMAIL=${EMAIL}

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n

REDIS_PASSWORD=${REDIS_PASSWORD}

N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_USER_MANAGEMENT_JWT_SECRET=${N8N_JWT_SECRET}
ENVEOF

chmod 600 /opt/flux/.env
print_success "Configuracoes salvas"

# ============================================================
# 5. DOCKER COMPOSE
# ============================================================
print_step "Criando Docker Compose..."
cat > /opt/flux/docker-compose.yml << COMPOSEEOF
services:

  n8n_editor:
    image: n8nio/n8n:latest
    container_name: flux_n8n
    command: start
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /opt/flux/n8n:/home/node/.n8n
    ports:
      - "5678:5678"
    environment:
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${WEBHOOK_HOST}
      N8N_EDITOR_BASE_URL: https://${N8N_HOST}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: "6379"
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_USER_MANAGEMENT_JWT_SECRET: ${N8N_JWT_SECRET}
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: "168"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_TEMPLATES_ENABLED: "true"

  n8n_webhook:
    image: n8nio/n8n:latest
    container_name: flux_n8n_webhook
    command: webhook
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /opt/flux/n8n:/home/node/.n8n
    ports:
      - "5679:5678"
    environment:
      N8N_HOST: ${N8N_HOST}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${WEBHOOK_HOST}
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: "6379"
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo

  n8n_worker:
    image: n8nio/n8n:latest
    container_name: flux_n8n_worker
    command: worker --concurrency=10
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /opt/flux/n8n:/home/node/.n8n
    environment:
      EXECUTIONS_MODE: queue
      QUEUE_BULL_REDIS_HOST: redis
      QUEUE_BULL_REDIS_PORT: "6379"
      QUEUE_BULL_REDIS_PASSWORD: ${REDIS_PASSWORD}
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: America/Sao_Paulo
      TZ: America/Sao_Paulo

  postgres:
    image: postgres:16-alpine
    container_name: flux_postgres
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /opt/flux/postgres:/var/lib/postgresql/data
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_USER: postgres
      POSTGRES_DB: n8n
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: flux_redis
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /opt/flux/redis:/data
    command: redis-server --requirepass ${REDIS_PASSWORD} --maxmemory 128mb --maxmemory-policy allkeys-lru

  portainer:
    image: portainer/portainer-ce:latest
    container_name: flux_portainer
    restart: unless-stopped
    networks:
      - flux_network
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/flux/portainer:/data
    ports:
      - "9000:9000"

networks:
  flux_network:
    external: true
COMPOSEEOF

print_success "Docker Compose criado"

# ============================================================
# 6. SUBIR CONTAINERS
# ============================================================
print_step "Subindo containers..."
cd /opt/flux
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
# 8. CONFIGURAR NGINX (PROXY REVERSO)
# ============================================================
print_step "Configurando Nginx..."

cat > /etc/nginx/sites-available/flux << NGINXEOF
# n8n Editor
server {
    listen 80;
    server_name ${N8N_HOST};

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
    }
}

# n8n Webhooks
server {
    listen 80;
    server_name ${WEBHOOK_HOST};

    location / {
        proxy_pass http://localhost:5679;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# Portainer
server {
    listen 80;
    server_name ${PORTAINER_HOST};

    location / {
        proxy_pass http://localhost:9000;
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

# Ativar configuracao e remover default
ln -sf /etc/nginx/sites-available/flux /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Testar e recarregar
nginx -t && systemctl reload nginx
print_success "Nginx configurado"

# ============================================================
# 9. INSTALAR SSL COM CERTBOT
# ============================================================
print_step "Instalando Certbot e gerando certificados SSL..."
apt-get install -y -qq certbot python3-certbot-nginx

certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "$EMAIL" \
    -d "$N8N_HOST" \
    -d "$WEBHOOK_HOST" \
    -d "$PORTAINER_HOST"

print_success "SSL ativado para todos os dominios"

# ============================================================
# 10. LIBERAR FIREWALL
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
for svc in flux_n8n flux_n8n_webhook flux_n8n_worker flux_postgres flux_redis flux_portainer; do
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
    echo ""
    echo -e "${YELLOW}IMPORTANTE: Anote as credenciais do arquivo .env${NC}"
    echo ""
    echo -e "${BLUE}Comandos uteis:${NC}"
    echo "  Ver logs:       cd /opt/flux && docker compose logs -f"
    echo "  Reiniciar:      cd /opt/flux && docker compose restart"
    echo "  Parar:          cd /opt/flux && docker compose down"
    echo "  Atualizar n8n:  cd /opt/flux && docker compose pull && docker compose up -d"
    echo "  Renovar SSL:    certbot renew"
    echo ""
else
    echo -e "${RED}"
    echo "=============================================="
    echo "     ALGUNS SERVICOS COM PROBLEMA             "
    echo "=============================================="
    echo -e "${NC}"
    echo "Verifique os logs: cd /opt/flux && docker compose logs"
fi
