# ─────────────────────────────────────────────────────────────────────────────
# Shopizer React Shop – artifact-based Dockerfile
#
# Build context: deployment/react/
# Expected directory at build time: deployment/react/build/
#   (placed there by the CD workflow after downloading build.tar.gz from CI)
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:1.25-alpine

ARG APP_VERSION=unknown

LABEL org.opencontainers.image.title="shopizer-react"
LABEL org.opencontainers.image.description="Shopizer React e-commerce frontend"
LABEL org.opencontainers.image.version="${APP_VERSION}"

RUN rm -rf /usr/share/nginx/html/*

# Copy pre-built React build/
COPY build/ /usr/share/nginx/html/

# Copy custom nginx config (handles React routing + API proxy)
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO/dev/null http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
