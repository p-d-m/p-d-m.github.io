#!/usr/bin/env bash

set -Eeuo pipefail

K8S_VERSION="${K8S_VERSION:-v1.36}"

MASTER1_IP="${MASTER1_IP:-192.168.3.214}"
MASTER2_IP="${MASTER2_IP:-192.168.3.215}"
MASTER3_IP="${MASTER3_IP:-192.168.3.216}"
VIP_IP="${VIP_IP:-192.168.3.217}"

MASTER1_NAME="${MASTER1_NAME:-k8s-master1}"
MASTER2_NAME="${MASTER2_NAME:-k8s-master2}"
MASTER3_NAME="${MASTER3_NAME:-k8s-master3}"
VIP_NAME="${VIP_NAME:-k8s-vip}"

API_LB_PORT="${API_LB_PORT:-8443}"
POD_NETWORK_CIDR="${POD_NETWORK_CIDR:-10.244.0.0/16}"
CRI_SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"
KEEPALIVED_AUTH_PASS="${KEEPALIVED_AUTH_PASS:-k8sha}"
VRID="${VRID:-51}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

init_sudo() {
  if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    sudo -v
    SUDO="sudo"
  fi
}

detect_default_iface() {
  ip -o -4 route show to default | awk '{print $5; exit}'
}

detect_node_ip() {
  local ip
  while read -r ip; do
    case "${ip}" in
      "${MASTER1_IP}"|"${MASTER2_IP}"|"${MASTER3_IP}")
        printf '%s\n' "${ip}"
        return 0
        ;;
    esac
  done < <(ip -o -4 addr show scope global | awk '{split($4, a, "/"); print a[1]}')

  return 1
}

node_name_from_ip() {
  case "$1" in
    "${MASTER1_IP}") printf '%s\n' "${MASTER1_NAME}" ;;
    "${MASTER2_IP}") printf '%s\n' "${MASTER2_NAME}" ;;
    "${MASTER3_IP}") printf '%s\n' "${MASTER3_NAME}" ;;
    *) die "unknown node IP: $1" ;;
  esac
}

keepalived_state_from_ip() {
  case "$1" in
    "${MASTER1_IP}") printf 'MASTER\n' ;;
    "${MASTER2_IP}"|"${MASTER3_IP}") printf 'BACKUP\n' ;;
    *) die "unknown node IP: $1" ;;
  esac
}

keepalived_priority_from_ip() {
  case "$1" in
    "${MASTER1_IP}") printf '101\n' ;;
    "${MASTER2_IP}") printf '100\n' ;;
    "${MASTER3_IP}") printf '99\n' ;;
    *) die "unknown node IP: $1" ;;
  esac
}

keepalived_peers_from_ip() {
  case "$1" in
    "${MASTER1_IP}") printf '        %s\n        %s\n' "${MASTER2_IP}" "${MASTER3_IP}" ;;
    "${MASTER2_IP}") printf '        %s\n        %s\n' "${MASTER1_IP}" "${MASTER3_IP}" ;;
    "${MASTER3_IP}") printf '        %s\n        %s\n' "${MASTER1_IP}" "${MASTER2_IP}" ;;
    *) die "unknown node IP: $1" ;;
  esac
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
}
