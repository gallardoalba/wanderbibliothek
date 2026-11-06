# syntax=docker/dockerfile:1
#
# Imagen de producción de Wanderbibliothek.
#
#   docker build -t wanderbibliothek .
#   docker compose up -d          (ver docker-compose.yml)
#
# Tres etapas para que la imagen final no lleve ni TypeScript ni las
# herramientas de compilación de better-sqlite3.

# --- 1. Dependencias completas (incluye devDependencies para el build) ------
FROM node:25-bookworm-slim AS deps
WORKDIR /app

# `better-sqlite3` se compila con node-gyp al instalarlo (no trae binarios para
# todas las plataformas): estas herramientas son obligatorias en esta etapa.
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
RUN npm ci

# --- 2. Build ---------------------------------------------------------------
FROM node:25-bookworm-slim AS builder
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1

# Las variables NEXT_PUBLIC_* se incrustan en el bundle del cliente durante el
# build: definirlas solo en el entorno del contenedor NO sirve (el widget de
# Turnstile no aparecería y la CSP no autorizaría challenges.cloudflare.com).
# Se pasan como build args para que la imagen pueda llevar captcha:
#   docker compose build --build-arg NEXT_PUBLIC_TURNSTILE_SITE_KEY=0x4AAA…
ARG NEXT_PUBLIC_TURNSTILE_SITE_KEY=""
ENV NEXT_PUBLIC_TURNSTILE_SITE_KEY=$NEXT_PUBLIC_TURNSTILE_SITE_KEY

COPY --from=deps /app/node_modules ./node_modules
COPY . .
# El build no necesita base de datos ni secretos.
RUN npm run build

# --- 3. Runtime -------------------------------------------------------------
FROM node:25-bookworm-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    WANDERBIBLIOTHEK_DB=/data/wanderbibliothek.db \
    WANDERBIBLIOTHEK_BACKUP_DIR=/backups

# `curl` es útil para diagnosticar desde dentro del contenedor.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /data /backups \
  && chown -R node:node /data /backups

# Solo dependencias de ejecución (tsx va en dependencies: lo usan los scripts
# de administración, copia y verificación).
#
# `better-sqlite3` 13 no publica binarios para todas las plataformas: npm lo
# compila con node-gyp al instalarlo. Por eso aquí no se vuelve a instalar —
# haría falta python3, make y g++ también en la imagen final—, sino que se
# reutiliza el `node_modules` ya compilado en la etapa `deps` y se quitan las
# devDependencies.
COPY package.json package-lock.json ./
COPY --from=deps /app/node_modules ./node_modules
RUN npm prune --omit=dev && npm cache clean --force

COPY --from=builder --chown=node:node /app/.next ./.next
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/next.config.ts ./next.config.ts
COPY --from=builder --chown=node:node /app/tsconfig.json ./tsconfig.json
# `src` y `scripts` no los necesita Next en ejecución, pero sí los scripts de
# operación (`admin:create`, `db:backup`, `user:verify`).
COPY --from=builder --chown=node:node /app/src ./src
COPY --from=builder --chown=node:node /app/scripts ./scripts

USER node
EXPOSE 3000
VOLUME ["/data", "/backups"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/api/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

# Dentro del contenedor escucha en todas las interfaces: el proxy (nginx,
# Caddy, el del host) es quien pone el TLS delante.
CMD ["node", "node_modules/next/dist/bin/next", "start", "-H", "0.0.0.0", "-p", "3000"]
