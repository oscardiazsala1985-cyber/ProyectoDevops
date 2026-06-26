#!/bin/bash
# ==============================================================================
# deploy_local.sh — Despliegue local con Docker Compose
# Útil para desarrollo y demostración sin necesitar AWS
#
# Uso: bash scripts/deploy_local.sh [start|stop|restart|logs|test]
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}✅ $1${NC}"; }
error()  { echo -e "${RED}❌ $1${NC}"; }
header() { echo -e "${BLUE}══ $1 ══${NC}"; }

ACTION="${1:-start}"

case "$ACTION" in
  start)
    header "Levantando entorno local con Docker Compose"
    docker-compose up --build -d
    log "Servicios iniciados"
    echo ""
    echo "Endpoints disponibles:"
    echo "  App:           http://localhost:8080/process"
    echo "  Health:        http://localhost:8080/health"
    echo "  Redis UI:      http://localhost:8081"
    echo ""
    echo "Prueba rápida:"
    echo "  curl -X POST http://localhost:8080/process \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"data\": \"hello-docker\"}'"
    ;;
  stop)
    header "Deteniendo entorno local"
    docker-compose down
    log "Servicios detenidos"
    ;;
  restart)
    header "Reiniciando entorno local"
    docker-compose down
    docker-compose up --build -d
    log "Servicios reiniciados"
    ;;
  logs)
    docker-compose logs -f --tail=50
    ;;
  test)
    header "Ejecutando smoke test local"
    sleep 3  # Esperar que esté listo
    bash scripts/health_check.sh "http://localhost:8080"
    ;;
  *)
    error "Uso: bash scripts/deploy_local.sh [start|stop|restart|logs|test]"
    exit 1
    ;;
esac
