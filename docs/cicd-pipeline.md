# CI/CD pipeline

Every push to `main` builds FormFlow, tests it, publishes the images to Docker Hub and deploys that exact version to the Azure VM. If the new version is not healthy, the VM goes back to the last good version by itself and the run turns red.

Files: `.github/workflows/ci-cd.yml` (release), `.github/workflows/rollback.yml` (manual rollback), `.github/scripts/` (the checks), `deploy/` (the scripts that run on the VM).

## What happens on a push to `main`

| Step | Where it runs | What it does | Why |
|---|---|---|---|
| 1 | GitHub runner | Checks that all 7 secrets exist (names only, never values). | A missing secret is found in seconds, not after a 5 minute build. |
| 2 | GitHub runner | Works out the tag `sha-` plus the first 7 characters of the commit. | One tag points to one commit, so `/api/version` on the VM tells you exactly which code is live. `latest` is never used. |
| 3 | GitHub runner | Builds the backend and frontend images. The tag is baked in as `APP_VERSION`. | The running app can report its own version. |
| 4 | GitHub runner | Starts the whole app (database, backend, frontend) as a throwaway copy with a random password. | This is the test environment. It costs nothing and is deleted at the end of the run. |
| 5 | GitHub runner | Smoke tests: `/api/health` is 200 and the database is up, backend and frontend report the new tag, a form entry is saved and read back, an empty entry is rejected. | If any check fails, nothing is pushed and nothing is deployed. |
| 6 | GitHub runner | Pushes both images to Docker Hub, unless that tag already exists there. | A tag is never pushed twice. |
| 7 | GitHub runner to VM | Opens SSH after checking the VM's host key against a pinned fingerprint. | Stops a fake server taking the VM's place. |
| 8 | VM | Copies the compose file and deploy scripts. Never the `.env`. | The `.env` holds the database password and lives only on the VM. |
| 9 | VM | `env-sync.sh` checks the `DB_PASSWORD` secret equals the password in the VM's `.env`. It never overwrites it. | Postgres keeps the password it was first started with. A silent change would lock the app out of its own database. |
| 10 | VM | `deploy.sh` pulls the images, switches the tag, starts the containers and waits up to 60 seconds for `/api/health` and `/api/version`. If it fails, it returns to the previous tag by itself. | Automatic rollback. |
| 11 | GitHub runner | Checks the public address from outside: health, backend tag and frontend tag. If this fails, the pipeline runs `rollback.sh` on the VM. | Proves that visitors, not just the VM, see the new version. |

The run summary page shows the tag and the result. The last lines of `deploy-history.log` from the VM are printed at the end of every run.

## Secrets

Set under the repository **Settings > Secrets and variables > Actions**. The values are never in the repository, never printed in logs and never passed on a command line.

| Secret | What it is | Used for |
|---|---|---|
| `DOCKERHUB_USERNAME` | Docker ID | Logging in, naming the images, writing the VM `.env` on a brand new VM. |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Read and Write) | Pushing images. |
| `VM_HOST` | Public IP of the VM | SSH and the outside health check. |
| `VM_USER` | Login name on the VM | SSH. |
| `VM_SSH_PRIVATE_KEY` | A key made only for deployments | SSH. Different from the key used by a person. |
| `VM_HOST_FINGERPRINT` | Fingerprint of the VM's host key | Detects a fake server. |
| `DB_PASSWORD` | Database password | Checked against the VM's `.env`. |

To rotate a secret: change it on the VM and in GitHub together, then re-run the pipeline.

## Rolling back

**Automatic.** `deploy.sh` goes back to the last good tag if the new one is not healthy within 60 seconds. The pipeline then fails, so the run is red.

**Manual.** Actions tab > **Rollback** > Run workflow. Type a tag such as `sha-c43eb34`, or leave it empty to go back to the version that was live before the last deploy. The workflow uses the `rollback.sh` already on the VM, so it works even if the newest commit is broken. It checks the public address afterwards.

Old images stay on Docker Hub, so a rollback needs no rebuild. See `deploy/README.md` for the rollback by hand on the VM.

## When a run fails

| Message | Meaning | Fix |
|---|---|---|
| `Missing GitHub Actions secrets: ...` | A secret name is missing or misspelled. | Add it with exactly that name. |
| `SMOKE TEST FAILED: ...` | The new version is broken. Nothing was pushed. | Read the line, fix the code, push again. |
| `The VM presented a different host key` | The fingerprint secret does not match the VM. | If you rebuilt the VM on purpose, update `VM_HOST_FINGERPRINT`. If not, stop and find out why. |
| `The VM refused the deploy key` | The public half of the deploy key is not on the VM. | Add it to `~/.ssh/authorized_keys` on the VM. |
| `Could not reach ... to read its host key` | The VM is stopped or port 22 is closed. | Start the VM and check the network rules. |
| `STOP: the GitHub secret DB_PASSWORD does NOT match` | The secret differs from the password in the VM `.env`. Nothing was changed. | Update the secret to the VM's value. |
| `Pull failed ... Nothing changed.` | The tag is not on Docker Hub. | Check the tag and the Docker Hub repository names. |
| `FAILED: sha-... did not become healthy` | The new version started but failed its health check. The VM went back by itself. | Read the container logs, fix, push again. |
| `Public check failed: ...` | Visitors cannot see the new version. The pipeline went back. | Check the VM network rule for port 80. |

## Known limits

- One VM: `docker compose up -d` replaces the containers, so there is a few seconds of interruption during a release. Removing it needs two copies running side by side, which is what the blue-green project does.
- Port 22 is open to the internet because GitHub-hosted runners use addresses that change from run to run, so it cannot be limited to one address. Password login is off on the VM, so only a private key opens it, and the pipeline uses a key made only for deployments.
- Database changes may only add things. Never rename or delete a column an older version still uses, or a rollback will break.
- The throwaway copy in step 4 proves the images work together. It is not an exact copy of the VM (different network, no real data).
