#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Voting App - Project-Level Setup
#
# Assumes:
#   setup-voting-app-ec2.sh has already been completed.
#
# This script:
#   1. Verifies the machine/Kubernetes prerequisites
#   2. Creates the voting-app namespace
#   3. Creates app-config
#   4. Creates db-secret interactively
#   5. Creates required ServiceAccounts
#   6. Enables Metrics Server for HPA
#   7. Deploys DB + Redis
#   8. Deploys Vote + Worker + Result
#   9. Waits for deployments
#  10. Verifies pods, services, HPA, PVC
#  11. Tests Vote and Result NodePorts
#
# Credentials are NOT stored in this script.
#
# NOTE:
# Project-wide production resources such as Ingress,
# RBAC rules, NetworkPolicies and PDB manifests will be
# persisted/handled separately when we finalize the complete
# production-grade configuration.
# ============================================================

NAMESPACE="voting-app"

ROOT="$HOME"

DB_REPO="$ROOT/voting-app-db"
REDIS_REPO="$ROOT/voting-app-redis"
VOTE_REPO="$ROOT/voting-app-vote"
WORKER_REPO="$ROOT/voting-app-worker"
RESULT_REPO="$ROOT/voting-app-result"

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

# ------------------------------------------------------------
# 1. Verify machine prerequisites
# ------------------------------------------------------------

log "1/9 - VERIFYING MACHINE"

command -v docker >/dev/null 2>&1 ||
    fail "Docker is not installed."

command -v kubectl >/dev/null 2>&1 ||
    fail "kubectl is not installed."

command -v minikube >/dev/null 2>&1 ||
    fail "Minikube is not installed."

# Docker daemon check does not depend on the current shell's
# supplementary groups.
sudo docker info >/dev/null 2>&1 ||
    fail "Docker service is not accessible."

# Kubernetes API check.
kubectl cluster-info >/dev/null 2>&1 ||
    fail "Kubernetes cluster is not reachable."

# Node readiness.
NODE_READY="$(
    kubectl get nodes --no-headers 2>/dev/null |
    awk '$2=="Ready"{print "yes"; exit}'
)"

[[ "$NODE_READY" == "yes" ]] ||
    fail "Kubernetes node is not Ready."

echo "Docker: OK"
echo "kubectl: OK"
echo "Minikube: OK"
echo "Kubernetes API: OK"
echo "Kubernetes node: Ready"

# ------------------------------------------------------------
# 2. Verify repositories
# ------------------------------------------------------------

log "2/9 - VERIFYING REPOSITORIES"

REQUIRED_REPOS=(
    "$DB_REPO"
    "$REDIS_REPO"
    "$VOTE_REPO"
    "$WORKER_REPO"
    "$RESULT_REPO"
)

for repo in "${REQUIRED_REPOS[@]}"; do
    [[ -d "$repo/.git" ]] ||
        fail "Repository missing: $repo"

    echo "✅ $(basename "$repo")"
done

# Required Kubernetes manifests.
REQUIRED_FILES=(
    "$DB_REPO/k8s/deployment.yaml"
    "$DB_REPO/k8s/pvc.yaml"
    "$DB_REPO/k8s/service.yaml"

    "$REDIS_REPO/k8s/deployment.yaml"
    "$REDIS_REPO/k8s/service.yaml"

    "$VOTE_REPO/k8s/deployment.yaml"
    "$VOTE_REPO/k8s/service.yaml"
    "$VOTE_REPO/k8s/hpa.yaml"

    "$WORKER_REPO/k8s/deployment.yaml"
    "$WORKER_REPO/k8s/hpa.yaml"

    "$RESULT_REPO/k8s/deployment.yaml"
    "$RESULT_REPO/k8s/service.yaml"
    "$RESULT_REPO/k8s/hpa.yaml"
)

for file in "${REQUIRED_FILES[@]}"; do
    [[ -f "$file" ]] ||
        fail "Required manifest missing: $file"
done

echo "✅ Required manifests present."

# ------------------------------------------------------------
# 3. Namespace
# ------------------------------------------------------------

log "3/9 - CREATING NAMESPACE"

if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace already exists: $NAMESPACE"
else
    kubectl create namespace "$NAMESPACE"
    echo "Namespace created: $NAMESPACE"
fi

kubectl get namespace "$NAMESPACE"

# ------------------------------------------------------------
# 4. Shared ConfigMap
# ------------------------------------------------------------

log "4/9 - CREATING SHARED CONFIGMAP"

kubectl create configmap app-config \
    -n "$NAMESPACE" \
    --from-literal=DB_HOST=db \
    --from-literal=DB_PORT=5432 \
    --from-literal=REDIS_HOST=redis \
    --from-literal=REDIS_PORT=6379 \
    --dry-run=client \
    -o yaml |
kubectl apply -f -

echo
kubectl get configmap app-config -n "$NAMESPACE"

# ------------------------------------------------------------
# 5. PostgreSQL Secret
# ------------------------------------------------------------

log "5/9 - CREATING DATABASE SECRET"

echo
read -r -p "PostgreSQL username [postgres]: " POSTGRES_USER
POSTGRES_USER="${POSTGRES_USER:-postgres}"

echo
read -r -s -p "PostgreSQL password: " POSTGRES_PASSWORD
echo

[[ -n "$POSTGRES_PASSWORD" ]] ||
    fail "PostgreSQL password cannot be empty."

kubectl create secret generic db-secret \
    -n "$NAMESPACE" \
    --from-literal=POSTGRES_USER="$POSTGRES_USER" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --dry-run=client \
    -o yaml |
kubectl apply -f -

echo
echo "Secret exists:"
kubectl get secret db-secret -n "$NAMESPACE"

# ------------------------------------------------------------
# 6. ServiceAccounts + Metrics Server
# ------------------------------------------------------------

log "6/9 - SERVICE ACCOUNTS + METRICS SERVER"

for sa in vote-sa result-sa worker-sa; do

    if kubectl get serviceaccount "$sa" \
        -n "$NAMESPACE" >/dev/null 2>&1; then

        echo "ServiceAccount exists: $sa"

    else

        kubectl create serviceaccount "$sa" \
            -n "$NAMESPACE"

        echo "ServiceAccount created: $sa"

    fi

done

echo
kubectl get serviceaccounts -n "$NAMESPACE"

echo
echo "Enabling Metrics Server..."

# Minikube may need Docker access through the docker group.
sg docker -c 'minikube addons enable metrics-server'

echo
echo "Metrics Server:"
kubectl get deployment metrics-server \
    -n kube-system \
    -o wide

# ------------------------------------------------------------
# 7. Deploy DB + Redis
# ------------------------------------------------------------

log "7/9 - DEPLOYING DATABASE + REDIS"

kubectl apply \
    -f "$DB_REPO/k8s/" \
    -n "$NAMESPACE"

kubectl apply \
    -f "$REDIS_REPO/k8s/" \
    -n "$NAMESPACE"

echo
echo "Waiting for DB deployment..."

kubectl rollout status deployment/db \
    -n "$NAMESPACE" \
    --timeout=240s

echo
echo "Waiting for Redis deployment..."

kubectl rollout status deployment/redis \
    -n "$NAMESPACE" \
    --timeout=240s

# ------------------------------------------------------------
# 8. Deploy Vote + Worker + Result
# ------------------------------------------------------------

log "8/9 - DEPLOYING APPLICATION SERVICES"

kubectl apply \
    -f "$VOTE_REPO/k8s/" \
    -n "$NAMESPACE"

kubectl apply \
    -f "$WORKER_REPO/k8s/" \
    -n "$NAMESPACE"

kubectl apply \
    -f "$RESULT_REPO/k8s/" \
    -n "$NAMESPACE"

echo
echo "Waiting for Vote..."

kubectl rollout status deployment/vote \
    -n "$NAMESPACE" \
    --timeout=240s

echo
echo "Waiting for Worker..."

kubectl rollout status deployment/worker \
    -n "$NAMESPACE" \
    --timeout=240s

echo
echo "Waiting for Result..."

kubectl rollout status deployment/result \
    -n "$NAMESPACE" \
    --timeout=240s

# ------------------------------------------------------------
# 9. Final verification
# ------------------------------------------------------------

log "9/9 - PROJECT VERIFICATION"

echo
echo "==================== PODS ===================="
kubectl get pods \
    -n "$NAMESPACE" \
    -o wide

echo
echo "==================== DEPLOYMENTS ===================="
kubectl get deployments \
    -n "$NAMESPACE"

echo
echo "==================== SERVICES ===================="
kubectl get services \
    -n "$NAMESPACE"

echo
echo "==================== HPA ===================="
kubectl get hpa \
    -n "$NAMESPACE"

echo
echo "==================== PVC ===================="
kubectl get pvc \
    -n "$NAMESPACE"

echo
echo "==================== SERVICE ACCOUNTS ===================="
kubectl get serviceaccounts \
    -n "$NAMESPACE"

# ------------------------------------------------------------
# Deployment readiness verification
# ------------------------------------------------------------

echo
echo "==================== DEPLOYMENT READINESS ===================="

DEPLOYMENTS=(
    db
    redis
    vote
    worker
    result
)

DEPLOYMENT_FAILURE=0

for deployment in "${DEPLOYMENTS[@]}"; do

    DESIRED="$(
        kubectl get deployment "$deployment" \
            -n "$NAMESPACE" \
            -o jsonpath='{.spec.replicas}'
    )"

    READY="$(
        kubectl get deployment "$deployment" \
            -n "$NAMESPACE" \
            -o jsonpath='{.status.readyReplicas}'
    )"

    AVAILABLE="$(
        kubectl get deployment "$deployment" \
            -n "$NAMESPACE" \
            -o jsonpath='{.status.availableReplicas}'
    )"

    DESIRED="${DESIRED:-0}"
    READY="${READY:-0}"
    AVAILABLE="${AVAILABLE:-0}"

    echo
    echo "$deployment"
    echo "  Desired   : $DESIRED"
    echo "  Ready     : $READY"
    echo "  Available : $AVAILABLE"

    if [[ "$READY" -ge 1 && "$AVAILABLE" -ge 1 ]]; then
        echo "  ✅ Ready"
    else
        echo "  ❌ Not ready"
        DEPLOYMENT_FAILURE=1
    fi

done

# ------------------------------------------------------------
# Verify required services
# ------------------------------------------------------------

echo
echo "==================== SERVICE VERIFICATION ===================="

for service in db redis vote result; do

    if kubectl get service "$service" \
        -n "$NAMESPACE" >/dev/null 2>&1; then

        echo "✅ Service exists: $service"

    else

        echo "❌ Service missing: $service"
        DEPLOYMENT_FAILURE=1

    fi

done

# ------------------------------------------------------------
# NodePort endpoint verification
# ------------------------------------------------------------

echo
echo "==================== FRONTEND ENDPOINT TEST ===================="

# Use sg docker because minikube itself uses Docker.
MINIKUBE_IP="$(sg docker -c 'minikube ip')"

echo "Minikube IP: $MINIKUBE_IP"

echo
echo "Testing Vote..."

VOTE_CODE="$(
    curl -s \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 5 \
        --max-time 15 \
        "http://${MINIKUBE_IP}:31000" || true
)"

echo "Vote HTTP status: $VOTE_CODE"

echo
echo "Testing Result..."

RESULT_CODE="$(
    curl -s \
        -o /dev/null \
        -w '%{http_code}' \
        --connect-timeout 5 \
        --max-time 15 \
        "http://${MINIKUBE_IP}:31001" || true
)"

echo "Result HTTP status: $RESULT_CODE"

# ------------------------------------------------------------
# HPA availability
# ------------------------------------------------------------

echo
echo "==================== HPA VERIFICATION ===================="

HPA_FAILURE=0

for hpa in vote-hpa result-hpa worker-hpa; do

    if kubectl get hpa "$hpa" \
        -n "$NAMESPACE" >/dev/null 2>&1; then

        echo "✅ HPA exists: $hpa"

    else

        echo "❌ HPA missing: $hpa"
        HPA_FAILURE=1

    fi

done

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------

echo
echo "============================================================"
echo " FINAL PROJECT RESULT"
echo "============================================================"

if [[ \
    "$DEPLOYMENT_FAILURE" -eq 0 && \
    "$HPA_FAILURE" -eq 0 && \
    "$VOTE_CODE" == "200" && \
    "$RESULT_CODE" == "200"
]]; then

    echo
    echo "✅ PROJECT SETUP SUCCESSFUL"
    echo
    echo "All application deployments are ready."
    echo "Vote endpoint  : http://${MINIKUBE_IP}:31000"
    echo "Result endpoint: http://${MINIKUBE_IP}:31001"
    echo
    echo "The application is ready for functional testing."

else

    echo
    echo "❌ PROJECT SETUP VERIFICATION FAILED"
    echo
    echo "Deployment failure : $DEPLOYMENT_FAILURE"
    echo "HPA failure        : $HPA_FAILURE"
    echo "Vote HTTP          : $VOTE_CODE"
    echo "Result HTTP        : $RESULT_CODE"
    echo
    echo "Run:"
    echo "  kubectl get pods -n $NAMESPACE"
    echo "  kubectl describe pods -n $NAMESPACE"
    echo "  kubectl logs -n $NAMESPACE <pod-name>"
    echo

    exit 1

fi

echo
echo "============================================================"
