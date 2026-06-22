#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

init_sudo

LOCAL_JOIN_SCRIPT="${HOME}/k8s-control-plane-join.sh"

if [[ $# -gt 0 ]]; then
  JOIN_COMMAND="$*"
elif [[ -n "${JOIN_COMMAND:-}" ]]; then
  JOIN_COMMAND="${JOIN_COMMAND}"
elif [[ -f "${LOCAL_JOIN_SCRIPT}" ]]; then
  log "Run ${LOCAL_JOIN_SCRIPT}"
  bash "${LOCAL_JOIN_SCRIPT}"
  JOIN_COMMAND=""
else
  die "provide JOIN_COMMAND='sudo kubeadm join ... --control-plane --certificate-key ...' or copy ${LOCAL_JOIN_SCRIPT}"
fi

if [[ -n "${JOIN_COMMAND:-}" ]]; then
  log "Join this node as a control-plane"
  if [[ "${JOIN_COMMAND}" != *"--control-plane"* ]]; then
    JOIN_COMMAND="${JOIN_COMMAND} --control-plane"
  fi
  if [[ "${JOIN_COMMAND}" != *"--cri-socket"* ]]; then
    JOIN_COMMAND="${JOIN_COMMAND} --cri-socket=${CRI_SOCKET}"
  fi
  if [[ "${JOIN_COMMAND}" != sudo* && "${EUID}" -ne 0 ]]; then
    JOIN_COMMAND="sudo ${JOIN_COMMAND}"
  fi
  eval "${JOIN_COMMAND}"
fi

if ${SUDO} test -f /etc/kubernetes/admin.conf; then
  log "Configure kubectl for current user"
  mkdir -p "${HOME}/.kube"
  ${SUDO} cp -f /etc/kubernetes/admin.conf "${HOME}/.kube/config"
  ${SUDO} chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
fi

log "Control-plane join finished"
