# ─────────────────────────────────────────────────────────────────────────────
# Shopizer Admin UI – artifact-based Dockerfile (Angular)
#
# Build context: deployment/admin/
# Expected directory at build time: deployment/admin/dist/
#   (placed there by the CD workflow after downloading dist.tar.gz from CI)
#
# Why not build Angular here?
#   Angular builds are slow (2-5 min), depend on node_modules,
#   and the CI-produced dist/ is already verified by CI tests.
#   Using the pre-built artifact guarantees what was tested = what is deployed.
# ─────────────────────────────────────────────────────────────────────────────
FROM nginx:1.25-alpine

ARG APP_VERSION=unknown

LABEL org.opencontainers.image.title="shopizer-admin"
LABEL org.opencontainers.image.description="Shopizer Angular Admin UI"
LABEL org.opencontainers.image.version="${APP_VERSION}"

# Remove default nginx content
RUN rm -rf /usr/share/nginx/html/*

# Copy pre-built Angular dist
COPY dist/ /usr/share/nginx/html/

# Copy custom nginx config (handles Angular routing + API proxy)
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO/dev/null http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
