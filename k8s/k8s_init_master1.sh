#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

init_sudo

NODE_IP="${NODE_IP:-$(detect_node_ip || true)}"
[[ -n "${NODE_IP}" ]] || die "cannot detect node IP; set NODE_IP=${MASTER1_IP}"

if [[ "${NODE_IP}" != "${MASTER1_IP}" && "${ALLOW_NON_MASTER1:-}" != "yes" ]]; then
  die "this script should run on ${MASTER1_IP}; set ALLOW_NON_MASTER1=yes to override"
fi

log "Initialize first control-plane through ${VIP_IP}:${API_LB_PORT}"
if ${SUDO} test -f /etc/kubernetes/admin.conf; then
  log "/etc/kubernetes/admin.conf exists; skip kubeadm init"
else
  ${SUDO} kubeadm init \
    --control-plane-endpoint "${VIP_IP}:${API_LB_PORT}" \
    --upload-certs \
    --apiserver-advertise-address="${NODE_IP}" \
    --pod-network-cidr="${POD_NETWORK_CIDR}" \
    --cri-socket="${CRI_SOCKET}" \
    | tee "${HOME}/kubeadm-init.log"
fi

log "Configure kubectl for current user"
mkdir -p "${HOME}/.kube"
${SUDO} cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
${SUDO} chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

log "Install Flannel"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

log "Create control-plane join script"
JOIN_BASE="$(kubeadm token create --print-join-command)"
CERT_KEY="$(${SUDO} kubeadm init phase upload-certs --upload-certs | tail -n 1)"
JOIN_SCRIPT="${HOME}/k8s-control-plane-join.sh"
cat > "${JOIN_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
sudo ${JOIN_BASE} \\
  --control-plane \\
  --certificate-key ${CERT_KEY} \\
  --cri-socket=${CRI_SOCKET}
EOF
chmod +x "${JOIN_SCRIPT}"

log "Join script written to ${JOIN_SCRIPT}"
log "Run it on ${MASTER2_IP} and ${MASTER3_IP} after k8s_prepare.sh"
