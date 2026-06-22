#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

SSH_USER="${SSH_USER:-root}"
WORKER_IPS="${WORKER_IPS-192.168.3.218 192.168.3.219 192.168.3.220}"
SSH_KEY="${SSH_KEY:-}"
ASSUME_YES=0
DRY_RUN=0
SKIP_WORKERS=0

usage() {
  cat <<EOF
Usage:
  bash k8s_shutdown_all.sh [options]

Options:
  -y, --yes       Do not ask for confirmation
      --dry-run   Print the shutdown plan only
      --no-workers
                  Only shut down the three master nodes
  -h, --help      Show this help

Environment variables:
  SSH_USER        SSH user for remote nodes, default: root
  SSH_KEY         Optional SSH private key path
  WORKER_IPS      Space separated worker IPs, default:
                  "192.168.3.218 192.168.3.219 192.168.3.220"

Examples:
  bash k8s_shutdown_all.sh --dry-run
  YES=yes bash k8s_shutdown_all.sh
  SSH_KEY=~/.ssh/id_rsa YES=yes bash k8s_shutdown_all.sh
  WORKER_IPS="" YES=yes bash k8s_shutdown_all.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-workers)
      SKIP_WORKERS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "${YES:-}" == "yes" ]]; then
  ASSUME_YES=1
fi

shutdown_command='if [ "$(id -u)" -eq 0 ]; then shutdown -h now; else sudo shutdown -h now; fi'

ssh_base_cmd() {
  local args=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=8
    -o StrictHostKeyChecking=accept-new
  )

  if [[ -n "${SSH_KEY}" ]]; then
    args+=(-i "${SSH_KEY}")
  fi

  printf '%q ' "${args[@]}"
}

remote_shutdown() {
  local ip="$1"
  local cmd

  cmd="$(ssh_base_cmd)"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] ${cmd}${SSH_USER}@${ip} '${shutdown_command}'"
    return 0
  fi

  log "Shutting down remote node ${ip}"
  # The SSH session may be closed by the shutdown itself. That is expected.
  bash -lc "${cmd}${SSH_USER}@${ip} '${shutdown_command}'" || true
}

local_shutdown() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "[dry-run] local: ${shutdown_command}"
    return 0
  fi

  log "Shutting down local node"
  if [[ "${EUID}" -eq 0 ]]; then
    shutdown -h now
  else
    sudo shutdown -h now
  fi
}

MASTER_IPS=("${MASTER1_IP}" "${MASTER2_IP}" "${MASTER3_IP}")
WORKER_IP_ARRAY=()
if [[ -n "${WORKER_IPS}" ]]; then
  read -r -a WORKER_IP_ARRAY <<< "${WORKER_IPS}"
fi

LOCAL_IP="$(detect_node_ip || true)"

cat <<EOF

K8s cluster shutdown plan

Masters:
  ${MASTER1_IP}  ${MASTER1_NAME}
  ${MASTER2_IP}  ${MASTER2_NAME}
  ${MASTER3_IP}  ${MASTER3_NAME}

Workers:
EOF

if [[ "${SKIP_WORKERS}" -eq 1 || "${#WORKER_IP_ARRAY[@]}" -eq 0 ]]; then
  printf '  none\n'
else
  for ip in "${WORKER_IP_ARRAY[@]}"; do
    [[ -n "${ip}" ]] && printf '  %s\n' "${ip}"
  done
fi

cat <<EOF

Local master detected: ${LOCAL_IP:-not a configured master}
Shutdown order:
  1. workers
  2. remote masters
  3. local master

EOF

if command -v kubectl >/dev/null 2>&1; then
  log "Current nodes"
  kubectl get nodes -o wide || true
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "Dry run only. No node will be shut down."
else
  if [[ "${ASSUME_YES}" -ne 1 ]]; then
    printf 'Type SHUTDOWN to power off the cluster: '
    read -r answer
    [[ "${answer}" == "SHUTDOWN" ]] || die "cancelled"
  fi
fi

if [[ "${SKIP_WORKERS}" -ne 1 ]]; then
  for ip in "${WORKER_IP_ARRAY[@]}"; do
    [[ -n "${ip}" ]] || continue
    remote_shutdown "${ip}"
  done
fi

for ip in "${MASTER_IPS[@]}"; do
  if [[ -n "${LOCAL_IP}" && "${ip}" == "${LOCAL_IP}" ]]; then
    continue
  fi

  remote_shutdown "${ip}"
done

if [[ -n "${LOCAL_IP}" ]]; then
  local_shutdown
else
  log "This machine is not one of the configured masters. Local shutdown skipped."
fi
