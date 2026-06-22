#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

require_kubectl

log "Show nodes"
kubectl get nodes -o wide

log "Allow control-plane nodes to run workload pods"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

log "Create nginx test deployment and NodePort service"
kubectl get deployment nginx >/dev/null 2>&1 || kubectl create deployment nginx --image=nginx:latest
kubectl get svc nginx >/dev/null 2>&1 || kubectl expose deployment nginx --port=80 --type=NodePort

log "Show nginx pods and service"
kubectl get pods -o wide
kubectl get svc nginx

NODE_PORT="$(kubectl get svc nginx -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
if [[ -n "${NODE_PORT}" ]]; then
  cat <<EOF

Nginx test URLs:
http://${MASTER1_IP}:${NODE_PORT}
http://${MASTER2_IP}:${NODE_PORT}
http://${MASTER3_IP}:${NODE_PORT}
EOF
fi

log "Post install finished"
