# =============================================================================
# Shopizer Combined Frontend – artifact-based Dockerfile
#
# Serves Angular Admin (port 8081) AND React Shop (port 8082) from a single
# Nginx process, eliminating the need for two separate frontend containers.
#
# Build context: deployment/frontend/
# Required at build time (placed by the CD workflow):
#   admin-dist/   ←  Angular dist/ output  (from shopizer-admin CI)
#   react-build/  ←  React build/ output   (from shopizer-shop-reactjs CI)
#
# Why a single container?
#   • Halves the number of container processes for static file serving
#   • One healthcheck, one restart policy, one log stream to monitor
#   • Admin and shop are always deployed together – version skew is explicit
#     (the image tag encodes which CI run produced this image)
#
# Ports:
#   8081  →  /usr/share/nginx/html/admin  (Angular SPA)
#   8082  →  /usr/share/nginx/html/react  (React SPA)
# =============================================================================
FROM nginx:1.25-alpine

ARG APP_VERSION_ADMIN=unknown
ARG APP_VERSION_REACT=unknown

LABEL org.opencontainers.image.title="shopizer-frontend"
LABEL org.opencontainers.image.description="Shopizer combined frontend: Angular admin (8081) + React shop (8082)"
LABEL shopizer.admin.version="${APP_VERSION_ADMIN}"
LABEL shopizer.react.version="${APP_VERSION_REACT}"

# Remove the default Nginx welcome page and default conf.d config
RUN rm -rf /usr/share/nginx/html \
 && rm -f /etc/nginx/conf.d/default.conf

# Create document roots
RUN mkdir -p /usr/share/nginx/html/admin \
          /usr/share/nginx/html/react

# Copy pre-built frontend artifacts
COPY admin-dist/  /usr/share/nginx/html/admin/
COPY react-build/ /usr/share/nginx/html/react/

# Replace the entire nginx.conf (defines events + http with two server blocks)
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8081 8082

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO/dev/null http://localhost:8081/ \
   && wget -qO/dev/null http://localhost:8082/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
