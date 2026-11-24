# Deploying FormFlow to the Linux VM

These files put a tagged version of FormFlow on the VM and take it back if something goes wrong. The GitHub Actions pipeline (see `../docs/cicd-pipeline.md`) runs them for you on every push to `main`. You can also run them by hand.

## What each file does

| File | Runs where | What it does |
|---|---|---|
| `../infra/provision-vm.sh` | Local machine | Checks your Azure subscription, then creates the resource group, the VM and opens port 80. Asks for `yes` before anything costs money. |
| `../infra/delete-azure-resources.sh` | Local machine | Deletes the whole resource group so that Azure stops billing. |
| `vm-setup.sh` | The VM, once | Installs Docker and creates `/opt/formflow`. |
| `make-env.sh` | The VM, once | Writes the private `.env` file (permissions 600). Asks for the Docker ID and the database password, so the password never appears in a command. |
| `env-sync.sh` | The VM, by the pipeline | Reads the database password from the pipeline (standard input, never a command line). Creates `.env` if there is none. If there is one, it only checks the password matches and never overwrites it. |
| `../docker-compose.prod.yml` | The VM | Same three services as `docker-compose.yml`, but it only pulls images from Docker Hub. It has no `build` sections. |
| `deploy.sh` | The VM | Deploys one tag, checks health, and goes back by itself if the check fails. The pipeline calls this same script over SSH. |
| `rollback.sh` | The VM | Puts the VM back on an older tag. No rebuild. |

## What lives on the VM in `/opt/formflow`

| File | Meaning |
|---|---|
| `.env` | Settings and the database password. Permissions 600. Never in Git, never copied by the pipeline. |
| `previous_tag` | The tag the VM was running before the last switch. |
| `deploy-history.log` | One line per deploy or rollback: time, action, tag, result, who, which pipeline run (`run=manual` when done by hand). |

## How a deploy works (`./deploy.sh sha-1a2b3c4`)

1. Refuse anything that is not `sha-` plus 7 characters.
2. Pull both images for that tag. If a tag does not exist, stop here. Nothing has changed.
3. Save the current tag to `previous_tag`, then write the new tag into `.env`.
4. `docker compose up -d`.
5. For up to 60 seconds, ask `/api/health` for a 200 and `/api/version` for the new tag.
6. Healthy: log `OK`. Not healthy: log `FAILED`, then go back to `previous_tag` by itself and exit with an error so the pipeline run turns red.

## Rollback by hand

```
cd /opt/formflow
./rollback.sh sha-1a2b3c4     # a specific known-good tag
./rollback.sh                 # the tag saved in previous_tag
```

Or from GitHub: Actions tab > Rollback > Run workflow.

## The database rule that keeps rollback safe

Database changes may only add things. Never rename or delete a table or column that an older version still uses. See section 2.2 of the design worksheet.
