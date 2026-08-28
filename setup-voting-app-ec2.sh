#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Voting App - Canonical EC2 Machine Bootstrap
# ============================================================

DATA_MOUNT="/mnt/docker-data"
DOCKER_DATA="${DATA_MOUNT}/docker"
DOCKER_OLD="/var/lib/docker.old"

MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-3000}"

GITHUB_ORG="Mohammed-Azam-Sohail"

REPOS=(
    voting-app-vote
    voting-app-result
    voting-app-worker
    voting-app-db
    voting-app-redis
)

log() {
    echo
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $1"
    exit 1
}

[[ "$EUID" -ne 0 ]] || fail "Run as the ubuntu user, not root."

# ============================================================
# 1. SYSTEM
# ============================================================

log "1/10 - SYSTEM"

echo "User     : $(whoami)"
echo "Hostname : $(hostname)"
echo "CPU      : $(nproc)"
echo
free -h
echo
df -h /

# ============================================================
# 2. PACKAGES
# ============================================================

log "2/10 - REQUIRED PACKAGES"

sudo apt-get update

sudo apt-get install -y \
    ca-certificates \
    curl \
    git \
    rsync \
    conntrack \
    python3 \
    python3-pip \
    python3-venv

# ============================================================
# 3. DOCKER
# ============================================================

log "3/10 - DOCKER"

if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get install -y docker.io
fi

sudo systemctl enable docker
sudo systemctl start docker

# Give ubuntu Docker group membership permanently.
sudo usermod -aG docker "$USER"

echo "Docker:"
sudo docker --version

# ============================================================
# 4. DETECT 20GB DISK
# ============================================================

log "4/10 - 20GB DATA DISK"

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"

echo "Root filesystem: $ROOT_SOURCE"
echo
lsblk -dpno NAME,SIZE,TYPE

DATA_DISK=""

while read -r DEV SIZE TYPE; do

    [[ "$TYPE" == "disk" ]] || continue
    [[ "$SIZE" == "20G" ]] || continue

    # Never touch root disk.
    [[ "$ROOT_SOURCE" == "$DEV"* ]] && continue

    DATA_DISK="$DEV"
    break

done < <(lsblk -dpno NAME,SIZE,TYPE)

[[ -n "$DATA_DISK" ]] || fail "Unused 20GB disk not found."

echo
echo "Selected: $DATA_DISK"

# ============================================================
# 5. FORMAT + MOUNT
# ============================================================

log "5/10 - MOUNTING 20GB DISK"

sudo mkdir -p "$DATA_MOUNT"

FSTYPE="$(lsblk -no FSTYPE "$DATA_DISK" | tr -d '[:space:]')"

if [[ -z "$FSTYPE" ]]; then

    echo "Formatting $DATA_DISK as ext4..."
    sudo mkfs.ext4 -F "$DATA_DISK"

elif [[ "$FSTYPE" == "ext4" ]]; then

    echo "Existing ext4 filesystem detected."

else

    fail "Filesystem '$FSTYPE' detected; refusing to reformat."

fi

DATA_UUID="$(sudo blkid -s UUID -o value "$DATA_DISK")"

[[ -n "$DATA_UUID" ]] || fail "Could not determine disk UUID."

if ! mountpoint -q "$DATA_MOUNT"; then
    sudo mount "$DATA_DISK" "$DATA_MOUNT"
fi

sudo mkdir -p "$DOCKER_DATA"

# Persistent mount after reboot.
if ! grep -q "UUID=$DATA_UUID" /etc/fstab; then
    echo "UUID=$DATA_UUID $DATA_MOUNT ext4 defaults,nofail 0 2" |
        sudo tee -a /etc/fstab >/dev/null
fi

df -h "$DATA_MOUNT"

# ============================================================
# 6. DOCKER STORAGE
# ============================================================

log "6/10 - DOCKER STORAGE"

CURRENT_ROOT="$(
    sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || true
)"

if [[ "$CURRENT_ROOT" != "$DOCKER_DATA" ]]; then

    sudo systemctl stop docker.socket 2>/dev/null || true
    sudo systemctl stop docker 2>/dev/null || true

    sudo mkdir -p "$DOCKER_DATA"

    if [[ -L /var/lib/docker ]]; then

        echo "/var/lib/docker is already a symlink."

    elif [[ -d /var/lib/docker ]]; then

        echo "Moving existing Docker data..."
        sudo rsync -aHAX /var/lib/docker/ "$DOCKER_DATA/"

        if [[ ! -e "$DOCKER_OLD" ]]; then
            sudo mv /var/lib/docker "$DOCKER_OLD"
        else
            sudo rm -rf /var/lib/docker
        fi

        sudo ln -s "$DOCKER_DATA" /var/lib/docker

    else

        sudo ln -s "$DOCKER_DATA" /var/lib/docker

    fi

    sudo systemctl start docker
fi

DOCKER_ROOT="$(
    sudo docker info --format '{{.DockerRootDir}}'
)"

echo "Docker Root Dir: $DOCKER_ROOT"

[[ "$DOCKER_ROOT" == "$DOCKER_DATA" ]] ||
    fail "Docker is not using the 20GB disk."

# ============================================================
# 7. KUBECTL + MINIKUBE
# ============================================================

log "7/10 - KUBERNETES TOOLS"

if ! command -v kubectl >/dev/null 2>&1; then

    KUBECTL_VERSION="$(curl -fsSL \
        https://dl.k8s.io/release/stable.txt)"

    curl -fsSL \
        -o /tmp/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

    sudo install \
        -o root \
        -g root \
        -m 0755 \
        /tmp/kubectl \
        /usr/local/bin/kubectl

    rm -f /tmp/kubectl
fi

if ! command -v minikube >/dev/null 2>&1; then

    curl -fsSL \
        -o /tmp/minikube-linux-amd64 \
        https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64

    sudo install \
        /tmp/minikube-linux-amd64 \
        /usr/local/bin/minikube

    rm -f /tmp/minikube-linux-amd64
fi

kubectl version --client
minikube version

# ============================================================
# 8. MINIKUBE
# ============================================================

log "8/10 - MINIKUBE"

MINIKUBE_HOST="$(
    sudo -u "$USER" minikube status --format='{{.Host}}' 2>/dev/null || true
)"

if [[ "$MINIKUBE_HOST" != "Running" ]]; then

    # Use a fresh login-like docker group for Minikube.
    sg docker -c "
        minikube start \
            --driver=docker \
            --cpus=$MINIKUBE_CPUS \
            --memory=$MINIKUBE_MEMORY
    "

else

    echo "Minikube already running."

fi

echo
echo "Node:"
kubectl get nodes

# Give system components time to settle.
for i in {1..12}; do

    if kubectl get pods -n kube-system \
        --no-headers 2>/dev/null |
        awk '
            $2=="1/1" && $3=="Running" {ready++}
            END {
                exit !(ready > 0)
            }
        '
    then
        break
    fi

    sleep 5
done

echo
kubectl get pods -A

# ============================================================
# 9. REPOSITORIES
# ============================================================

log "9/10 - REPOSITORIES"

cd "$HOME"

for repo in "${REPOS[@]}"; do

    if [[ -d "$HOME/$repo/.git" ]]; then

        echo "$repo exists; syncing origin/main..."
        git -C "$HOME/$repo" fetch origin
        git -C "$HOME/$repo" reset --hard origin/main
        git -C "$HOME/$repo" clean -fd

    else

        echo "Cloning $repo..."

        git clone \
            "https://github.com/$GITHUB_ORG/$repo.git" \
            "$HOME/$repo"

    fi

done

# ============================================================
# 10. PYTHON TEST ENVIRONMENT
# ============================================================

log "10/10 - VOTE TEST ENVIRONMENT"

cd "$HOME/voting-app-vote"

rm -rf .venv
rm -rf tests/__pycache__

python3 -m venv .venv

source .venv/bin/activate

python -m pip install --upgrade pip
python -m pip install -r requirements.txt
python -m pip install pytest

echo
echo "Vote tests:"
pytest -q

deactivate

rm -rf tests/__pycache__

# ============================================================
# FINAL VALIDATION
# ============================================================

log "FINAL VALIDATION"

echo
echo "Docker version:"
sudo docker --version

echo
echo "Docker Root Dir:"
sudo docker info --format '{{.DockerRootDir}}'

echo
echo "20GB disk:"
df -h "$DATA_MOUNT"

echo
echo "kubectl:"
kubectl version --client

echo
echo "Minikube:"
sudo -u "$USER" minikube status

echo
echo "Kubernetes:"
kubectl get nodes

echo
echo "System pods:"
kubectl get pods -A

echo
echo "Repositories:"
ls -d "$HOME"/voting-app-*/

echo
echo "Vote tests:"
cd "$HOME/voting-app-vote"
source .venv/bin/activate
pytest -q
deactivate
rm -rf tests/__pycache__

echo
echo "Git status:"
for repo in "${REPOS[@]}"; do
    echo "--- $repo ---"
    git -C "$HOME/$repo" status --short
done

echo
echo "============================================================"
echo " EC2 MACHINE BOOTSTRAP COMPLETE"
echo "============================================================"
echo
echo "Docker group has been configured permanently."
echo
echo "IMPORTANT:"
echo "The current shell may not yet contain the docker group."
echo "For a completely new SSH session, Docker access will work."
echo
echo "If you want to continue in this exact shell immediately:"
echo "    newgrp docker"
echo
echo "Machine dependencies are complete."
echo "Project deployment can begin."
echo "============================================================"
