#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Script Adicional: Evolution API
# Adiciona Evolution API a uma instalacao Flux existente
# Requisito: install-base.sh ja executado
# Usa: Nginx + Certbot (mesmo padrao da base)
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
echo "     FLUX AUTOMATE - Evolution API            "
echo "        WhatsApp Nao Oficial                  "
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

if [ -z "$EVOLUTION_HOST" ]; then
    print_error "Argumento obrigatorio faltando!"
    echo ""
    echo "Uso:"
    echo "  bash install-evolution.sh \\"
    echo "    --evolution evolution.seudominio.com \\"
    echo "    --email seuemail@email.com"
    exit 1
fi

# ============================================================
# VERIFICAR INSTALACAO BASE
# ============================================================
print_step "Verificando instalacao base..."

if [ ! -f /opt/flux/docker-compose.yml ]; then
    print_error "Instalacao base nao encontrada!"
    echo "Execute primeiro o install-base.sh"
    exit 1
fi

if ! docker network inspect flux_network &>/dev/null; then
    print_error "Rede flux_network nao encontrada!"
    echo "Execute primeiro o install-base.sh"
    exit 1
fi

print_success "Instalacao base encontrada"

# ============================================================
# CARREGAR .ENV E RECUPERAR EMAIL
# ============================================================
print_step "Carregando configuracoes existentes..."
source /opt/flux/.env

# Usar email do argumento ou do .env
if [ -z "$EMAIL" ]; then
    EMAIL="${SSL_EMAIL}"
fi

if [ -z "$EMAIL" ]; then
    print_error "Email nao encontrado. Use --email seuemail@email.com"
    exit 1
fi

print_success "Configuracoes carregadas"

# ============================================================
# GERAR CHAVE DA EVOLUTION
# ============================================================
EVOLUTION_API_KEY=$(openssl rand -hex 24)

# ============================================================
# ADICIONAR AO .ENV
# ============================================================
print_step "Adicionando Evolution ao .env..."

cat >> /opt/flux/.env << ENVEOF

# Evolution API
EVOLUTION_HOST=${EVOLUTION_HOST}
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
ENVEOF

print_success "Evolution adicionado ao .env"

# ============================================================
# CRIAR DIRETORIO
# ============================================================
mkdir -p /opt/flux/evolution
print_success "Diretorio Evolution criado"

# ============================================================
# CRIAR DOCKER COMPOSE DA EVOLUTION
# ============================================================
print_step "Criando docker-compose da Evolution..."

cat > /opt/flux/docker-compose.evolution.yml << COMPOSEEOF
services:

  evolution:
    image: atendai/evolution-api:latest
    container_name: flux_evolution
    restart: unless-stopped
    ports:
      - "8080:8080"
    environment:
      SERVER_URL: https://${EVOLUTION_HOST}
      SERVER_PORT: "8080"
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
      QRCODE_LIMIT: "10"
      QRCODE_COLOR: "#000000"
      TZ: America/Sao_Paulo
    volumes:
      - /opt/flux/evolution:/evolution/instances
    networks:
      - flux_network

networks:
  flux_network:
    external: true
COMPOSEEOF

print_success "Docker Compose Evolution criado"

# ============================================================
# SUBIR EVOLUTION
# ============================================================
print_step "Iniciando Evolution API..."
cd /opt/flux
docker compose -f docker-compose.yml -f docker-compose.evolution.yml up -d evolution

print_step "Aguardando Evolution ficar pronta (15s)..."
sleep 15

# ============================================================
# CONFIGURAR NGINX
# ============================================================
print_step "Configurando Nginx para Evolution..."

cat >> /etc/nginx/sites-available/flux << NGINXEOF

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

nginx -t && systemctl reload nginx
print_success "Nginx configurado para Evolution"

# ============================================================
# GERAR SSL
# ============================================================
print_step "Gerando certificado SSL para Evolution..."

certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "$EMAIL" \
    -d "$EVOLUTION_HOST"

print_success "SSL ativado para Evolution"

# ============================================================
# VERIFICAR STATUS
# ============================================================
status=$(docker inspect -f '{{.State.Status}}' flux_evolution 2>/dev/null || echo "not found")
if [ "$status" = "running" ]; then
    echo ""
    echo -e "${GREEN}"
    echo "=============================================="
    echo "     EVOLUTION API INSTALADA COM SUCESSO!     "
    echo "=============================================="
    echo -e "${NC}"
    echo ""
    echo -e "${BLUE}Acesse:${NC} https://${EVOLUTION_HOST}"
    echo ""
    echo -e "${YELLOW}API Key:${NC} ${EVOLUTION_API_KEY}"
    echo -e "${YELLOW}IMPORTANTE: Anote a API Key acima!${NC}"
    echo ""
    echo -e "${BLUE}Comandos uteis:${NC}"
    echo "  Logs:       cd /opt/flux && docker compose -f docker-compose.yml -f docker-compose.evolution.yml logs -f evolution"
    echo "  Reiniciar:  docker restart flux_evolution"
    echo "  Atualizar:  cd /opt/flux && docker compose -f docker-compose.yml -f docker-compose.evolution.yml pull evolution && docker compose -f docker-compose.yml -f docker-compose.evolution.yml up -d evolution"
    echo ""
    echo -e "${BLUE}Proximo passo:${NC} Acesse https://${EVOLUTION_HOST} e crie sua primeira instancia"
    echo ""
else
    print_error "Evolution nao iniciou corretamente"
    echo "Verifique os logs: docker logs flux_evolution"
fi
