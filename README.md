# Shopizer – Local CD with Docker + Colima

> **Scope**: macOS · Colima · Docker Compose · GitHub Actions · No Kubernetes · No cloud.

---

## 0. Quick-Start (Local Dev Compose)

The root [`docker-compose.yml`](docker-compose.yml) is the fastest way to run the **complete Shopizer stack** on your machine using images built from the individual repo scripts.

### Step 1 — Build each image

```bash
# From the root of your shopizer-repo checkout:
cd shopizer              && ./build-image-from-ci.sh <github-owner> shopizer
cd ../shopizer-admin        && ./build-image-from-ci.sh <github-owner> shopizer-admin
cd ../shopizer-shop-reactjs && ./build-image-from-ci.sh <github-owner> shopizer-shop-reactjs
```

This produces three local images: `shopizer:ci-latest`, `shopizer-admin:ci-latest`, and `shopizer-shop-reactjs:ci-latest`.

### Step 2 — Start all services

```bash
cd shopizer-infra
docker compose up -d
```

### Service URLs

| Service | URL |
|---|---|
| Backend (Swagger UI) | http://localhost:8080/swagger-ui.html |
| Backend (Health) | http://localhost:8080/actuator/health |
| Admin UI (Angular) | http://localhost:4200 |
| React Shop | http://localhost:3000 |
| MySQL | `localhost:3306` (internal only) |

### Default credentials

| Role | Email | Password |
|---|---|---|
| Admin | `admin@shopizer.com` | `password` |
| Customer | `john.doe@example.com` | `password123` |

### Environment variables

All env vars in `docker-compose.yml` are sensible defaults. Override them inline or with a `.env` file:

| Variable | Service | Default | Notes |
|---|---|---|---|
| `APP_BASE_URL` | admin, react | `http://localhost:8080[/api]` | Must be browser-reachable |
| `APP_MERCHANT` | react | `DEFAULT` | Merchant code |
| `APP_PAYMENT_TYPE` | react | `STRIPE` | `STRIPE` or `NUVEI` |
| `APP_STRIPE_KEY` | react | _(empty)_ | Your Stripe publishable key |
| `APP_DEFAULT_LANGUAGE` | admin | `en` | UI language |

### Stop / tear down

```bash
# Stop all containers (keep data)
docker compose stop

# Remove containers (keep volumes)
docker compose down

# Full reset including MySQL data
docker compose down -v
```

> **Difference from `deployment/docker-compose.yml`**: The root compose uses images built by the per-repo `build-image-from-ci.sh` scripts (tagged `ci-latest` / `local-latest`) and is intended for local development and testing. The `deployment/` compose is the artifact-based CD stack used by the full `deploy-local.sh` pipeline with versioned image tags.

---

## 1. High-level Architecture

```mermaid
flowchart TD
    subgraph GITHUB["☁️  GitHub Actions"]
        direction TB

        subgraph CI_GROUP["Continuous Integration"]
            CI_BE["🔨 CI Pipeline\nshopizer\nMaven · shopizer.jar"]
            CI_ADM["🔨 CI Pipeline\nshopizer-admin\nng build · dist/"]
            CI_REACT["🔨 CI/CD Pipeline\nshopizer-shop-reactjs\nnpm build · build/"]
        end

        subgraph CD_GROUP["Continuous Delivery"]
            CD_BE["📦 cd-backend.yml\nDownload JAR → docker build\ndocker save → upload tar"]
            CD_FE["📦 cd-frontend.yml (×2)\n1. Download triggering artifact\n2. Download other repo's latest\n3. Build shopizer-frontend image\n4. Upload image tar"]
        end

        CI_BE  -- "workflow_run\nshopizer-{ver}-{sha}" --> CD_BE
        CI_ADM -- "workflow_run · admin-build-N\n+ latest react build" --> CD_FE
        CI_REACT -- "workflow_run · react-build-N\n+ latest admin dist" --> CD_FE
    end

    subgraph MAC["🖥️  macOS · Colima · Docker"]
        SCRIPT["🚀 deploy-local.sh\ngh run download\ndocker load × 2\ndocker compose up -d"]

        subgraph COMPOSE["Docker Compose Stack"]
            MYSQL["🗄️ MySQL 8\n:3306 internal"]
            BACKEND["☕ shopizer-backend\n:8080"]
            FRONTEND["🌐 shopizer-frontend\n:8081  Admin (Angular)\n:8082  Shop  (React)"]
        end
    end

    CD_BE -- "backend image tar\nartifact" --> SCRIPT
    CD_FE -- "frontend image tar\nartifact" --> SCRIPT

    SCRIPT --> BACKEND
    SCRIPT --> FRONTEND

    BACKEND -->|"JDBC"| MYSQL
    FRONTEND -->|"/api/ proxy"| BACKEND

    %% ── Subgraph backgrounds (lighter fills, rich border, dark label text) ──
    style GITHUB   fill:#dbeafe,stroke:#1d4ed8,stroke-width:2px,color:#1e3a8a
    style CI_GROUP fill:#bbf7d0,stroke:#15803d,stroke-width:1.5px,color:#14532d
    style CD_GROUP fill:#fed7aa,stroke:#c2410c,stroke-width:1.5px,color:#7c2d12
    style MAC      fill:#fecdd3,stroke:#be123c,stroke-width:2px,color:#881337
    style COMPOSE  fill:#fef08a,stroke:#ca8a04,stroke-width:1.5px,color:#713f12

    %% ── CI nodes: dark green fill, white text ────────────────────────────────
    style CI_BE    fill:#15803d,stroke:#14532d,stroke-width:1px,color:#ffffff
    style CI_ADM   fill:#15803d,stroke:#14532d,stroke-width:1px,color:#ffffff
    style CI_REACT fill:#15803d,stroke:#14532d,stroke-width:1px,color:#ffffff

    %% ── CD nodes: dark orange fill, white text ───────────────────────────────
    style CD_BE    fill:#c2410c,stroke:#7c2d12,stroke-width:1px,color:#ffffff
    style CD_FE    fill:#c2410c,stroke:#7c2d12,stroke-width:1px,color:#ffffff

    %% ── Deploy script: deep amber fill, white text ───────────────────────────
    style SCRIPT   fill:#b45309,stroke:#78350f,stroke-width:1.5px,color:#ffffff

    %% ── Docker Compose nodes: dark fills, white text ─────────────────────────
    style MYSQL    fill:#0f766e,stroke:#134e4a,stroke-width:1px,color:#ffffff
    style BACKEND  fill:#1d4ed8,stroke:#1e3a8a,stroke-width:1px,color:#ffffff
    style FRONTEND fill:#6d28d9,stroke:#4c1d95,stroke-width:1px,color:#ffffff
```

---

## 2. Why Artifact-based Image Builds?

| | Artifact-based (this design) | Rebuild from source in CD |
|---|---|---|
| **What is deployed** | Exact JAR/dist tested by CI | Potentially different binary |
| **Build time** | Seconds (just `docker build`) | Minutes (full compile) |
| **Environment parity** | Guaranteed (same byte sequence) | Risk of env drift |
| **CI/CD separation** | Clean – CI owns code, CD owns delivery | CI and CD are coupled |
| **Simulates production** | Yes – prod also deploys pre-built artifacts | No |

### CI vs CD responsibilities

```
CI (Continuous Integration)           CD (Continuous Delivery)
───────────────────────────           ───────────────────────
• Compile                             • Download CI artifact
• Run unit / integration tests        • Build container image
• Static analysis / lint              • Tag and version the image
• Upload versioned artifact           • Export image as loadable tar
                                      • Start/update local containers
```

---

## 3. Directory Structure

```
docker-compose.yml             ← quick-start full-stack compose (ci-latest images)
                                  runs mysql + shopizer + shopizer-admin + shopizer-shop-reactjs

deployment/
├── .env.example                   ← copy to .env and fill in secrets
├── .env                           ← git-ignored; your actual values
├── docker-compose.yml             ← CD pipeline stack (versioned artifact-based images)
├── deploy-local.sh                ← main deployment script
├── rollback.sh                    ← tag-switch rollback script
│
├── backend/
│   └── Dockerfile                 ← artifact-based; expects shopizer.jar
│
├── frontend/                      ← combined Angular admin + React shop
│   ├── Dockerfile                 ← serves admin (8081) and react (8082)
│   └── nginx.conf                 ← two server{} blocks; no base-href changes needed
│
└── reference-workflows/           ← copy these to the respective repos
    ├── cd-admin.yml               → shopizer-admin/.github/workflows/cd-frontend.yml
    └── cd-react.yml               → shopizer-shop-reactjs/.github/workflows/cd-frontend.yml
```

---

## 4. Image Tagging Strategy

Every image is tagged three ways simultaneously:

```
shopizer-backend:latest                  ← always points to newest
shopizer-backend:3.2.5                   ← semantic version
shopizer-backend:3.2.5-a1b2c3d4         ← version + short SHA  (canonical)

shopizer-frontend:latest                 ← always points to newest combined build
shopizer-frontend:1.0.0-b2c3d4e5        ← version of the triggering app + its SHA
```

The canonical `{version}-{sha}` tag is what you put in `.env` when deploying
or rolling back. This makes it unambiguous exactly what code is running.

> **Combined frontend tag note**: `shopizer-frontend` is built by a CD workflow
> in whichever frontend repo's CI just completed. The tag uses the version and
> SHA of the **triggering** app (admin or react). The other app's content is
> always the most recent successfully built artifact.

### Version extraction per language

| Image | Source | Extraction |
|---|---|---|
| shopizer-backend | Maven `pom.xml` | `./mvnw help:evaluate -Dexpression=project.version -q -DforceStdout -pl sm-shop` |
| shopizer-frontend (admin side) | `shopizer-admin/package.json` | `node -p "require('./package.json').version"` |
| shopizer-frontend (react side) | `shopizer-shop-reactjs/package.json` | `node -p "require('./package.json').version"` |

---

## 5. Step-by-step Setup

### 5.1 One-time prerequisites

```bash
# Install Colima
brew install colima

# Install Docker CLI (no Docker Desktop needed)
brew install docker docker-compose

# Install GitHub CLI
brew install gh
gh auth login        # authenticate once

# Create a Docker context that points to Colima
colima start --cpu 2 --memory 4 --disk 60
docker context use colima
```

### 5.2 Configure the CD workflow in each repo

1. **shopizer** – already at `.github/workflows/cd-backend.yml`. Fully configured.

2. **shopizer-admin** – copy `reference-workflows/cd-admin.yml` to
   `.github/workflows/cd-frontend.yml` in the admin repo. This workflow
   downloads the admin dist **and** the latest react build, then builds the
   combined `shopizer-frontend` image.

3. **shopizer-shop-reactjs** – copy `reference-workflows/cd-react.yml` to
   `.github/workflows/cd-frontend.yml` in the react repo. This workflow
   downloads the react build **and** the latest admin dist, then builds the
   same combined `shopizer-frontend` image.

   > **CROSS_REPO_TOKEN**: both frontend CD workflows need to download artifacts
   > from the *other* repo. Add a fine-grained PAT (`CROSS_REPO_TOKEN`) to each
   > repo's secrets with **Actions (read)** permission on the counterpart repo.
   > Create at: *Settings → Developer settings → Personal access tokens →
   > Fine-grained tokens*.

   > **CI workflow name must match** `workflow_run.workflows` in the CD file:
   >
   > | Repo | CI workflow name | CD trigger value |
   > |---|---|---|
   > | shopizer | `CI Pipeline` | `"CI Pipeline"` ✔ |
   > | shopizer-admin | `CI` | `"CI"` ✔ |
   > | shopizer-shop-reactjs | `CI/CD Pipeline` | `"CI/CD Pipeline"` ✔ |

### 5.3 Ensure CI artifact names match

The `cd-frontend.yml` workflow downloads artifacts from **both** CI repos:

| Repo | CI workflow name | CI artifact name | Pattern in CD |
|---|---|---|---|
| shopizer | `CI Pipeline` | `shopizer-{version}-{sha}` | `shopizer-*` |
| shopizer-admin | `CI` | `shopizer-admin-build-{run_number}` | `shopizer-admin-build-*` |
| shopizer-shop-reactjs | `CI/CD Pipeline` | `shopizer-react-build-{run_number}` | `shopizer-react-build-*` |

All CI workflows already upload artifacts matching these patterns. ✔

> **Note on Dockerfile**: The combined frontend Dockerfile lives in
> `shopizer-infra/deployment/frontend/`. The CD workflows sparse-checkout
> that path from shopizer-infra automatically.

### 5.4 Configure deployment environment

```bash
cd deployment
cp .env.example .env
# Edit .env – set passwords and the GitHub repo names
nano .env
```

---

## 6. Local Deployment Commands

### Start the full stack

```bash
# Start Colima (skip if already running)
colima start

# Full deploy – pulls latest image tars from GitHub, loads and starts
cd deployment
./deploy-local.sh
```

### Deploy a specific version

```bash
./deploy-local.sh --backend-tag 3.2.5-a1b2c3d4
```

### Deploy both services at explicit tags

```bash
./deploy-local.sh \
  --backend-tag  3.2.5-a1b2c3d4 \
  --frontend-tag 1.0.0-b2c3d4e5
```

### Skip GitHub download (use already-loaded images)

```bash
./deploy-local.sh --skip-pull
```

### Only restart the backend

```bash
./deploy-local.sh --only-backend --backend-tag 3.2.5-a1b2c3d4
```

---

## 7. Service URLs

| Service | URL |
|---|---|
| Backend (Swagger) | http://localhost:8080/swagger-ui/index.html |
| Backend (Health) | http://localhost:8080/actuator/health |
| Admin UI | http://localhost:8081 |
| React Shop | http://localhost:8082 |
| MySQL | localhost:3306 (internal only) |

---

## 8. Logs Inspection

```bash
# All services, follow
docker compose -f deployment/docker-compose.yml logs -f

# Single service, last 100 lines
docker compose -f deployment/docker-compose.yml logs --tail 100 shopizer-backend

# Check container health status
docker inspect --format='{{.State.Health.Status}}' shopizer-backend
docker inspect --format='{{.State.Health.Status}}' shopizer-mysql
```

---

## 9. Rollback Strategy

### List locally available tags

```bash
cd deployment
./rollback.sh --list
```

Output:
```
Backend (shopizer-backend):
TAG                           CREATED         SIZE
3.2.5-a1b2c3d4                2 hours ago     185MB
3.2.4-9e8d7c6b                1 day ago       183MB
latest                        2 hours ago     185MB
```

### Roll back backend to a previous tag

```bash
./rollback.sh --backend-tag 3.2.4-9e8d7c6b
```

### Roll back the combined frontend

```bash
./rollback.sh --frontend-tag 1.0.0-9e8d7c6b
```

Each rollback:
1. Validates the tag exists locally (no download)
2. Records the current tags in `.rollback-history`
3. Updates `.env`
4. Restarts only the affected service (`docker compose up --no-deps`)

### Manual tag switch (without the script)

```bash
# Switch backend tag in .env
sed -i '' 's/^IMAGE_TAG_BACKEND=.*/IMAGE_TAG_BACKEND=3.2.4-9e8d7c6b/' deployment/.env
docker compose -f deployment/docker-compose.yml up -d --no-deps shopizer-backend

# Switch frontend tag in .env
sed -i '' 's/^IMAGE_TAG_FRONTEND=.*/IMAGE_TAG_FRONTEND=1.0.0-9e8d7c6b/' deployment/.env
docker compose -f deployment/docker-compose.yml up -d --no-deps shopizer-frontend
```

---

## 10. Teardown

```bash
# Stop all containers (keep volumes / data)
docker compose -f deployment/docker-compose.yml stop

# Remove containers (keep volumes)
docker compose -f deployment/docker-compose.yml down

# Remove containers AND all data volumes (full reset)
docker compose -f deployment/docker-compose.yml down -v

# Stop Colima VM entirely
colima stop
```

---

## 11. CI Artifact Reference (all three repos)

The `cd-frontend.yml` workflow in each frontend repo downloads BOTH artifact
patterns. No changes to the CI workflows are needed.

**shopizer-admin** (`ci.yml` – workflow name `"CI"`):

| Field | Value |
|---|---|
| Artifact name | `shopizer-admin-build-{run_number}` |
| Artifact contents | `shopizer-admin-{sha}.tar.gz` (contains `dist/` contents) |
| Used by CD | `cd-frontend.yml` in admin repo (primary) + react repo (cross-repo) |

**shopizer-shop-reactjs** (`ci-cd.yml` – workflow name `"CI/CD Pipeline"`):

| Field | Value |
|---|---|
| Artifact name | `shopizer-react-build-{run_number}` |
| Artifact contents | `build/` directory (flat, not tarred) |
| Used by CD | `cd-frontend.yml` in react repo (primary) + admin repo (cross-repo) |

> If you adjust artifact naming, update both the `upload-artifact` step in the CI
> workflow **and** the `pattern:` in **both** `cd-frontend.yml` files to stay in sync.

---

## 12. Optional Improvements

### A – Local Docker registry (push instead of tar export)

Running a local registry removes the tar export/download step. Images are
pushed from GitHub Actions self-hosted runner directly to your Mac.

```bash
# Start a local registry on your Mac
docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
```

Then in the CD workflow, replace the `Export image tar` step with:
```yaml
- name: Push to local registry
  run: |
    docker tag shopizer-backend:${{ steps.meta.outputs.image_tag }} \
               localhost:5000/shopizer-backend:${{ steps.meta.outputs.image_tag }}
    docker push localhost:5000/shopizer-backend:${{ steps.meta.outputs.image_tag }}
```

In `docker-compose.yml`:
```yaml
image: localhost:5000/shopizer-backend:${IMAGE_TAG_BACKEND:-latest}
```

> Requires a self-hosted GitHub Actions runner on your Mac to make
> `localhost:5000` reachable from the workflow.

### B – TLS via mkcert (HTTPS locally)

```bash
brew install mkcert nss
mkcert -install
mkcert localhost

# Results in: localhost.pem  localhost-key.pem
# Mount into the shopizer-frontend container and update nginx.conf to listen on 443
```

### C – Self-hosted runner (full automation)

Run a GitHub Actions self-hosted runner on your Mac to make the entire CD
workflow execute locally. Images are built, loaded, and deployed without any
manual `deploy-local.sh` invocation.

```bash
# From your GitHub repo settings → Actions → Runners → New self-hosted runner
# Follow the macOS instructions – registers as a persistent LaunchAgent
```

Change `runs-on: ubuntu-latest` to `runs-on: self-hosted` in all CD workflows.

### D – Watchtower (automatic container updates)

```yaml
# Add to docker-compose.yml for automatic rolling updates when
# new images are loaded into the local daemon
watchtower:
  image: containrrr/watchtower
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
  command: --interval 30 shopizer-backend shopizer-frontend
  restart: unless-stopped
```
