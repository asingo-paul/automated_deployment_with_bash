# automated_deployment_with_bash
Building a single production ready Bash Script(deploy.sh) that automates setting up an deploying a dockerized application onto a remote linux server


http://172.31.27.76
# Automated Deployment with Bash — HNG Stage 1

## 🚀 Overview
This project automates the setup and deployment of a Dockerized application to a remote Linux server using a single Bash script (`deploy.sh`).

## 🧠 Features
- Clones or updates a Git repository
- Validates user input
- Sets up Docker, Docker Compose, and Nginx on the remote server
- Builds and runs Docker containers
- Configures Nginx as a reverse proxy
- Logs all actions with timestamps
- Supports cleanup with `--cleanup` flag

## 🛠️ Requirements
- Ubuntu/Linux (local and remote)
- Git
- SSH access to the remote server
- Docker installed (if testing locally)

## ⚙️ Usage
```bash
chmod +x deploy.sh
./deploy.sh
