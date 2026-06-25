# ==============================================================================
# Dockerfile — SRE Process Service
# Imagen multi-stage para producción: build limpio + imagen final mínima
# Modo dummies: el stage 1 instala todo, el stage 2 solo copia lo necesario
# Resultado: imagen de ~120MB en vez de ~800MB
# ==============================================================================

# ── Stage 1: Dependencias ─────────────────────────────────────────────────────
FROM node:20-alpine AS deps

# Instalar dependencias del sistema necesarias para compilar módulos nativos
RUN apk add --no-cache python3 make g++

WORKDIR /app

# Copiar solo los archivos de dependencias primero
# Docker cachea esta capa — si no cambia package.json, no reinstala
COPY lambda/package.json ./

# Instalar solo dependencias de producción (no devDependencies)
RUN npm install --omit=dev --frozen-lockfile

# ── Stage 2: Imagen de producción ─────────────────────────────────────────────
FROM node:20-alpine AS production

# Metadatos de la imagen
LABEL maintainer="Oscar Diaz"
LABEL project="sre-process-service"
LABEL version="1.0.0"

# Crear usuario no-root por seguridad
# Modo dummies: la app no corre como administrador para limitar daños si la hackean
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app

# Copiar dependencias del stage anterior
COPY --from=deps --chown=appuser:appgroup /app/node_modules ./node_modules

# Copiar código de la aplicación
COPY --chown=appuser:appgroup lambda/index.js ./index.js
COPY --chown=appuser:appgroup lambda/server.js ./server.js
COPY --chown=appuser:appgroup lambda/package.json ./package.json

# Cambiar al usuario no-root
USER appuser

# Puerto que expone la aplicación
EXPOSE 8080

# Variables de entorno con valores por defecto (sobreescribibles al correr el container)
ENV PORT=8080 \
    NODE_ENV=production \
    REDIS_PORT=6379 \
    REDIS_TTL_SECONDS=60

# Health check — Docker verifica que la app responde correctamente
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

# Comando de arranque
CMD ["node", "server.js"]
