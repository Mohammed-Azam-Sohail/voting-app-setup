#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# VOTING APP - COMPLETE EC2 MACHINE BOOTSTRAP
#
# Run as the normal ubuntu user.
#
# Provides:
#   - Base packages
#   - Docker
#   - Docker Buildx
#   - 20GB EBS storage
#   - Docker data on 20GB EBS
#   - containerd data on 20GB EBS
#   - kubectl
#   - Minikube
#   - Java 21
#   - Jenkins
#   - Jenkins -> Docker access
#   - Jenkins -> Kubernetes access
#   - Git
#   - Python / pip / venv / pytest
#   - Five application repositories
#
# Application deployment is handled separately by:
#   setup-voting-app-project.sh
# ============================================================

set -o pipefail

# ============================================================
# CONFIGURATION
# ============================================================

DATA_MOUNT="/mnt/docker-data"
DOCKER_DATA="${DATA_MOUNT}/docker"
CONTAINERD_DATA="${DATA_MOUNT}/containerd"

MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-3000}"

GITHUB_ORG="Mohammed-Azam-Sohail"

REPOS=(
    voting-app-db
    voting-app-redis
    voting-app-result
    voting-app-vote
    voting-app-worker
)

# ============================================================
# HELPERS
# ============================================================

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

# ============================================================
# SAFETY
# ============================================================

[[ "$EUID" -ne 0 ]] ||
    fail "Run this script as the ubuntu user, not root."

command -v sudo >/dev/null 2>&1 ||
    fail "sudo is required."

# ============================================================
# 1. SYSTEM
# ============================================================

log "1/14 - SYSTEM"

echo "User     : $(whoami)"
echo "Hostname : $(hostname)"
echo "CPU      : $(nproc)"

echo
free -h

echo
df -h /

# ============================================================
# 2. REQUIRED PACKAGES
# ============================================================

log "2/14 - REQUIRED PACKAGES"

sudo apt-get update

sudo apt-get install -y \
    ca-certificates \
    curl \
    git \
    rsync \
    conntrack \
    python3 \
    python3-pip \
    python3-venv \
    wget \
    gnupg \
    fontconfig \
    openjdk-21-jre

# ============================================================
# 3. DOCKER + BUILDX
# ============================================================

log "3/14 - DOCKER + BUILDX"

if ! command -v docker >/dev/null 2>&1; then
    sudo apt-get install -y docker.io
fi

if ! docker buildx version >/dev/null 2>&1; then
    sudo apt-get install -y docker-buildx
fi

sudo systemctl enable --now containerd
sudo systemctl enable --now docker

sudo usermod -aG docker "$USER"

echo
echo "Docker:"
sudo docker --version

echo
echo "Buildx:"
docker buildx version

# ============================================================
# 4. DETECT 20GB EBS DISK
# ============================================================

log "4/14 - DETECTING 20GB EBS DISK"

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"

echo "Root filesystem: $ROOT_SOURCE"
echo
lsblk -dpno NAME,SIZE,TYPE

DATA_DISK=""

while read -r DEV SIZE TYPE; do

    [[ "$TYPE" == "disk" ]] || continue
    [[ "$SIZE" == "20G" ]] || continue

    # Never select the root disk.
    [[ "$ROOT_SOURCE" == "$DEV"* ]] && continue

    # Only use an unpartitioned disk.
    PART_COUNT="$(
        lsblk -ln -o TYPE "$DEV" |
        awk '$1=="part"{count++} END{print count+0}'
    )"

    [[ "$PART_COUNT" -eq 0 ]] || continue

    DATA_DISK="$DEV"
    break

done < <(lsblk -dpno NAME,SIZE,TYPE)

if [[ -z "$DATA_DISK" ]]; then
    echo
    lsblk -f
    fail "No safe unused 20GB disk was detected."
fi

echo
echo "Selected data disk: $DATA_DISK"

# ============================================================
# 5. FORMAT + MOUNT 20GB DISK
# ============================================================

log "5/14 - PREPARING 20GB STORAGE"

sudo mkdir -p "$DATA_MOUNT"

FSTYPE="$(lsblk -no FSTYPE "$DATA_DISK" | tr -d '[:space:]')"

if [[ -z "$FSTYPE" ]]; then

    echo "No filesystem detected. Formatting as ext4..."
    sudo mkfs.ext4 -F "$DATA_DISK"

elif [[ "$FSTYPE" == "ext4" ]]; then

    echo "Existing ext4 filesystem detected."

else

    fail "Filesystem '$FSTYPE' detected. Refusing to reformat."

fi

DATA_UUID="$(sudo blkid -s UUID -o value "$DATA_DISK")"

[[ -n "$DATA_UUID" ]] ||
    fail "Could not determine UUID of $DATA_DISK."

if ! mountpoint -q "$DATA_MOUNT"; then
    sudo mount "$DATA_DISK" "$DATA_MOUNT"
fi

sudo mkdir -p "$DOCKER_DATA"
sudo mkdir -p "$CONTAINERD_DATA"

# Persist mount across reboot.
FSTAB_LINE="UUID=${DATA_UUID} ${DATA_MOUNT} ext4 defaults,nofail 0 2"

if ! grep -qF "$FSTAB_LINE" /etc/fstab; then
    echo "$FSTAB_LINE" |
        sudo tee -a /etc/fstab >/dev/null
fi

echo
echo "Storage:"
df -h "$DATA_MOUNT"

# ============================================================
# 6. MOVE DOCKER STORAGE
# ============================================================

log "6/14 - DOCKER STORAGE"

sudo systemctl stop docker.socket 2>/dev/null || true
sudo systemctl stop docker.service 2>/dev/null || true

CURRENT_DOCKER_ROOT="$(
    sudo docker info \
        --format '{{.DockerRootDir}}' \
        2>/dev/null || true
)"

if [[ "$CURRENT_DOCKER_ROOT" == "$DOCKER_DATA" ]]; then

    echo "Docker already uses $DOCKER_DATA."

else

    if [[ -L /var/lib/docker ]]; then

        LINK_TARGET="$(readlink -f /var/lib/docker)"

        if [[ "$LINK_TARGET" != "$DOCKER_DATA" ]]; then
            sudo rm -f /var/lib/docker
            sudo ln -s "$DOCKER_DATA" /var/lib/docker
        fi

    elif [[ -d /var/lib/docker ]]; then

        echo "Migrating existing Docker data..."

        sudo rsync -aHAX \
            /var/lib/docker/ \
            "$DOCKER_DATA/"

        if [[ -e /var/lib/docker.old ]]; then
            sudo rm -rf /var/lib/docker.old
        fi

        sudo mv \
            /var/lib/docker \
            /var/lib/docker.old

        sudo ln -s \
            "$DOCKER_DATA" \
            /var/lib/docker

    else

        sudo ln -s \
            "$DOCKER_DATA" \
            /var/lib/docker

    fi

fi

# ============================================================
# 7. MOVE CONTAINERD STORAGE
# ============================================================

log "7/14 - CONTAINERD STORAGE"

sudo systemctl stop containerd.service 2>/dev/null || true

if [[ -L /var/lib/containerd ]]; then

    LINK_TARGET="$(readlink -f /var/lib/containerd)"

    if [[ "$LINK_TARGET" != "$CONTAINERD_DATA" ]]; then
        sudo rm -f /var/lib/containerd
        sudo ln -s "$CONTAINERD_DATA" /var/lib/containerd
    fi

elif [[ -d /var/lib/containerd ]]; then

    echo "Migrating existing containerd data..."

    sudo rsync -aHAX \
        /var/lib/containerd/ \
        "$CONTAINERD_DATA/"

    if [[ -e /var/lib/containerd.old ]]; then
        sudo rm -rf /var/lib/containerd.old
    fi

    sudo mv \
        /var/lib/containerd \
        /var/lib/containerd.old

    sudo ln -s \
        "$CONTAINERD_DATA" \
        /var/lib/containerd

else

    sudo ln -s \
        "$CONTAINERD_DATA" \
        /var/lib/containerd

fi

sudo systemctl enable --now containerd
sudo systemctl enable --now docker

# ============================================================
# 8. VERIFY DOCKER + STORAGE
# ============================================================

log "8/14 - VERIFYING DOCKER + STORAGE"

sudo systemctl is-active --quiet containerd ||
    fail "Containerd is not active."

sudo systemctl is-active --quiet docker ||
    fail "Docker is not active."

DOCKER_ROOT="$(
    sudo docker info \
        --format '{{.DockerRootDir}}'
)"

echo "Docker Root Dir: $DOCKER_ROOT"

[[ "$DOCKER_ROOT" == "$DOCKER_DATA" ]] ||
    fail "Docker is not using $DOCKER_DATA."

docker buildx version >/dev/null 2>&1 ||
    fail "Docker Buildx is unavailable."

echo
echo "Root disk:"
df -h /

echo
echo "20GB disk:"
df -h "$DATA_MOUNT"

echo
echo "Docker:"
sudo docker ps

echo
echo "Containerd data:"
sudo du -sh "$CONTAINERD_DATA" 2>/dev/null || true

# Remove old copies only after services are confirmed healthy.
if [[ -d /var/lib/docker.old ]]; then
    echo
    echo "Removing old Docker storage copy..."
    sudo rm -rf /var/lib/docker.old
fi

if [[ -d /var/lib/containerd.old ]]; then
    echo
    echo "Removing old containerd storage copy..."
    sudo rm -rf /var/lib/containerd.old
fi

# ============================================================
# 9. KUBECTL + MINIKUBE
# ============================================================

log "9/14 - KUBERNETES TOOLS"

if ! command -v kubectl >/dev/null 2>&1; then

    KUBECTL_VERSION="$(
        curl -fsSL https://dl.k8s.io/release/stable.txt
    )"

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
        -o root \
        -g root \
        -m 0755 \
        /tmp/minikube-linux-amd64 \
        /usr/local/bin/minikube

    rm -f /tmp/minikube-linux-amd64

fi

kubectl version --client
minikube version

# ============================================================
# 10. MINIKUBE
# ============================================================

log "10/14 - MINIKUBE"

MINIKUBE_HOST="$(
    sg docker -c \
        'minikube status --format="{{.Host}}" 2>/dev/null' ||
        true
)"

if [[ "$MINIKUBE_HOST" == "Running" ]]; then

    echo "Minikube already running."

else

    sg docker -c "
        minikube start \
            --driver=docker \
            --cpus=${MINIKUBE_CPUS} \
            --memory=${MINIKUBE_MEMORY}
    "

fi

echo
echo "Minikube status:"
sg docker -c 'minikube status'

echo
echo "Kubernetes nodes:"
kubectl get nodes

# Wait for system pods.
for _ in {1..24}; do

    READY_COUNT="$(
        kubectl get pods \
            -n kube-system \
            --no-headers 2>/dev/null |
        awk '
            {
                split($2,a,"/");
                if (a[1] == a[2] && $3 == "Running")
                    count++
            }
            END {print count+0}
        '
    )"

    if [[ "$READY_COUNT" -ge 1 ]]; then
        break
    fi

    sleep 5
done

echo
kubectl get pods -A

# ============================================================
# 11. JENKINS INSTALLATION
# ============================================================

log "11/14 - JENKINS"

if ! command -v jenkins >/dev/null 2>&1; then

    sudo mkdir -p /etc/apt/keyrings

    sudo wget -q \
        -O /etc/apt/keyrings/jenkins-keyring.asc \
        https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

    echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" |
        sudo tee /etc/apt/sources.list.d/jenkins.list >/dev/null

    sudo apt-get update

    sudo apt-get install -y jenkins

fi

sudo usermod -aG docker jenkins

sudo systemctl daemon-reload
sudo systemctl enable jenkins
sudo systemctl restart jenkins

sudo systemctl is-active --quiet jenkins ||
    fail "Jenkins is not active."

echo
echo "Jenkins version:"
jenkins --version

echo
echo "Java:"
java -version

# ============================================================
# 12. JENKINS KUBERNETES CONFIGURATION
# ============================================================

log "12/14 - JENKINS KUBERNETES ACCESS"

sudo mkdir -p /var/lib/jenkins/.kube

JENKINS_KUBECONFIG_TMP="/tmp/jenkins-kubeconfig"

# Flatten the Minikube context so the certificate/key/CA data
# are embedded instead of referencing /home/ubuntu/.minikube.
sg docker -c \
    'kubectl config view --raw --minify --flatten' \
    > "$JENKINS_KUBECONFIG_TMP"

[[ -s "$JENKINS_KUBECONFIG_TMP" ]] ||
    fail "Failed to create Jenkins kubeconfig."

sudo install \
    -o jenkins \
    -g jenkins \
    -m 0600 \
    "$JENKINS_KUBECONFIG_TMP" \
    /var/lib/jenkins/.kube/config

rm -f "$JENKINS_KUBECONFIG_TMP"

sudo systemctl restart jenkins

# Verify Jenkins Docker access.
sudo -u jenkins docker version >/dev/null ||
    fail "Jenkins cannot access Docker."

# Verify Jenkins Kubernetes access.
sudo -u jenkins \
    KUBECONFIG=/var/lib/jenkins/.kube/config \
    kubectl get nodes >/dev/null ||
    fail "Jenkins cannot access Kubernetes."

echo
echo "Jenkins Docker access: OK"
echo "Jenkins Kubernetes access: OK"

# ============================================================
# 13. REPOSITORIES + PYTHON
# ============================================================

log "13/14 - REPOSITORIES + PYTHON"

cd "$HOME"

for repo in "${REPOS[@]}"; do

    if [[ -d "$HOME/$repo/.git" ]]; then

        echo
        echo "$repo already exists."

        git -C "$HOME/$repo" fetch origin
        git -C "$HOME/$repo" reset --hard origin/main

    else

        echo
        echo "Cloning $repo..."

        git clone \
            "https://github.com/${GITHUB_ORG}/${repo}.git" \
            "$HOME/$repo"

    fi

done

# Vote test environment.
cd "$HOME/voting-app-vote"

if [[ ! -d .venv ]]; then
    python3 -m venv .venv
fi

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
# 14. FINAL VALIDATION
# ============================================================

log "14/14 - FINAL VALIDATION"

echo
echo "========== SYSTEM =========="

echo "User: $(whoami)"
echo "CPU: $(nproc)"

echo
df -h /

echo
echo "========== 20GB STORAGE =========="

lsblk -f

echo
df -h "$DATA_MOUNT"

echo
echo "Mount:"
findmnt "$DATA_MOUNT"

echo
echo "Persistent mount:"
grep "$DATA_MOUNT" /etc/fstab || true

echo
echo "========== DOCKER =========="

docker --version
docker buildx version

echo
echo "Docker Root Dir:"
sudo docker info --format '{{.DockerRootDir}}'

echo
echo "Docker containers:"
docker ps

echo
echo "========== CONTAINERD =========="

containerd --version

echo
echo "Containerd data:"
sudo du -sh "$CONTAINERD_DATA" 2>/dev/null || true

echo
echo "========== KUBERNETES =========="

kubectl version --client

echo
echo "Minikube:"
sg docker -c 'minikube status'

echo
echo "Nodes:"
kubectl get nodes

echo
echo "Pods:"
kubectl get pods -A

echo
echo "========== JENKINS =========="

java -version
jenkins --version

echo
echo "Jenkins service:"
systemctl is-active jenkins
systemctl is-enabled jenkins

echo
echo "Jenkins Docker:"
sudo -u jenkins docker version --format '{{.Server.Version}}'

echo
echo "Jenkins Kubernetes:"
sudo -u jenkins \
    KUBECONFIG=/var/lib/jenkins/.kube/config \
    kubectl get nodes

echo
echo "========== REPOSITORIES =========="

for repo in "${REPOS[@]}"; do

    echo
    echo "--- $repo ---"

    if [[ -d "$HOME/$repo/.git" ]]; then

        echo "Repository: PRESENT"

        echo "Latest commit:"
        git -C "$HOME/$repo" log --oneline -1

        echo "Remote:"
        git -C "$HOME/$repo" remote -v | head -2

        echo "Status:"
        git -C "$HOME/$repo" status --short

    else

        echo "Repository: MISSING"

    fi

done

echo
echo "========== VOTE TEST =========="

cd "$HOME/voting-app-vote"

source .venv/bin/activate
pytest -q
deactivate

rm -rf tests/__pycache__

echo
echo "========== DOCKER RUNTIME TEST =========="

docker run --rm hello-world >/dev/null

echo "Docker runtime: OK"

# ============================================================
# COMPLETE
# ============================================================

echo
echo "============================================================"
echo " EC2 MACHINE BOOTSTRAP COMPLETE"
echo "============================================================"

echo
echo "READY:"
echo "  Docker"
echo "  Docker Buildx"
echo "  Docker storage on 20GB EBS"
echo "  containerd storage on 20GB EBS"
echo "  kubectl"
echo "  Minikube"
echo "  Java 21"
echo "  Jenkins"
echo "  Jenkins -> Docker"
echo "  Jenkins -> Kubernetes"
echo "  Git"
echo "  Python"
echo "  pip"
echo "  venv"
echo "  pytest"
echo "  Five voting-app repositories"

echo
echo "NEXT:"
echo "  Run setup-voting-app-project.sh"

echo
echo "============================================================"
