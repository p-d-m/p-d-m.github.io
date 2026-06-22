#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

init_sudo

if [[ "${YES:-}" != "yes" && "${K8S_RESET_CONFIRM:-}" != "yes" ]]; then
  printf 'This will remove the local Kubernetes state on this node.\n'
  printf 'Type "yes" to continue: '
  read -r answer
  [[ "${answer}" == "yes" ]] || die "reset cancelled"
fi

log "Reset kubeadm state"
${SUDO} kubeadm reset -f || true

log "Remove Kubernetes, etcd, kubelet and CNI data"
${SUDO} rm -rf /etc/kubernetes
${SUDO} rm -rf /var/lib/etcd
${SUDO} rm -rf /var/lib/kubelet
${SUDO} rm -rf /etc/cni/net.d
${SUDO} rm -rf /var/lib/cni
rm -rf "${HOME}/.kube"

log "Restart services if present"
${SUDO} systemctl restart containerd || true
${SUDO} systemctl restart kubelet || true

log "Reset finished"
