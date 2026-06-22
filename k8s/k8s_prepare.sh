#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s_env.sh
source "${SCRIPT_DIR}/k8s_env.sh"

init_sudo

NODE_IP="${NODE_IP:-$(detect_node_ip || true)}"
[[ -n "${NODE_IP}" ]] || die "cannot detect node IP; set NODE_IP=${MASTER1_IP}|${MASTER2_IP}|${MASTER3_IP}"

NODE_NAME="${NODE_NAME:-$(node_name_from_ip "${NODE_IP}")}"
IFACE="${IFACE:-$(detect_default_iface)}"
[[ -n "${IFACE}" ]] || die "cannot detect default network interface; set IFACE=ens33"

export DEBIAN_FRONTEND=noninteractive

log "Node: ${NODE_NAME} (${NODE_IP}), interface: ${IFACE}"

log "Install base packages"
${SUDO} apt update
${SUDO} apt install -y apt-transport-https ca-certificates curl gpg vim haproxy keepalived psmisc containerd

log "Disable swap"
${SUDO} swapoff -a || true
${SUDO} cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
${SUDO} sed -ri '/[[:space:]]swap[[:space:]]/ s/^([^#])/#\1/' /etc/fstab

log "Configure kernel modules"
cat <<'EOF' | ${SUDO} tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
${SUDO} modprobe overlay
${SUDO} modprobe br_netfilter

log "Configure sysctl"
cat <<'EOF' | ${SUDO} tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
EOF
${SUDO} sysctl --system

log "Configure /etc/hosts"
tmp_hosts="$(mktemp)"
awk '
  /# k8s-ha hosts begin/ { skip=1; next }
  /# k8s-ha hosts end/ { skip=0; next }
  !skip { print }
' /etc/hosts > "${tmp_hosts}"
cat >> "${tmp_hosts}" <<EOF
# k8s-ha hosts begin
${MASTER1_IP} ${MASTER1_NAME}
${MASTER2_IP} ${MASTER2_NAME}
${MASTER3_IP} ${MASTER3_NAME}
${VIP_IP} ${VIP_NAME}
# k8s-ha hosts end
EOF
${SUDO} cp "${tmp_hosts}" /etc/hosts
rm -f "${tmp_hosts}"

log "Set hostname"
${SUDO} hostnamectl set-hostname "${NODE_NAME}"

log "Configure containerd"
${SUDO} mkdir -p /etc/containerd
if [[ -f /etc/containerd/config.toml ]]; then
  ${SUDO} cp /etc/containerd/config.toml "/etc/containerd/config.toml.bak.$(date +%Y%m%d%H%M%S)"
fi
containerd config default | ${SUDO} tee /etc/containerd/config.toml >/dev/null
${SUDO} sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
${SUDO} systemctl restart containerd
${SUDO} systemctl enable containerd

log "Install kubeadm, kubelet and kubectl from Kubernetes ${K8S_VERSION}"
${SUDO} mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
  | ${SUDO} gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | ${SUDO} tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
${SUDO} apt update
${SUDO} apt install -y kubelet kubeadm kubectl
${SUDO} apt-mark hold kubelet kubeadm kubectl
${SUDO} systemctl enable --now kubelet

log "Configure HAProxy"
if [[ -f /etc/haproxy/haproxy.cfg ]]; then
  ${SUDO} cp /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)"
fi
cat <<EOF | ${SUDO} tee /etc/haproxy/haproxy.cfg >/dev/null
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
    maxconn 4096

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend kubernetes-apiserver
    bind *:${API_LB_PORT}
    mode tcp
    default_backend kubernetes-apiserver

backend kubernetes-apiserver
    mode tcp
    balance roundrobin
    option tcp-check
    server ${MASTER1_NAME} ${MASTER1_IP}:6443 check
    server ${MASTER2_NAME} ${MASTER2_IP}:6443 check
    server ${MASTER3_NAME} ${MASTER3_IP}:6443 check
EOF
${SUDO} systemctl restart haproxy
${SUDO} systemctl enable haproxy

log "Configure Keepalived"
KEEPALIVED_STATE="$(keepalived_state_from_ip "${NODE_IP}")"
KEEPALIVED_PRIORITY="$(keepalived_priority_from_ip "${NODE_IP}")"
KEEPALIVED_PEERS="$(keepalived_peers_from_ip "${NODE_IP}")"
cat <<EOF | ${SUDO} tee /etc/keepalived/keepalived.conf >/dev/null
vrrp_script chk_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight -20
}

vrrp_instance VI_1 {
    state ${KEEPALIVED_STATE}
    interface ${IFACE}
    virtual_router_id ${VRID}
    priority ${KEEPALIVED_PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}
    }

    unicast_src_ip ${NODE_IP}
    unicast_peer {
${KEEPALIVED_PEERS}
    }

    virtual_ipaddress {
        ${VIP_IP}/24
    }

    track_script {
        chk_haproxy
    }
}
EOF
${SUDO} systemctl restart keepalived
${SUDO} systemctl enable keepalived

log "Local VIP check"
ip addr | grep "${VIP_IP}" || true

log "Prepare finished"
