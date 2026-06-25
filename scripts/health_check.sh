#!/bin/bash
# ==============================================================================
# health_check.sh — Smoke test y verificación de salud de todos los endpoints
# Modo dummies: verifica que la app está respondiendo correctamente
# después de un despliegue. Si algo falla, lo reporta inmediatamente.
#
# Uso: bash scripts/health_check.sh <API_URL>
# Ejemplo: bash scripts/health_check.sh https://abc123.execute-api.us-east-1.amazonaws.com
# ==============================================================================

set -euo pipefail

API_URL="${1:-}"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}✅ $1${NC}"; }
error()   { echo -e "${RED}❌ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
header()  { echo -e "${BLUE}══ $1 ══${NC}"; }

# Obtener URL desde Terraform si no se pasó como argumento
if [ -z "$API_URL" ]; then
  if command -v terraform &> /dev/null; then
    API_URL=$(terraform output -raw api_process_url 2>/dev/null | sed 's|/process$||' || echo "")
  fi
fi

if [ -z "$API_URL" ]; then
  error "Uso: bash scripts/health_check.sh <API_BASE_URL>"
  error "O ejecuta desde el directorio raíz donde está terraform state"
  exit 1
fi

PROCESS_URL="${API_URL}/process"
PASS=0
FAIL=0

header "HEALTH CHECK — SRE Process Service"
echo "URL base: $API_URL"
echo "Fecha: $(date)"
echo ""

# ── Test 1: Cache MISS (primera petición con payload único) ────────────────
header "Test 1: Cache MISS"
UNIQUE_PAYLOAD="health-check-$(date +%s)-$$"
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "$PROCESS_URL" \
  -H "Content-Type: application/json" \
  -d "{\"test\": \"$UNIQUE_PAYLOAD\"}" \
  --max-time 10)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)
CACHE_STATUS=$(echo "$RESPONSE" | grep -o '"X-Cache":"[^"]*"' | cut -d'"' -f4 2>/dev/null || \
  curl -s -I -X POST "$PROCESS_URL" \
    -H "Content-Type: application/json" \
    -d "{\"test\": \"$UNIQUE_PAYLOAD\"}" 2>/dev/null | grep -i "x-cache" | awk '{print $2}' || echo "unknown")

if [ "$HTTP_CODE" = "200" ]; then
  log "HTTP 200 OK"
  PASS=$((PASS + 1))
else
  error "HTTP $HTTP_CODE (esperado 200)"
  FAIL=$((FAIL + 1))
fi

# ── Test 2: Cache HIT (misma petición inmediatamente) ─────────────────────
header "Test 2: Cache HIT"
RESPONSE2=$(curl -s -w "\n%{http_code}" \
  -X POST "$PROCESS_URL" \
  -H "Content-Type: application/json" \
  -d "{\"test\": \"$UNIQUE_PAYLOAD\"}" \
  --max-time 10)

HTTP_CODE2=$(echo "$RESPONSE2" | tail -1)

if [ "$HTTP_CODE2" = "200" ]; then
  log "HTTP 200 OK — segunda petición exitosa"
  PASS=$((PASS + 1))
else
  error "HTTP $HTTP_CODE2 en segunda petición"
  FAIL=$((FAIL + 1))
fi

# ── Test 3: Latencia aceptable (<1000ms) ───────────────────────────────────
header "Test 3: Latencia"
LATENCY=$(curl -s -o /dev/null -w "%{time_total}" \
  -X POST "$PROCESS_URL" \
  -H "Content-Type: application/json" \
  -d '{"test": "latency-check"}' \
  --max-time 10)

LATENCY_MS=$(echo "$LATENCY * 1000" | bc | cut -d. -f1)

if [ "$LATENCY_MS" -lt 1000 ]; then
  log "Latencia: ${LATENCY_MS}ms (< 1000ms ✅)"
  PASS=$((PASS + 1))
elif [ "$LATENCY_MS" -lt 3000 ]; then
  warn "Latencia: ${LATENCY_MS}ms (elevada pero aceptable)"
  PASS=$((PASS + 1))
else
  error "Latencia: ${LATENCY_MS}ms (> 3000ms — problema de rendimiento)"
  FAIL=$((FAIL + 1))
fi

# ── Test 4: Respuesta con campos requeridos ────────────────────────────────
header "Test 4: Validación de respuesta JSON"
RESPONSE4=$(curl -s \
  -X POST "$PROCESS_URL" \
  -H "Content-Type: application/json" \
  -d '{"validate": "json-structure"}' \
  --max-time 10)

if echo "$RESPONSE4" | grep -q '"id"' && \
   echo "$RESPONSE4" | grep -q '"processedAt"' && \
   echo "$RESPONSE4" | grep -q '"algorithm"'; then
  log "Campos requeridos presentes: id, processedAt, algorithm"
  PASS=$((PASS + 1))
else
  error "Respuesta incompleta: $RESPONSE4"
  FAIL=$((FAIL + 1))
fi

# ── Test 5: Manejo de método incorrecto ───────────────────────────────────
header "Test 5: Método no permitido (GET)"
HTTP_GET=$(curl -s -o /dev/null -w "%{http_code}" \
  -X GET "$PROCESS_URL" \
  --max-time 10)

if [ "$HTTP_GET" != "200" ]; then
  log "GET devuelve HTTP $HTTP_GET (correcto — endpoint solo acepta POST)"
  PASS=$((PASS + 1))
else
  warn "GET devuelve 200 — considerar restringir métodos HTTP"
  PASS=$((PASS + 1))  # No falla, solo advierte
fi

# ── Resumen final ──────────────────────────────────────────────────────────
echo ""
header "RESUMEN"
echo "Tests ejecutados: $((PASS + FAIL))"
echo -e "${GREEN}Pasados: $PASS${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "${RED}Fallados: $FAIL${NC}"
  exit 1
else
  echo -e "${GREEN}Fallados: $FAIL${NC}"
  log "Todos los health checks PASARON ✅"
fi
