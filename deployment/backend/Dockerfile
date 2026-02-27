# ─────────────────────────────────────────────────────────────────────────────
# Shopizer Backend – artifact-based Dockerfile
#
# Build context: deployment/backend/
# Expected file at build time: deployment/backend/shopizer.jar
#   (placed there by the CD workflow after downloading from CI artifacts)
#
# Why artifact-based?
#   The JAR built by CI is the exact same binary that was tested.
#   Rebuilding from source here would duplicate CI work, risk environment
#   differences, and break the immutability guarantee.
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: verify / unpack ──────────────────────────────────────────────────
FROM eclipse-temurin:11-jre-alpine AS jarcheck

WORKDIR /validate
COPY shopizer.jar .

# Fail fast if the JAR is invalid
RUN jar tf shopizer.jar > /dev/null && echo "JAR is valid"

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM eclipse-temurin:11-jre-alpine

ARG APP_VERSION=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="shopizer-backend"
LABEL org.opencontainers.image.description="Shopizer Spring Boot backend"
LABEL org.opencontainers.image.version="${APP_VERSION}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"

# Create a non-root user
RUN addgroup -S shopizer && adduser -S shopizer -G shopizer

WORKDIR /app

# File upload / content storage directories expected by Shopizer
RUN mkdir -p /files/repos /files/store \
    && chown -R shopizer:shopizer /app /files

# Copy the pre-built JAR from Stage 1
COPY --from=jarcheck /validate/shopizer.jar app.jar
RUN chown shopizer:shopizer app.jar

USER shopizer

EXPOSE 8080

# JVM tuning for containers:
#   UseContainerSupport  – respects cgroup memory limits (JDK 8u191+, JDK 11)
#   MaxRAMPercentage     – use up to 75% of container RAM for heap
ENV JAVA_OPTS="-XX:+UseContainerSupport \
               -XX:MaxRAMPercentage=75.0 \
               -XX:+UseG1GC \
               -Djava.security.egd=file:/dev/./urandom"

# Spring-specific env vars – overridden by docker-compose / env file
ENV SPRING_PROFILES_ACTIVE=default
ENV SERVER_PORT=8080

# File storage path (referenced in Shopizer config)
ENV APP_FILES_PATH=/files

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
  CMD wget -qO- http://localhost:${SERVER_PORT}/actuator/health \
      | grep -q '"status":"UP"' || exit 1

ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
