locals {
  # ---------------------------------------------------------------------------
  # Network Info: CP (single NIC) vs Worker (dual NIC)
  # ---------------------------------------------------------------------------
  network_info_cp = jsonencode({
    interfaces = [{
      networkName = "${var.harvester_network_namespace}/${var.harvester_network_name}"
    }]
  })

  network_info_worker = jsonencode({
    interfaces = [
      { networkName = "${var.harvester_network_namespace}/${var.harvester_network_name}" },
      { networkName = "${var.harvester_services_network_namespace}/${var.harvester_services_network_name}" },
    ]
  })

  # ---------------------------------------------------------------------------
  # Golden image reference (always golden — no vanilla path)
  # ---------------------------------------------------------------------------
  image_full_name = "${var.vm_namespace}/${data.harvester_image.golden.name}"

  # ---------------------------------------------------------------------------
  # Cloud-init: deployment-specific config applied on top of golden image.
  # Golden image has packages/repos/iptables baked in. Cloud-init handles:
  #   - SSH keys (both)
  #   - Cilium L2 manifests (CP only)
  #   - vault-root-ca placeholder ConfigMap (CP only — enables Traefik without deploy scripts)
  #   - Dual-NIC networking: ARP + eth1 policy routing (workers only)
  #   - Private CA trust (both)
  # ---------------------------------------------------------------------------
  user_data_cp = <<-EOF
    #cloud-config

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    write_files:
    - path: /var/lib/rancher/rke2/server/manifests/cilium-lb-ippool.yaml
      permissions: '0644'
      content: |
        apiVersion: "cilium.io/v2alpha1"
        kind: CiliumLoadBalancerIPPool
        metadata:
          name: ingress-pool
        spec:
          blocks:
            - start: "${var.cilium_lb_pool_start}"
              stop: "${var.cilium_lb_pool_stop}"

    - path: /var/lib/rancher/rke2/server/manifests/cilium-l2-policy.yaml
      permissions: '0644'
      content: |
        apiVersion: "cilium.io/v2alpha1"
        kind: CiliumL2AnnouncementPolicy
        metadata:
          name: l2-policy
        spec:
          serviceSelector:
            matchLabels: {}
          nodeSelector:
            matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
          interfaces:
            - ^eth1$
          externalIPs: true
          loadBalancerIPs: true

    - path: /var/lib/rancher/rke2/server/manifests/vault-root-ca-placeholder.yaml
      permissions: '0644'
      content: |
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: vault-root-ca
          namespace: kube-system
        data:
          ca.crt: ""

    - path: /etc/pki/ca-trust/source/anchors/private-ca.pem
      permissions: '0644'
      content: |
        ${indent(4, var.private_ca_pem)}

    - path: /etc/sysconfig/iptables
      permissions: '0600'
      content: |
        *filter
        :INPUT DROP [0:0]
        :FORWARD ACCEPT [0:0]
        :OUTPUT DROP [0:0]
        # --- INPUT rules ---
        -A INPUT -i lo -j ACCEPT
        -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        -A INPUT -p icmp -j ACCEPT
        -A INPUT -p tcp --dport 22 -j ACCEPT
        -A INPUT -p tcp --dport 6443 -j ACCEPT
        -A INPUT -p tcp --dport 9345 -j ACCEPT
        -A INPUT -p tcp --dport 2379:2381 -j ACCEPT
        -A INPUT -p tcp --dport 10250 -j ACCEPT
        -A INPUT -p tcp --dport 10257 -j ACCEPT
        -A INPUT -p tcp --dport 10259 -j ACCEPT
        -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
        -A INPUT -p udp --dport 30000:32767 -j ACCEPT
        -A INPUT -p tcp --dport 4240 -j ACCEPT
        -A INPUT -p udp --dport 8472 -j ACCEPT
        -A INPUT -p tcp --dport 4244 -j ACCEPT
        -A INPUT -p tcp --dport 4245 -j ACCEPT
        -A INPUT -p tcp --dport 9962 -j ACCEPT
        -A INPUT -p tcp --dport 9100 -j ACCEPT
        # --- OUTPUT rules (airgap enforcement) ---
        # Allow all RFC1918 private networks, block public internet
        -A OUTPUT -o lo -j ACCEPT
        -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
        -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
        -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
        -A OUTPUT -p udp --dport 53 -j ACCEPT
        -A OUTPUT -p tcp --dport 53 -j ACCEPT
        -A OUTPUT -p udp --dport 123 -j ACCEPT
        -A OUTPUT -p icmp -j ACCEPT
        COMMIT

    runcmd:
    - mkdir -p /var/lib/rancher/rke2/server/manifests
    - update-ca-trust
    - systemctl enable --now iptables
  EOF

  user_data_worker = <<-EOF
    #cloud-config

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    write_files:
    - path: /etc/sysctl.d/90-arp.conf
      permissions: '0644'
      content: |
        net.ipv4.conf.all.arp_ignore=1
        net.ipv4.conf.all.arp_announce=2

    - path: /etc/NetworkManager/dispatcher.d/10-ingress-routing
      permissions: '0755'
      content: |
        #!/bin/bash
        # Policy routing for ingress NIC (eth1)
        # Ensures traffic from eth1's IP replies via eth1
        IFACE=$1
        ACTION=$2
        if [ "$IFACE" = "eth1" ] && [ "$ACTION" = "up" ]; then
          IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
          SUBNET=$(ip -4 route show dev eth1 scope link | awk '{print $1}' | head -1)
          GW=$(ip -4 route show dev eth1 | grep default | awk '{print $3}')
          [ -z "$GW" ] && GW=$(ip -4 route show default | awk '{print $3}' | head -1)
          grep -q "^200 ingress" /etc/iproute2/rt_tables || echo "200 ingress" >> /etc/iproute2/rt_tables
          ip rule add from $IP table ingress priority 100 2>/dev/null || true
          ip route replace default via $GW dev eth1 table ingress 2>/dev/null || true
          [ -n "$SUBNET" ] && ip route replace $SUBNET dev eth1 table ingress 2>/dev/null || true
        fi

    - path: /etc/pki/ca-trust/source/anchors/private-ca.pem
      permissions: '0644'
      content: |
        ${indent(4, var.private_ca_pem)}

    - path: /etc/sysconfig/iptables
      permissions: '0600'
      content: |
        *filter
        :INPUT DROP [0:0]
        :FORWARD ACCEPT [0:0]
        :OUTPUT DROP [0:0]
        # --- INPUT rules ---
        -A INPUT -i lo -j ACCEPT
        -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        -A INPUT -p icmp -j ACCEPT
        -A INPUT -p tcp --dport 22 -j ACCEPT
        -A INPUT -p tcp --dport 6443 -j ACCEPT
        -A INPUT -p tcp --dport 9345 -j ACCEPT
        -A INPUT -p tcp --dport 2379:2381 -j ACCEPT
        -A INPUT -p tcp --dport 10250 -j ACCEPT
        -A INPUT -p tcp --dport 10257 -j ACCEPT
        -A INPUT -p tcp --dport 10259 -j ACCEPT
        -A INPUT -p tcp --dport 30000:32767 -j ACCEPT
        -A INPUT -p udp --dport 30000:32767 -j ACCEPT
        -A INPUT -p tcp --dport 4240 -j ACCEPT
        -A INPUT -p udp --dport 8472 -j ACCEPT
        -A INPUT -p tcp --dport 4244 -j ACCEPT
        -A INPUT -p tcp --dport 4245 -j ACCEPT
        -A INPUT -p tcp --dport 9962 -j ACCEPT
        -A INPUT -p tcp --dport 9100 -j ACCEPT
        # --- OUTPUT rules (airgap enforcement) ---
        # Allow all RFC1918 private networks, block public internet
        -A OUTPUT -o lo -j ACCEPT
        -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
        -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
        -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
        -A OUTPUT -p udp --dport 53 -j ACCEPT
        -A OUTPUT -p tcp --dport 53 -j ACCEPT
        -A OUTPUT -p udp --dport 123 -j ACCEPT
        -A OUTPUT -p icmp -j ACCEPT
        COMMIT

    runcmd:
    - sysctl --system
    - restorecon -R /etc/NetworkManager/dispatcher.d/ || true
    - update-ca-trust
    - systemctl enable --now iptables
  EOF
}

# -----------------------------------------------------------------------------
# Control Plane Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "controlplane" {
  generate_name = "${var.cluster_name}-cp"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.controlplane_cpu
    memory_size          = var.controlplane_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_cp

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.controlplane_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_cp
  }
}

# -----------------------------------------------------------------------------
# General Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "general" {
  generate_name = "${var.cluster_name}-general"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.general_cpu
    memory_size          = var.general_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.general_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# Compute Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "compute" {
  generate_name = "${var.cluster_name}-compute"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.compute_cpu
    memory_size          = var.compute_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.compute_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# Database Worker Nodes
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "database" {
  generate_name = "${var.cluster_name}-database"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.database_cpu
    memory_size          = var.database_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_worker

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.database_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}
