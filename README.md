# FormFlow

FormFlow is a small three-tier web application (frontend, backend and database) that runs in Docker containers. Its images are published to Docker Hub with versioned tags, and a GitHub Actions pipeline builds, tests, publishes and deploys every change to a Linux virtual machine on Azure. It was built for the capstone project "Dockerized 3-Tier App with Full CI/CD".

While the VM is running, the application is available at http://20.106.75.210 (port 80 only). The Azure resources are deleted after the demonstration, so this address stops working after that.

## Contents

1. [What the application does](#1-what-the-application-does)
2. [Design](#2-design)
3. [Repository layout](#3-repository-layout)
4. [Configuration](#4-configuration)
5. [Run it on a local computer](#5-run-it-on-a-local-computer)
6. [Versioning and tagging](#6-versioning-and-tagging)
7. [Deploy to Azure](#7-deploy-to-azure)
8. [CI/CD pipeline](#8-cicd-pipeline)
9. [Rollback](#9-rollback)
10. [Challenges and solutions](#10-challenges-and-solutions)
11. [Where to find each required item](#11-where-to-find-each-required-item)
12. [Clean up and cost](#12-clean-up-and-cost)
13. [Screenshots](#13-screenshots)

## 1. What the application does

The web page has a form with three fields: name, email and message. When the form is sent, the Flask API checks the input and saves the message in a Postgres database. The page also shows the latest messages, and its footer shows the version of the frontend and the version of the backend, so the running version can always be read from the page itself.

| Address | Method | What it does |
|---|---|---|
| `/` | GET | The web page, served by nginx. |
| `/version.txt` | GET | The frontend version tag. |
| `/api/version` | GET | The backend version tag, as JSON. |
| `/api/health` | GET | Returns 200 only if the backend can reach the database. Returns 503 otherwise. |
| `/api/submissions` | POST | Saves a message. Returns 201, or 400 if a field is empty or too long. |
| `/api/submissions` | GET | Returns the latest 20 messages. |

Docker Hub repositories: [formflow-backend](https://hub.docker.com/r/optimistadeserie/formflow-backend) and [formflow-frontend](https://hub.docker.com/r/optimistadeserie/formflow-frontend).

## 2. Design

![Architecture diagram](docs/architecture.png)

The application is split into three containers, and each one has one job:

- **frontend** (nginx) is the only container that is published to the internet, and only on port 80. It serves the page and passes `/api/` requests on to the backend.
- **backend** (Flask with gunicorn, port 5000) is the only code that talks to the database. It has no published port.
- **db** (Postgres 16) stores the messages in a volume called `db_data`. It has no published port.

Two Docker networks keep the tiers apart. `frontend_net` joins the frontend and the backend. `backend_net` joins the backend and the database, and it is marked `internal`, so it has no connection to the internet. The frontend and the database share no network.

The reasons for these choices, the tagging strategy, the rollback procedure and the secrets plan are in the [design worksheet](docs/phase0-design-worksheet.md). The diagram has its own page with a short legend: [docs/architecture.md](docs/architecture.md).

## 3. Repository layout

```
formflow/
    .github/
        workflows/
            ci-cd.yml            builds, tests, pushes and deploys on every push to main
            rollback.yml         manual rollback, started from the Actions tab
        scripts/                 the checks that the workflows call
    backend/                     Flask API and its Dockerfile
    frontend/                    nginx, the web page and its Dockerfile
    deploy/                      scripts that run on the VM, and their README
    infra/                       scripts that create and delete the Azure resources
    docs/                        design worksheet, architecture, pipeline notes,
                                 incident report and screenshots
    docker-compose.yml           runs all three services together (builds the images)
    docker-compose.prod.yml      the same services for the VM (only pulls images)
    .env.example                 settings template with placeholders only
    .gitignore                   keeps .env and keys out of git
```

## 4. Configuration

All settings come from environment variables, which Docker Compose reads from a file called `.env`. The real `.env` is never committed. The repository only has `.env.example`, which holds placeholder values.

| Variable | Meaning |
|---|---|
| `DOCKERHUB_USER` | The Docker ID, in lowercase. It becomes part of the image names. |
| `IMAGE_TAG` | The version to build or run. It is `local-dev` on a local computer and `sha-` plus 7 characters in the pipeline and on the VM. |
| `DB_NAME` | The database name. |
| `DB_USER` | The database user. |
| `DB_PASSWORD` | The database password. Letters and numbers only. |
| `HTTP_PORT` | The port that the website uses. Keep 80 on the VM. |

| Container | Port | Published to the internet |
|---|---|---|
| frontend | 80 | Yes, the only one |
| backend | 5000 | No |
| db | 5432 | No |

docker-compose.yml stops with a clear message if a required value is missing, so a forgotten setting never falls back to a quiet default.

### Secrets

No secret is stored in this repository. The real `.env` file is ignored by git, the pipeline reads its secrets from GitHub, and the VM keeps its `.env` with permissions 600. The secrets plan is in section 2.3 of the [design worksheet](docs/phase0-design-worksheet.md), and the 7 pipeline secrets are listed in section 8.

## 5. Run it on a local computer

Requirements: Git, and Docker Desktop running.

**Step 1.** Clone the repository and open the folder.

```
git clone https://github.com/OptimistaDeSerie/formflow.git
```

```
cd formflow
```

**Step 2.** Copy the settings template.

Mac or Linux:

```
cp .env.example .env
```

Windows (Command Prompt):

```
copy .env.example .env
```

Windows (PowerShell):

```
Copy-Item .env.example .env
```

**Step 3.** Open `.env` in an editor and replace the two placeholder values: `DOCKERHUB_USER` (the Docker ID, in lowercase) and `DB_PASSWORD` (any password with letters and numbers only).

**Step 4.** Build and start all three services.

```
docker compose up --build -d
```

**Step 5.** Open http://localhost in a browser. If port 80 is busy, set `HTTP_PORT=8080` in `.env`, run step 4 again and open http://localhost:8080.

**Step 6.** Check the health and the version. On Windows PowerShell, write `curl.exe` instead of `curl`.

```
curl http://localhost/api/health
```

```
curl http://localhost/api/version
```

**Step 7.** Stop the application. The stored messages are kept. Add `-v` to also delete them.

```
docker compose down
```

## 6. Versioning and tagging

Every image is tagged `sha-` followed by the first 7 characters of the Git commit ID, for example `sha-0f16681`. The same tag is used on both images, a tag is never pushed twice, and the tag `latest` is never pushed or deployed. The tag is built into each image, so the running application can report it.

The version that is live can be read in four ways:

1. The footer of the web page shows the frontend and backend versions.
2. `curl http://20.106.75.210/api/version` returns the backend version.
3. `docker ps --format 'table {{.Names}}\t{{.Image}}'` on the VM shows the image names with their tags.
4. `/opt/formflow/deploy-history.log` on the VM has one line for every deploy and rollback.

The first push to Docker Hub was done by hand, with the tag `sha-c43eb34`, to prove the tagging strategy. From the pipeline onward, GitHub Actions builds and pushes every release.

## 7. Deploy to Azure

The scripts in `infra/` and `deploy/` create the VM and put the application on it. They need `bash`. On Windows, run them in Git Bash, in WSL or in Azure Cloud Shell. `ssh` and `scp` are included in current versions of Windows. The details of every script are in [deploy/README.md](deploy/README.md).

**Step 1. Create the VM.** This needs the Azure CLI, already logged in with `az login`.

```
bash infra/provision-vm.sh
```

Before it creates anything, the script checks the Azure login and the Azure services, and then it asks Azure's own free check which region and VM size the subscription may create. It prints the price estimate and the plan, and it creates the resources only after `yes` is typed. It creates one resource group, one Ubuntu 22.04 VM, and opens port 22 (SSH, key login only) and port 80 (the website). At the end it prints the public IP address. The region and size can be set with `REGION` and `SIZE` when the defaults are refused. Section 10 explains why this check exists.

**Step 2. Install Docker on the VM, once.** Replace `VM_IP` with the public IP address.

```
scp deploy/vm-setup.sh azureuser@VM_IP:/tmp/vm-setup.sh
```

```
ssh azureuser@VM_IP 'bash /tmp/vm-setup.sh'
```

**Step 3. Copy the deploy files to the VM.**

```
scp docker-compose.prod.yml deploy/deploy.sh deploy/rollback.sh deploy/make-env.sh deploy/env-sync.sh azureuser@VM_IP:/opt/formflow/
```

**Step 4. Create the private `.env` file on the VM, once.** Log in to the VM again, because the new login is what lets Docker run without `sudo`. The next three commands run on the VM. The script asks for the Docker ID and the database password, and the password is typed hidden.

```
ssh azureuser@VM_IP
```

```
cd /opt/formflow
```

```
chmod +x *.sh
```

```
./make-env.sh
```

**Step 5. Deploy a version that exists on Docker Hub.** This command also runs on the VM. The tag `sha-c43eb34` is the first one that was pushed.

```
./deploy.sh sha-c43eb34
```

The script pulls both images, writes the tag into `.env`, starts the containers and waits up to 60 seconds for `/api/health` and `/api/version`. Open `http://VM_IP` in a browser to see the application.

After the first deploy, the pipeline in section 8 does all of this automatically on every push.

## 8. CI/CD pipeline

Every push to `main` runs `.github/workflows/ci-cd.yml`, which has two jobs:

1. **Build, test, push.** It checks that all 7 secrets exist, works out the tag, builds both images, starts the whole application as a throwaway copy inside the GitHub runner with a random password, and runs the smoke tests. If every test passes, it pushes both images to Docker Hub. This throwaway copy is the staging environment, and it costs nothing.
2. **Deploy to the VM.** It opens SSH after checking the VM's host key against a pinned fingerprint, copies the deploy files (never the `.env`), checks that the database password secret matches the VM, deploys the exact tag, and then checks the public address from outside. If the check fails, the VM goes back to the previous version and the run turns red.

The full table of steps, the failure messages and the known limits are in [docs/cicd-pipeline.md](docs/cicd-pipeline.md).

### Setting the pipeline up

The pipeline needs 7 secrets, which are set in the repository under Settings, Secrets and variables, Actions. Their values are never written in the repository or printed in the logs.

| Secret | What it holds |
|---|---|
| `DOCKERHUB_USERNAME` | The Docker ID. |
| `DOCKERHUB_TOKEN` | A Docker Hub access token with Read and Write permission. |
| `VM_HOST` | The public IP address of the VM. |
| `VM_USER` | The login name on the VM, `azureuser`. |
| `VM_SSH_PRIVATE_KEY` | The private half of a key made only for deployments. |
| `VM_HOST_FINGERPRINT` | The fingerprint of the VM's SSH host key. |
| `DB_PASSWORD` | The database password, equal to the one in the VM's `.env`. |

**Make the deploy key.** It is a separate key from the one that a person uses.

```
ssh-keygen -t ed25519 -f ~/.ssh/formflow_deploy -N ""
```

**Put its public half on the VM.**

Mac or Linux:

```
cat ~/.ssh/formflow_deploy.pub | ssh azureuser@VM_IP 'cat >> ~/.ssh/authorized_keys'
```

Windows (PowerShell):

```
type $env:USERPROFILE\.ssh\formflow_deploy.pub | ssh azureuser@VM_IP "cat >> ~/.ssh/authorized_keys"
```

**Read the host key fingerprint of the VM.**

```
ssh azureuser@VM_IP "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
```

The output looks like `256 SHA256:... root@... (ED25519)`. The secret `VM_HOST_FINGERPRINT` is the part that starts with `SHA256:`, copied exactly, with nothing before or after it.

**Copy the private key to the clipboard.** This way the key never appears on the screen. Paste it into the secret `VM_SSH_PRIVATE_KEY`, including the BEGIN and END lines.

Mac:

```
pbcopy < ~/.ssh/formflow_deploy
```

Windows (PowerShell):

```
Get-Content $env:USERPROFILE\.ssh\formflow_deploy | Set-Clipboard
```

## 9. Rollback

A rollback puts the VM back on an older version. It needs no rebuild, because the old images stay on Docker Hub, and the database volume is not touched.

**Automatic.** If a new version is not healthy within 60 seconds, `deploy.sh` goes back to the previous tag by itself and the pipeline run fails. If the public check fails afterwards, the pipeline runs `rollback.sh` on the VM.

**Manual, from GitHub.**

1. Open the repository, click the **Actions** tab and click **Rollback** in the left list.
2. Click **Run workflow**.
3. Type the tag to go back to, for example `sha-400142c`. Leave the box empty to go back to the tag saved in `previous_tag`.
4. Click the green **Run workflow** button inside the panel.

**Manual, on the VM.** Log in with `ssh azureuser@VM_IP` first, then run:

```
cd /opt/formflow
```

```
./rollback.sh sha-400142c
```

**Check the result.** The backend version must be the older tag, and the deploy history must have a new `ROLLBACK` line.

```
curl http://20.106.75.210/api/version
```

```
tail -n 3 /opt/formflow/deploy-history.log
```

**The rollback test.** I performed the rollback once on the live VM, from `sha-0f16681` back to `sha-400142c`, using the manual workflow with the tag typed in. Screenshots 40 to 45 show the state before, the workflow, the finished run and the state after.

Database changes may only add things, such as a new table or column, and must never rename or delete something that an older version still uses. Otherwise an old version could fail against a newer database.

## 10. Challenges and solutions

| Problem | What I did |
|---|---|
| Azure refused to create the VM. Every region and size in the list was either blocked for the new subscription or had a quota of 0 cores (screenshot 17). | `infra/provision-vm.sh` now asks Azure's own free check, which includes the core quota, for each region and size before it creates anything. I added newer sizes to the list, and the check passed for Standard_D2ads_v6 in West US 3, which is where the VM runs. The full write-up is in [docs/incident-report.pdf](docs/incident-report.pdf). |
| The pipeline has to log in to the VM over SSH, but GitHub runners have no fixed IP address, so port 22 cannot be limited to one address. | Port 22 stays open, but password login is off, so only a key opens it. The pipeline uses its own deploy key, and it checks the VM's host key against a pinned fingerprint (the secret `VM_HOST_FINGERPRINT`) before it sends anything. |
| Postgres keeps the password it was first started with. A different `DB_PASSWORD` secret would lock the backend out of its own database, and a rollback would not fix that. | `deploy/env-sync.sh` never overwrites the VM's `.env`. It only checks that the secret matches, and it stops the pipeline with a clear message if they differ. |
| The backend container is replaced on every deploy and rollback, and the new container gets a new internal address. | `frontend/nginx.conf` asks Docker's DNS again every 10 seconds, so nginx follows the new address and does not keep pointing at the old one. |
| A brand-new VM is busy with its own first-boot updates, and that locks `apt`. | `deploy/vm-setup.sh` waits for the first-boot tasks to finish and tries `apt` again if it is still busy. |
| An image built on an Apple silicon computer would have a different processor architecture from the Azure VM, and it would not start there. | `docker-compose.yml` sets `platform: linux/amd64`, so the images match the VM wherever they are built. |

## 11. Where to find each required item

| Required item | Where it is |
|---|---|
| Dockerfiles | `backend/Dockerfile` and `frontend/Dockerfile` |
| docker-compose.yml | `docker-compose.yml` (local) and `docker-compose.prod.yml` (the VM) |
| GitHub Actions workflow | `.github/workflows/ci-cd.yml` and `.github/workflows/rollback.yml`, with the checks in `.github/scripts/` |
| Completed worksheet | [docs/phase0-design-worksheet.md](docs/phase0-design-worksheet.md) |
| Documentation of architecture, configuration and deployment | This README, [docs/architecture.md](docs/architecture.md), [docs/cicd-pipeline.md](docs/cicd-pipeline.md) and [deploy/README.md](deploy/README.md) |
| Screenshots of a successful deploy | Screenshots 27 to 30 (deployed by hand) and 36 to 39 (deployed by the pipeline) |
| Screenshots of a completed rollback | Screenshots 40 to 45 |
| Incident report | [docs/incident-report.pdf](docs/incident-report.pdf) |
| Public IP address, port 80 only | http://20.106.75.210 while the VM is running |
| All scripts and configuration in one link | This repository |

## 12. Clean up and cost

The VM costs about $0.114 per hour while it is running, plus small hourly charges for its disk and public IP address. Stopping the VM from the operating system does not stop the billing. To stop the compute charge and keep the VM, deallocate it:

```
az vm deallocate --resource-group formflow-rg --name formflow-vm
```

To start it again:

```
az vm start --resource-group formflow-rg --name formflow-vm
```

When the project is finished, delete everything. This removes the VM, its disk, its public IP address and its network:

```
bash infra/delete-azure-resources.sh
```

## 13. Screenshots

The screenshots are grouped by stage. The file names match the files in `docs/Screenshots`.

### Build and run locally

![Screenshot 1: The base project open in VS Code.](docs/Screenshots/1-base-image-of-vscode.png)

*Screenshot 1. The base project open in VS Code.*

![Screenshot 2: The docker-compose.yml file in VS Code.](docs/Screenshots/2-docker-compose-vscode.png)

*Screenshot 2. The docker-compose.yml file in VS Code.*

![Screenshot 3: Git initialised in the project folder.](docs/Screenshots/3-git-initialization-.png)

*Screenshot 3. Git initialised in the project folder.*

![Screenshot 4: The application loading in the browser.](docs/Screenshots/4-browser-loading-app.png)

*Screenshot 4. The application loading in the browser.*

![Screenshot 5: A message sent successfully through the form in the browser.](docs/Screenshots/5-message-sent-success-in-browser.png)

*Screenshot 5. A message sent successfully through the form in the browser.*

![Screenshot 6: The health and version checks in the terminal.](docs/Screenshots/6-terminal-health-and-version-check.png)

*Screenshot 6. The health and version checks in the terminal.*

![Screenshot 7: The git status output before the first commit.](docs/Screenshots/7-git-status.png)

*Screenshot 7. The git status output before the first commit.*

### Version tag and Docker Hub

![Screenshot 8: Making the image tag from the commit ID.](docs/Screenshots/8-making-the-image-tag.png)

*Screenshot 8. Making the image tag from the commit ID.*

![Screenshot 9: Building the backend and frontend images.](docs/Screenshots/9-building-the-backend-and-frontend.png)

*Screenshot 9. Building the backend and frontend images.*

![Screenshot 10: Confirming that no image has the tag latest.](docs/Screenshots/10-confirming-that-there-is-no-latest-tag.png)

*Screenshot 10. Confirming that no image has the tag latest.*

![Screenshot 11: Confirmation that the images were pushed.](docs/Screenshots/11-confirmation-of-pushed-image.png)

*Screenshot 11. Confirmation that the images were pushed.*

![Screenshot 12: The backend image on Docker Hub with its sha tag.](docs/Screenshots/12-backend-image-on-dockerhub-with-tag.png)

*Screenshot 12. The backend image on Docker Hub with its sha tag.*

![Screenshot 13: The frontend image on Docker Hub with its sha tag.](docs/Screenshots/13-frontend-image-on-dockerhub-with-tag.png)

*Screenshot 13. The frontend image on Docker Hub with its sha tag.*

![Screenshot 14: The full directory listing of the project.](docs/Screenshots/14-full-directory-listing-everything.png)

*Screenshot 14. The full directory listing of the project.*

### Provisioning the VM on Azure

![Screenshot 15: Checking the Azure login.](docs/Screenshots/15-checking-azure-login.png)

*Screenshot 15. Checking the Azure login.*

![Screenshot 16: The first provisioning attempt, with an earlier version of the script. It ended with Cancelled and nothing was created.](docs/Screenshots/16-services-registered-on-azure.png)

*Screenshot 16. The first provisioning attempt, with an earlier version of the script. It ended with Cancelled and nothing was created.*

![Screenshot 17: The incident: Azure refused every region and size (see docs/incident-report.pdf).](docs/Screenshots/17-issue-with-registering-services-in-zones.png)

*Screenshot 17. The incident: Azure refused every region and size (see docs/incident-report.pdf).*

![Screenshot 18: After the fix: Standard_D2ads_v6 passes Azure's check in westus3.](docs/Screenshots/18-after-troubleshooting-to-find-available-zone.png)

*Screenshot 18. After the fix: Standard_D2ads_v6 passes Azure's check in westus3.*

![Screenshot 19: The plan, the confirmation and the public IP address of the new VM.](docs/Screenshots/19-done-registering-services-with-public-ip.png)

*Screenshot 19. The plan, the confirmation and the public IP address of the new VM.*

![Screenshot 20: The virtual machine in the Azure portal.](docs/Screenshots/20-viewing-the-virtual-machine-in-azure-portal.png)

*Screenshot 20. The virtual machine in the Azure portal.*

![Screenshot 21: The network rules for ports 22 and 80.](docs/Screenshots/21-port-settings-of-22-and-80-set-to-allow.png)

*Screenshot 21. The network rules for ports 22 and 80.*

### Setting up and deploying on the VM

![Screenshot 22: Setting up Docker on the Ubuntu VM.](docs/Screenshots/22-setting-up-docker-in-the-ubuntu-vm.png)

*Screenshot 22. Setting up Docker on the Ubuntu VM.*

![Screenshot 23: Logging in to the Azure VM with SSH.](docs/Screenshots/23-ssh-into-azure-vm.png)

*Screenshot 23. Logging in to the Azure VM with SSH.*

![Screenshot 24: Assigning permissions on the VM.](docs/Screenshots/24-assigning-permissions.png)

*Screenshot 24. Assigning permissions on the VM.*

![Screenshot 25: Creating the private .env file on the VM.](docs/Screenshots/25-creating-a-password-for-env-on-azure.png)

*Screenshot 25. Creating the private .env file on the VM.*

![Screenshot 26: Checking the permissions of the files on the VM.](docs/Screenshots/26-checking-permissions-of-files-on-the-ubuntu-vm.png)

*Screenshot 26. Checking the permissions of the files on the VM.*

![Screenshot 27: The containers running on the VM.](docs/Screenshots/27-containers-running-in-vm.png)

*Screenshot 27. The containers running on the VM.*

![Screenshot 28: Checking which version the containers are running.](docs/Screenshots/28-checking-which-version-is-the-container-running.png)

*Screenshot 28. Checking which version the containers are running.*

![Screenshot 29: Visiting the public IP address in the browser.](docs/Screenshots/29-visiting-the-public-ip-in-browser.png)

*Screenshot 29. Visiting the public IP address in the browser.*

![Screenshot 30: Sending a message through the public IP address.](docs/Screenshots/30-sending-message-on-the-public-ip.png)

*Screenshot 30. Sending a message through the public IP address.*

![Screenshot 31: Showing that the backend and the database are not reachable from the internet.](docs/Screenshots/31-ensuring-the-backend-and-databse-is-hidden.png)

*Screenshot 31. Showing that the backend and the database are not reachable from the internet.*

### CI/CD pipeline

![Screenshot 32: Creating the new repository on GitHub.](docs/Screenshots/32-created-new-repo-in-github.png)

*Screenshot 32. Creating the new repository on GitHub.*

![Screenshot 33: Creating a secret in the repository settings.](docs/Screenshots/33-create-secret-key-for-github.png)

*Screenshot 33. Creating a secret in the repository settings.*

![Screenshot 34: The repository secrets after they were added (names only).](docs/Screenshots/34-github-secrets-added.png)

*Screenshot 34. The repository secrets after they were added (names only).*

![Screenshot 35: The version check in the VS Code terminal.](docs/Screenshots/35-version-check-in-vscode-terminal.png)

*Screenshot 35. The version check in the VS Code terminal.*

![Screenshot 36: A pipeline run with every step green.](docs/Screenshots/36-pipeline-run-green.png)

*Screenshot 36. A pipeline run with every step green.*

![Screenshot 37: The smoke tests passing.](docs/Screenshots/37-smoke-tests-pass.png)

*Screenshot 37. The smoke tests passing.*

![Screenshot 38: The deploy step and the check from the public address.](docs/Screenshots/38-deploy-and-outside-check.png)

*Screenshot 38. The deploy step and the check from the public address.*

![Screenshot 39: The new sha tag on Docker Hub after a pipeline run.](docs/Screenshots/39-dockerhub-new-sha-tag.png)

*Screenshot 39. The new sha tag on Docker Hub after a pipeline run.*

### Rollback test

![Screenshot 40: Before the rollback: the live version and the previous tag on the VM.](docs/Screenshots/40-before-rollback-terminal.png)

*Screenshot 40. Before the rollback: the live version and the previous tag on the VM.*

![Screenshot 41: Before the rollback: the version in the page footer.](docs/Screenshots/41-before-rollback-browser.png)

*Screenshot 41. Before the rollback: the version in the page footer.*

![Screenshot 42: Starting the Rollback workflow with the older tag typed in.](docs/Screenshots/42-rollback-workflow-form.png)

*Screenshot 42. Starting the Rollback workflow with the older tag typed in.*

![Screenshot 43: The Rollback run finished with every step green.](docs/Screenshots/43-rollback-run-green.png)

*Screenshot 43. The Rollback run finished with every step green.*

![Screenshot 44: After the rollback: the live version and the rollback line in the deploy history.](docs/Screenshots/44-after-rollback-terminal.png)

*Screenshot 44. After the rollback: the live version and the rollback line in the deploy history.*

![Screenshot 45: After the rollback: the older version in the page footer.](docs/Screenshots/45-after-rollback-browser.png)

*Screenshot 45. After the rollback: the older version in the page footer.*
