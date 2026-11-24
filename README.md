# FormFlow

A small three-tier web app (frontend, backend, database) packaged with Docker, published to Docker Hub, and deployed with a CI/CD pipeline.

Design decisions are explained in [docs/phase0-design-worksheet.md](docs/phase0-design-worksheet.md).

## Folder structure

```
formflow/
    backend/               Flask API and its Dockerfile
    frontend/              nginx, the web page and its Dockerfile
    docs/                  design worksheet and architecture diagram
    docker-compose.yml     runs all three services together
    .env.example           settings template (placeholders only)
    .gitignore             keeps .env and keys out of git
```

## One-time setup (Docker Hub)

1. Create a Docker Hub account at https://app.docker.com/signup. Your Docker ID (username) uses letters and numbers only.
2. On Docker Hub, create two public repositories under your username: `formflow-backend` and `formflow-frontend`.
3. On Docker Hub, create a personal access token with the permission Repo Read & Write. Keep it private. It is shown only once.

## Run it on your own computer

You need Docker Desktop running.

1. Copy the settings template:

   ```
   cp .env.example .env
   ```

2. Open `.env` and replace the two placeholder values: `DOCKERHUB_USER` (your Docker ID, lowercase) and `DB_PASSWORD` (any password, letters and numbers only).

3. Build and start everything:

   ```
   docker compose up --build -d
   ```

4. Open http://localhost in a browser. If port 80 is busy on your computer, set `HTTP_PORT=8080` in `.env`, run step 3 again, and open http://localhost:8080.

5. Check the version and health:

   ```
   curl http://localhost/api/version
   curl http://localhost/api/health
   ```

6. Stop the app (keeps stored messages):

   ```
   docker compose down
   ```

   To also delete the stored messages, add `-v`.

## Publish the images to Docker Hub with a version tag

Every image is tagged `sha-` plus the first 7 characters of the Git commit ID. The tag `latest` is never pushed.

```
git init
git add .
git status
git commit -m "Initial FormFlow app"
git branch -M main
export IMAGE_TAG=sha-$(git rev-parse --short=7 HEAD)
echo $IMAGE_TAG
docker login --username YOUR_DOCKER_ID
docker compose build backend frontend
docker compose push backend frontend
```

Before committing, `git status` must not list `.env`. When `docker login` asks for a password, paste the access token.

The first push is done by hand to prove the tagging strategy. From the pipeline stage onward, GitHub Actions builds and pushes every release with the same tag format.

## Secrets

No secret is stored in this repository. The real `.env` file is ignored by git. See section 2.3 of the design worksheet.
