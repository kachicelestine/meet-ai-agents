# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# Meet AI — Production Dockerfile
#
# Stages
#   base      shared Alpine + libc shim
#   deps      production-only node_modules (npm ci --omit=dev)
#   builder   full install + `next build` → .next/standalone
#   runner    minimal runtime image (~200 MB vs ~1 GB naive)
#   dev       local hot-reload target (bind-mounted source)
#
# Build args (NEXT_PUBLIC_* must be supplied at build time — Next.js inlines
# them into the client bundle during `next build`):
#   NEXT_PUBLIC_APP_URL
#   NEXT_PUBLIC_STREAM_VIDEO_API_KEY
#   NEXT_PUBLIC_STREAM_CHAT_API_KEY
#
# Usage:
#   # Production
#   docker build \
#     --build-arg NEXT_PUBLIC_APP_URL=https://meet.example.com \
#     --build-arg NEXT_PUBLIC_STREAM_VIDEO_API_KEY=xxx \
#     --build-arg NEXT_PUBLIC_STREAM_CHAT_API_KEY=xxx \
#     -t meet-ai:latest .
#
#   # Dev (via docker compose)
#   docker compose up
# ─────────────────────────────────────────────────────────────────────────────

ARG NODE_VERSION=22
ARG ALPINE_VERSION=3.21

# ─── Stage: base ─────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS base

# libc6-compat is required by some native Node addons on Alpine
RUN apk add --no-cache libc6-compat

WORKDIR /app

# ─── Stage: deps ─────────────────────────────────────────────────────────────
# Install production dependencies only.
# Layer is cached independently so code changes don't invalidate it.
FROM base AS deps

COPY package.json package-lock.json ./

# BuildKit cache mount keeps the npm cache across builds — faster CI rebuilds
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts

# ─── Stage: builder ───────────────────────────────────────────────────────────
# Full install (devDeps needed for TypeScript, ESLint, tailwind PostCSS, etc.)
# then compile the standalone Next.js bundle.
FROM base AS builder

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

COPY . .

# NEXT_PUBLIC_* vars are statically replaced in the client bundle at build time.
# They must arrive as ARGs here, not just at container runtime.
ARG NEXT_PUBLIC_APP_URL
ARG NEXT_PUBLIC_STREAM_VIDEO_API_KEY
ARG NEXT_PUBLIC_STREAM_CHAT_API_KEY

ENV NEXT_PUBLIC_APP_URL=${NEXT_PUBLIC_APP_URL}
ENV NEXT_PUBLIC_STREAM_VIDEO_API_KEY=${NEXT_PUBLIC_STREAM_VIDEO_API_KEY}
ENV NEXT_PUBLIC_STREAM_CHAT_API_KEY=${NEXT_PUBLIC_STREAM_CHAT_API_KEY}

ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production

RUN npm run build

# ─── Stage: runner ────────────────────────────────────────────────────────────
# Minimal runtime: standalone server.js + static assets only.
# No source, no devDeps, no node_modules (standalone bundle is self-contained
# except for the production deps that Next.js traces into .next/standalone).
FROM base AS runner

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Principle of least privilege: run as non-root
RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 nextjs

# Static assets served directly by the embedded server
COPY --from=builder /app/public ./public

# Next.js standalone output — owns its own node_modules subset
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static    ./.next/static

USER nextjs

EXPOSE 3000

# OCI image labels (https://github.com/opencontainers/image-spec)
LABEL org.opencontainers.image.title="Meet AI" \
      org.opencontainers.image.description="AI-native video meeting platform" \
      org.opencontainers.image.source="https://github.com/AntonioErdeljac/next15-meet-ai" \
      org.opencontainers.image.licenses="MIT"

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD wget -qO- http://localhost:3000/api/health || exit 1

CMD ["node", "server.js"]

# ─── Stage: dev ───────────────────────────────────────────────────────────────
# Lightweight target for local development.
# Source and node_modules are supplied via bind/named volumes in compose.
FROM base AS dev

ENV NODE_ENV=development
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Install all deps (devDeps needed for the dev server)
COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts

# Source is mounted at runtime — COPY here only gives IDE/linter happy path
# when building the dev image in isolation
COPY . .

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
    CMD wget -qO- http://localhost:3000/api/health || exit 1

CMD ["npm", "run", "dev"]
