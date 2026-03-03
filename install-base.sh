#!/bin/bash

# ============================================================
# FLUX AUTOMATE - Script Base de Instalacao v2
# Instala: Nginx Proxy Manager + n8n + PostgreSQL + Redis + Portainer
# SSL automatico via Let's Encrypt
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
echo "      FLUX AUTOMATE - Instalacao Base v2      "
echo "   n8n + PostgreSQL + Redis + Portainer       "
echo "        + Nginx Proxy Manager (SSL)           "
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
NPM_ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

print_step "Configuracao:"
echo "  Dominio:    $DOMAIN"
echo "  n8n:        $N8N_HOST"
echo "  Webhook:    $WEBHOOK_HOST"
echo "  Portainer:  $PORTAINER_HOST"
echo "  Email SSL:  $EMAIL"
echo ""

# ============================================================
# 1. ATUALIZAR SISTEMA (sem interacao)
# ============================================================
print_step "Atualizando sistema..."
apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
print_success "Sistema atualizado"

# ============================================================
# 2. INSTALAR DOCKER
# ============================================================
if command -v docker &> /dev/null; then
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
    DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)
    if [ "$DOCKER_MAJOR" -lt 24 ] 2>/dev/null; then
        print_step "Docker desatualizado ($DOCKER_VERSION). Atualizando..."
        apt-get remove -y docker.io docker-doc docker-compose containerd runc docker-ce docker-ce-cli 2>/dev/null || true
        curl -fsSL https://get.docker.com | bash
        systemctl restart docker
        print_success "Docker atualizado"
    else
        print_success "Docker ja instalado (v$DOCKER_VERSION)"
    fi
else
    print_step "Instalando Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    print_success "Docker instalado ($(docker version --format '{{.Server.Version}}'))"
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
mkdir -p /opt/flux/{n8n,postgres,redis,portainer}
mkdir -p /opt/flux/npm/{data,letsencrypt}
# Permissao correta para n8n (roda como user 1000)
chown -R 1000:1000 /opt/flux/n8n
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

  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: flux_npm
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    volumes:
      - /opt/flux/npm/data:/data
      - /opt/flux/npm/letsencrypt:/etc/letsencrypt
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

print_step "Aguardando servicos ficarem prontos (30s)..."
sleep 30

# ============================================================
# 8. CONFIGURAR NGINX PROXY MANAGER VIA API
# ============================================================
print_step "Configurando Nginx Proxy Manager..."

NPM_URL="http://127.0.0.1:81"

# Aguardar NPM ficar pronto
for i in $(seq 1 30); do
    if curl -s "$NPM_URL/api/" > /dev/null 2>&1; then
        break
    fi
    sleep 2
done

# Login com credenciais padrao
print_step "Fazendo login no NPM..."
TOKEN=$(curl -s "$NPM_URL/api/tokens" \
    -H "Content-Type: application/json" \
    -d '{"identity":"admin@example.com","secret":"changeme"}' 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    print_error "Nao foi possivel conectar ao NPM. Configuracao manual necessaria."
    print_step "Acesse http://IP_DA_VPS:81 para configurar manualmente."
else
    print_success "Login no NPM realizado"

    # Trocar email e senha do admin
    print_step "Atualizando credenciais do NPM..."
    
    # Atualizar dados do usuario admin
    curl -s "$NPM_URL/api/users/1" \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"Admin\",\"nickname\":\"Admin\",\"email\":\"${EMAIL}\"}" > /dev/null 2>&1

    # Atualizar senha do admin
    curl -s "$NPM_URL/api/users/1/auth" \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"password\",\"current\":\"changeme\",\"secret\":\"${NPM_ADMIN_PASSWORD}\"}" > /dev/null 2>&1

    # Refazer login com nova senha
    TOKEN=$(curl -s "$NPM_URL/api/tokens" \
        -H "Content-Type: application/json" \
        -d "{\"identity\":\"${EMAIL}\",\"secret\":\"${NPM_ADMIN_PASSWORD}\"}" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$TOKEN" ]; then
        print_error "Erro ao atualizar credenciais. Usando credenciais padrao."
        TOKEN=$(curl -s "$NPM_URL/api/tokens" \
            -H "Content-Type: application/json" \
            -d '{"identity":"admin@example.com","secret":"changeme"}' 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    else
        print_success "Credenciais do NPM atualizadas"
    fi

    # Funcao para criar proxy host com SSL
    create_proxy() {
        local DOMAIN_NAME=$1
        local FORWARD_HOST=$2
        local FORWARD_PORT=$3
        local LABEL=$4

        print_step "Configurando proxy: $LABEL ($DOMAIN_NAME)..."

        # Criar proxy host sem SSL primeiro
        PROXY_ID=$(curl -s "$NPM_URL/api/nginx/proxy-hosts" \
            -X POST \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
                \"domain_names\": [\"${DOMAIN_NAME}\"],
                \"forward_scheme\": \"http\",
                \"forward_host\": \"${FORWARD_HOST}\",
                \"forward_port\": ${FORWARD_PORT},
                \"block_exploits\": true,
                \"allow_websocket_upgrade\": true,
                \"access_list_id\": 0,
                \"certificate_id\": 0,
                \"ssl_forced\": false,
                \"http2_support\": true,
                \"meta\": {\"letsencrypt_agree\": true,\"dns_challenge\": false},
                \"advanced_config\": \"\",
                \"locations\": [],
                \"caching_enabled\": false,
                \"hsts_enabled\": false,
                \"hsts_subdomains\": false
            }" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

        if [ -n "$PROXY_ID" ]; then
            print_success "Proxy $LABEL criado (ID: $PROXY_ID)"

            # Solicitar certificado SSL
            print_step "Solicitando SSL para $DOMAIN_NAME..."
            sleep 3

            CERT_ID=$(curl -s "$NPM_URL/api/nginx/certificates" \
                -X POST \
                -H "Authorization: Bearer $TOKEN" \
                -H "Content-Type: application/json" \
                -d "{
                    \"domain_names\": [\"${DOMAIN_NAME}\"],
                    \"meta\": {
                        \"letsencrypt_email\": \"${EMAIL}\",
                        \"letsencrypt_agree\": true,
                        \"dns_challenge\": false
                    },
                    \"provider\": \"letsencrypt\"
                }" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

            if [ -n "$CERT_ID" ]; then
                # Atualizar proxy host com SSL
                curl -s "$NPM_URL/api/nginx/proxy-hosts/$PROXY_ID" \
                    -X PUT \
                    -H "Authorization: Bearer $TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "{
                        \"domain_names\": [\"${DOMAIN_NAME}\"],
                        \"forward_scheme\": \"http\",
                        \"forward_host\": \"${FORWARD_HOST}\",
                        \"forward_port\": ${FORWARD_PORT},
                        \"block_exploits\": true,
                        \"allow_websocket_upgrade\": true,
                        \"access_list_id\": 0,
                        \"certificate_id\": ${CERT_ID},
                        \"ssl_forced\": true,
                        \"http2_support\": true,
                        \"meta\": {\"letsencrypt_agree\": true,\"dns_challenge\": false},
                        \"advanced_config\": \"\",
                        \"locations\": [],
                        \"caching_enabled\": false,
                        \"hsts_enabled\": false,
                        \"hsts_subdomains\": false
                    }" > /dev/null 2>&1
                print_success "SSL ativado para $LABEL"
            else
                print_error "SSL falhou para $LABEL (configure manualmente no NPM)"
            fi
        else
            print_error "Erro ao criar proxy $LABEL (configure manualmente no NPM)"
        fi

        sleep 2
    }

    # Criar os 3 proxy hosts
    create_proxy "$N8N_HOST" "flux_n8n" 5678 "n8n"
    create_proxy "$WEBHOOK_HOST" "flux_n8n" 5678 "Webhook"
    create_proxy "$PORTAINER_HOST" "flux_portainer" 9000 "Portainer"
fi

# ============================================================
# 9. VERIFICAR STATUS
# ============================================================
print_step "Verificando status final..."
echo ""

all_ok=true
for svc in flux_npm flux_postgres flux_redis flux_n8n flux_n8n_worker flux_portainer; do
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
# 10. RESULTADO
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
    echo -e "${BLUE}Painel Nginx Proxy Manager:${NC}"
    echo "  URL:        http://$(curl -s ifconfig.me 2>/dev/null || echo 'IP_DA_VPS'):81"
    echo "  Email:      ${EMAIL}"
    echo "  Senha:      ${NPM_ADMIN_PASSWORD}"
    echo ""
    echo -e "${YELLOW}Credenciais salvas em:${NC} /opt/flux/.env"
    echo -e "${YELLOW}Senha inicial n8n:${NC} ${N8N_PASSWORD}"
    echo ""
    echo -e "${YELLOW}IMPORTANTE: Anote as senhas acima!${NC}"
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
