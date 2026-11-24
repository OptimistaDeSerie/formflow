# Phase 0 Design Worksheet: FormFlow

Project: Dockerized 3-Tier App with Full CI/CD (project for everyone)
Group: 5
Stack: Docker, Docker Compose, Docker Hub, GitHub Actions, Linux VM on Azure

## 1. The contradiction we are solving

The brief pulls in two directions. The founder wants changes shipped continuously until demo day. The founder also wants certainty about what is running, a fast way back when a deploy breaks, and no money spent on a second full staging environment.

Our answer in one line: ship often, but make every release a small, labelled, checked and reversible package.

| The brief wants | What our design does about it |
|---|---|
| Ship often | Pushing to the main branch triggers the whole pipeline automatically. Nobody copies files by hand. |
| Know exactly what is running | Every image carries an unchangeable tag, and the running app reports its own tag. |
| Fast way back | Old images stay in Docker Hub, so going back is one command with no rebuild. |
| No paid staging | The pipeline starts a throwaway copy of the whole stack inside the free GitHub runner and tests it before anything reaches the server. |

## 2.1 Tier boundaries

![Architecture diagram](architecture.png)

| Container | What lives in it | Who can reach it | Why it is its own container |
|---|---|---|---|
| frontend | nginx, the web page, and a rule that forwards /api/ calls to the backend | The internet, on port 80 only | It is the only public entry point. It is small and changes the most often. |
| backend | The Flask API: input checks, business rules, and the only code that talks to the database | Only the frontend (over frontend_net) | It holds the database login, so it must never face the internet. |
| db | Postgres 16 and a named volume called db_data | Only the backend (over backend_net) | It holds the data. It has no route to or from the internet at all. |

Why not combine them into one container:

1. Change one thing without touching the rest. Changing the page text rebuilds only the frontend image. The backend and the data are not touched.
2. Smaller blast radius. The frontend is not on the same network as the database, so a mistake or attack on the frontend cannot reach the data directly.
3. Each piece uses the right tool. nginx, Python and Postgres each use their own official base image, and each is updated on its own.
4. Containers are disposable, data is not. The data lives in the db_data volume, so replacing any container (a deploy or a rollback) never deletes data.
5. Rollback can be precise. Each tier can be put back to a known version on its own if needed.

Networks:

- frontend_net connects frontend and backend.
- backend_net connects backend and db. It is marked internal, which means Docker gives it no connection to the internet in either direction.
- The backend is on both networks. The frontend and the database share no network, so they cannot talk to each other.
- Only the frontend publishes a port to the outside world, and only port 80. The public address is http://VM-IP with nothing after it.

## 2.2 Versioning and tagging strategy

### Tag format

```
<dockerhub-user>/formflow-frontend:sha-a1b2c3d
<dockerhub-user>/formflow-backend:sha-a1b2c3d
```

The tag is the word sha, a dash, and the first 7 characters of the Git commit ID. That commit ID is a fingerprint of the exact code, so the tag points to exactly one version of the code forever.

Rules:

- One commit gives one tag, used on both images, so the frontend and backend versions always match.
- A tag is never pushed twice. Once sha-a1b2c3d exists, it is never overwritten.
- The tag latest is never pushed and never deployed. A server told to run "latest" cannot say which version it is running.
- The tag is baked into each image when it is built. The backend returns it at /api/version and the frontend writes it to /version.txt.

### How anyone can tell what is live right now

1. In a browser: the footer of the site shows the frontend version and the backend version.
2. With one command: `curl http://VM-IP/api/version`
3. On the server: `docker ps --format 'table {{.Names}}\t{{.Image}}'` shows the full image names with tags.
4. In the deploy log: `/opt/formflow/deploy-history.log` gets one line per deploy or rollback with the time, the tag, and which pipeline run did it.

### How a release flows (no staging server)

1. A developer pushes to the main branch.
2. The pipeline builds both images in the free GitHub runner and tags them sha-xxxxxxx.
3. The pipeline starts the whole stack inside the runner as a throwaway copy and runs smoke tests: /api/health must return 200, and a form entry must be saved and read back. This copy plays the role of staging and costs nothing.
4. Only if step 3 passes are the images pushed to Docker Hub.
5. The pipeline connects to the VM over SSH. It saves the current tag as previous_tag, writes the new tag into the server's .env file, then runs `docker compose pull` and `docker compose up -d`.
6. The pipeline checks http://VM-IP/api/health and checks that /api/version equals the new tag. It retries for about 60 seconds.
7. If that check fails, the pipeline rolls back to previous_tag by itself and the pipeline run is marked as failed so the team sees it.

### Rollback procedure, step by step

Why it is fast and reliable: the old images are still in Docker Hub, so nothing is rebuilt, and the database volume is not touched.

1. Find the last good tag: `cat /opt/formflow/previous_tag` or read deploy-history.log.
2. Run the rollback. Either press the manual Rollback workflow in GitHub Actions and type the tag, or log in to the VM and run `/opt/formflow/rollback.sh sha-xxxxxxx`.
3. The script writes that tag into .env, then runs `docker compose pull` and `docker compose up -d`.
4. Verify: `curl http://VM-IP/api/version` shows the old tag, and `curl http://VM-IP/api/health` returns 200.
5. The script appends a ROLLBACK line to deploy-history.log.

Automatic or manual:

- Automatic: the health check in step 6 of the release flow fails, so the pipeline rolls back by itself.
- Manual: a person notices a problem the health check cannot see, for example a wrong label on a button, and starts the Rollback workflow.

### The database rule that keeps rollback safe

Database changes may only add things (a new table or column). They must never rename or delete something the older code still uses. The app today only runs CREATE TABLE IF NOT EXISTS. If this rule is broken, an old version could crash against a newer database, so any destructive change needs its own planned migration and cannot go out as a normal release.

## 2.3 Secrets handling plan

| Secret | Used by | On a developer machine | In GitHub (pipeline) | On the VM |
|---|---|---|---|---|
| DB_PASSWORD | db and backend | `.env` file, ignored by git | Actions secret DB_PASSWORD | `/opt/formflow/.env`, permissions 600, written by the pipeline at deploy time |
| DOCKERHUB_TOKEN (an access token, not the account password) | Pipeline, to push images | Not needed | Actions secret DOCKERHUB_TOKEN | Not stored. Images are public and hold no secrets, so the VM pulls without logging in |
| DOCKERHUB_USERNAME | Naming the images | `.env` file | Actions secret DOCKERHUB_USERNAME | In `.env` as DOCKERHUB_USER |
| VM_SSH_PRIVATE_KEY (a key made only for deployments) | Pipeline, to log in to the VM | Not needed | Actions secret VM_SSH_PRIVATE_KEY | The matching public half sits in authorized_keys |
| VM_HOST and VM_USER | Pipeline, to find the VM | Not needed | Actions secrets VM_HOST and VM_USER | Not applicable |

Settings that are not secret (DB_NAME, DB_USER, HTTP_PORT) also live in `.env` so there is one place to change them.

Statement: no secret is hardcoded in any Dockerfile, in docker-compose.yml, in the application code, or in the workflow files, and none is committed to the repository. The repository contains only `.env.example`, which holds placeholder words. The real `.env` is listed in `.gitignore`. docker-compose.yml refuses to start if a required value is missing, so a forgotten secret fails loudly and is never replaced by a quiet default.

If a secret is ever committed by mistake, deleting it from the file is not enough. It must be changed (rotated) straight away, because it stays visible in the repository history.

## Notes where the build differs from this worksheet

None yet. Any difference found during the build gets a one-line note here with the reason.
