#!/bin/sh
# deploy.sh - HNG Stage 1 automated deployment script (POSIX-compatible)
# usage: ./deploy.sh [--cleanup]


TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOGFILE="deploy_${TIMESTAMP}.log"

#logging helper and trap for cleanup on errors

log() {
  printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOGFILE"
}
info()  { log "[INFO] $1"; }
warn()  { log "[WARN] $1"; }
error() { log "[ERROR] $1"; }

on_exit() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    error "Script exited with code $rc"
    error "See $LOGFILE for details"
  else
    info "Script completed successfully"
  fi
}
trap 'on_exit' EXIT INT TERM


# parse a cleanup flag
CLEANUP_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cleanup) CLEANUP_FLAG=1; shift ;;
    *) shift ;;
  esac
done

# prompt for and validate user input
printf "Git repository URL (HTTPS): "
read REPO_URL

printf "Personal Access Token (PAT) (leave blank for public repo): "
stty -echo
read GIT_PAT
stty echo
printf "\n"

printf "Branch [default: main]: "
read BRANCH
BRANCH=${BRANCH:-main}

printf "Remote SSH username: "
read REMOTE_USER
printf "Remote server IP/hostname: "
read REMOTE_HOST
printf "Path to SSH private key (local): "
read SSH_KEY_PATH
printf "Internal container port (inside container): "
read CONTAINER_PORT

# simple validation
if [ -z "$REPO_URL" ] || [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ] || [ -z "$SSH_KEY_PATH" ] || [ -z "$CONTAINER_PORT" ]; then
  error "Missing required inputs. Aborting."
  exit 10
fi


# log git clone / pull (idempotent)

REPO_NAME=$(basename "$REPO_URL" .git)
LOCAL_DIR="./$REPO_NAME"

git_clone_or_pull() {
  if [ -d "$LOCAL_DIR/.git" ]; then
    info "Local repo exists; fetching latest..."
    (cd "$LOCAL_DIR" && git fetch origin >> "$LOGFILE" 2>&1 && git checkout "$BRANCH" >> "$LOGFILE" 2>&1 && git pull origin "$BRANCH" >> "$LOGFILE" 2>&1) || return 1
  else
    info "Cloning repository..."
    if [ -n "$GIT_PAT" ]; then
      AUTH_URL=$(printf "%s" "$REPO_URL" | sed "s#https://#https://${GIT_PAT}@#g")
      git clone --branch "$BRANCH" "$AUTH_URL" "$LOCAL_DIR" >> "$LOGFILE" 2>&1 || return 1
      (cd "$LOCAL_DIR" && git remote set-url origin "$REPO_URL")
    else
      git clone --branch "$BRANCH" "$REPO_URL" "$LOCAL_DIR" >> "$LOGFILE" 2>&1 || return 1
    fi
  fi
  return 0
}

git_clone_or_pull || { error "Git clone/pull failed"; exit 12; }
info "Repository ready locally"


# check for dockerfile or docker-compose.yml

if [ -f "$LOCAL_DIR/Dockerfile" ]; then
  DEPLOY_MODE="dockerfile"
  info "Found Dockerfile"
elif [ -f "$LOCAL_DIR/docker-compose.yml" ] || [ -f "$LOCAL_DIR/docker-compose.yaml" ]; then
  DEPLOY_MODE="compose"
  info "Found docker-compose.yml"
else
  warn "No Dockerfile or docker-compose.yml found in repo root — deployment may fail unless app is containerized"
fi


# ssh connectivity dry run

SSH_BASE="$REMOTE_USER@$REMOTE_HOST"
SSH_OPTS="-i $SSH_KEY_PATH -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
SSH_CMD="ssh $SSH_OPTS $SSH_BASE"

$SSH_CMD "echo SSH_OK" >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
  error "SSH connectivity check failed. Check SSH key path, username, and host."
  exit 11
fi
info "SSH connectivity OK"


# remote cleanup mode
if [ "$CLEANUP_FLAG" -eq 1 ]; then
  info "Running remote cleanup..."
  CLEAN_CMD=$(cat <<'EOF'
set -eu
APP_DIR="$HOME/REPO_PLACEHOLDER"
# stop containers, remove images, remove nginx site and reload nginx, remove app dir
docker ps -a --format '{{.Names}}' | grep '^REPO_PLACEHOLDER' || true | xargs -r docker rm -f || true
docker images --format '{{.Repository}}:{{.Tag}}' | grep '^REPO_PLACEHOLDER:' || true | xargs -r docker rmi -f || true
sudo rm -f /etc/nginx/sites-enabled/REPO_PLACEHOLDER /etc/nginx/sites-available/REPO_PLACEHOLDER || true
sudo systemctl reload nginx || true
rm -rf "$APP_DIR" || true
echo CLEANUP_DONE
EOF
)
  # Replace placeholder with actual repo name and run
  CLEAN_CMD=$(printf "%s" "$CLEAN_CMD" | sed "s/REPO_PLACEHOLDER/${REPO_NAME}/g")
  $SSH_CMD "$CLEAN_CMD" >> "$LOGFILE" 2>&1 || warn "Remote cleanup reported errors"
  info "Cleanup attempted on remote"
  exit 0
fi



# prepare remote environment(install docker. compose plugin, nginx)

REMOTE_SETUP=$(cat <<'EOF'
set -eu
echo "REMOTE_SETUP_START"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi
sudo systemctl enable --now docker
if ! command -v nginx >/dev/null 2>&1; then
  sudo apt-get install -y nginx
fi
sudo systemctl enable --now nginx
echo "REMOTE_SETUP_DONE"
EOF
)

# Run remote setup
$SSH_CMD "bash -s" <<REMOTE_RUN >> "$LOGFILE" 2>&1
$REMOTE_SETUP
REMOTE_RUN

if [ $? -ne 0 ]; then
  error "Remote environment setup failed"
  exit 13
fi
info "Remote environment prepared"


# transfer project files with rsync
REMOTE_APP_DIR="\$HOME/${REPO_NAME}"
RSYNC_CMD="rsync -az --delete -e \"ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=accept-new\" ${LOCAL_DIR}/ ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_APP_DIR}/"
sh -c "$RSYNC_CMD" >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
  error "File transfer to remote failed"
  exit 14
fi
info "Files transferred"



# build and run on the remote (compose or docker file)
DEPLOY_SCRIPT=$(cat <<'EOF'
set -eu
APP_DIR="$HOME/REPO_PLACEHOLDER"
cd "$APP_DIR" || exit 2

# remove old containers with repo prefix
docker ps -a --format '{{.Names}}' | grep '^REPO_PLACEHOLDER' || true | xargs -r docker rm -f || true

if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  docker compose down || true
  docker compose build --no-cache || true
  docker compose up -d || { echo "compose up failed"; exit 1; }
else
  if [ -f Dockerfile ]; then
    IMAGE_TAG="REPO_PLACEHOLDER:latest"
    docker build -t "$IMAGE_TAG" . || { echo "docker build failed"; exit 2; }
    docker run -d --name "REPO_PLACEHOLDER_app" -p 127.0.0.1:CONTAINER_PORT:CONTAINER_PORT "$IMAGE_TAG" || { echo "docker run failed"; exit 3; }
  else
    echo "NO_CONTAINER_INSTRUCTION" && exit 4
  fi
fi
echo "REMOTE_DEPLOY_DONE"
EOF
)

DEPLOY_SCRIPT=$(printf "%s" "$DEPLOY_SCRIPT" | sed "s/REPO_PLACEHOLDER/${REPO_NAME}/g")
$SSH_CMD "CONTAINER_PORT=${CONTAINER_PORT} bash -s" <<REMOTE_DEPLOY >> "$LOGFILE" 2>&1
$DEPLOY_SCRIPT
REMOTE_DEPLOY

if [ $? -ne 0 ]; then
  error "Remote deploy failed"
  exit 14
fi
info "Remote deployment completed"


# create nginx config and enable it

NGINX_CONF=$(cat <<NGX
server {
  listen 80;
  server_name _;

  location / {
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:${CONTAINER_PORT};
    proxy_read_timeout 90;
  }
}
NGX
)

# push config via ssh
echo "$NGINX_CONF" | $SSH_CMD "sudo tee /etc/nginx/sites-available/${REPO_NAME} > /dev/null" >> "$LOGFILE" 2>&1
$SSH_CMD "sudo ln -sf /etc/nginx/sites-available/${REPO_NAME} /etc/nginx/sites-enabled/${REPO_NAME} && sudo nginx -t" >> "$LOGFILE" 2>&1
if [ $? -ne 0 ]; then
  error "Nginx configuration test failed"
  exit 15
fi
$SSH_CMD "sudo systemctl reload nginx" >> "$LOGFILE" 2>&1
info "Nginx configured and reloaded"


# validation checks (docker, container, nginx, endpoint)

# check docker version on remote
$SSH_CMD "docker --version" >> "$LOGFILE" 2>&1 || warn "docker not available"

# check containers
$SSH_CMD "docker ps --filter name=${REPO_NAME} --format 'table {{.Names}}\t{{.Status}}' || true" >> "$LOGFILE" 2>&1

# curl from remote to container
REMOTE_HTTP_CODE=$($SSH_CMD "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${CONTAINER_PORT} || true")
info "Remote-local curl returned: ${REMOTE_HTTP_CODE}"

# curl from local to remote (via nginx)
LOCAL_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://${REMOTE_HOST} || true)
info "Local->remote (http://${REMOTE_HOST}) returned: ${LOCAL_HTTP_CODE}"

if [ "$LOCAL_HTTP_CODE" = "000" ]; then
  warn "Local cannot reach remote HTTP port 80: check firewall / security group"
else
  info "Remote app reachable from this machine (HTTP status ${LOCAL_HTTP_CODE})"
fi
