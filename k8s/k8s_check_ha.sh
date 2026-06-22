#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

require_kubectl

log "Kubectl server endpoint"
kubectl config view --minify | grep server || true

log "Nodes"
kubectl get nodes -o wide

log "System pods"
kubectl get pods -A -o wide

log "Etcd pods"
kubectl get pods -n kube-system -o wide | grep etcd || true

log "Local VIP check"
ip addr | grep "${VIP_IP}" || true

log "API health through VIP"
curl -kfsS --max-time 5 "https://${VIP_IP}:${API_LB_PORT}/healthz" || true

cat <<EOF

Manual HA test:
1. Find the node currently holding ${VIP_IP}.
2. Power off that node.
3. Wait several seconds, then run: kubectl get nodes
4. Run this script again and confirm ${VIP_IP} moved to another master.
EOF
