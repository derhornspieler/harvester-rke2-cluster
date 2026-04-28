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
  # Golden image reference (always golden — no vanilla path).
  # Image namespace is typically 'default' (shared), distinct from vm_namespace.
  # ---------------------------------------------------------------------------
  image_full_name = "${var.harvester_image_namespace}/${data.harvester_image.golden.name}"

  # ---------------------------------------------------------------------------
  # VM anti-affinity: spread pool VMs across Harvester hosts.
  # Harvester's docker-machine driver labels each VM with:
  #   harvesterhci.io/machineSetName: <vm_namespace>-<cluster_name>-<pool_name>
  # All pools use preferredDuringScheduling (soft) for best-effort spread.
  # Hard (required) on CP blocks rolling replacement because the surge replica
  # can't schedule when every Harvester host already runs a CP VM. Soft still
  # spreads in steady state but permits temporary co-location during rollouts;
  # etcd quorum is protected by having 3 healthy CPs at any moment, not by
  # VM-level host constraints.
  # Requires Harvester >=1.2.2 / 1.3.0 for machineSetName label support.
  # ---------------------------------------------------------------------------
  vm_affinity_cp = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-controlplane"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  vm_affinity_general = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-general"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  vm_affinity_compute = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-compute"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  vm_affinity_database = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-database"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  # ---------------------------------------------------------------------------
  # VM anti-affinity for Shape B-2 pools (lb, ingress)
  # ---------------------------------------------------------------------------
  vm_affinity_lb = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-lb"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  vm_affinity_ingress = base64encode(jsonencode({
    podAntiAffinity = {
      preferredDuringSchedulingIgnoredDuringExecution = [{
        weight = 100
        podAffinityTerm = {
          labelSelector = {
            matchExpressions = [{
              key      = "harvesterhci.io/machineSetName"
              operator = "In"
              values   = ["${var.vm_namespace}-${var.cluster_name}-ingress"]
            }]
          }
          topologyKey = "kubernetes.io/hostname"
        }
      }]
    }
  }))

  # ---------------------------------------------------------------------------
  # Cilium L2 announce policy — embedded in CP user_data as static manifest.
  # nodeSelector flips between the legacy "all non-CP workers" pattern and
  # the Shape B-2 pattern (workload-type=lb only) so the L2 lease holder
  # is always on a node that has NO local Traefik backend — sidesteps the
  # cilium #44630 same-node DNAT bug.
  # ---------------------------------------------------------------------------
  # nodeSelector substring (only): two leaf-block variants. Both share
  # the same source-level indentation so when interpolated into the
  # user_data_cp heredoc at the right position, Terraform's heredoc
  # whitespace stripping handles them uniformly. Using a leaf-only
  # substitution avoids the "multi-line interpolation across two heredoc
  # contexts" bug where indent()'s output gets unevenly stripped.
  l2_policy_node_selector = var.enable_dedicated_ingress_pool ? "matchLabels:\n            workload-type: lb" : "matchExpressions:\n            - key: node-role.kubernetes.io/control-plane\n              operator: DoesNotExist"

  # ---------------------------------------------------------------------------
  # Optional NTP/chrony config — only included when ntp_servers is non-empty
  # ---------------------------------------------------------------------------
  ntp_servers_list = var.ntp_servers != "" ? split(" ", var.ntp_servers) : []
  ntp_config = var.ntp_servers != "" ? join("", [
    "\n    - path: /etc/chrony.conf\n",
    "      permissions: '0644'\n",
    "      content: |\n",
    "        # Custom NTP servers (from ntp_servers variable)\n",
    join("", [for s in local.ntp_servers_list : "        server ${s} iburst\n"]),
    "        driftfile /var/lib/chrony/drift\n",
    "        makestep 1.0 3\n",
    "        rtcsync\n",
    "        logdir /var/log/chrony\n",
  ]) : ""

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
    # rotation-marker: ${var.rotation_marker}

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    packages:
      - chrony

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
            ${local.l2_policy_node_selector}
          interfaces:
            - ^eth1$
          externalIPs: true
          loadBalancerIPs: true

    - path: /var/lib/rancher/rke2/server/manifests/vault-root-ca.yaml
      permissions: '0644'
      content: |
        apiVersion: v1
        kind: ConfigMap
        metadata:
          name: vault-root-ca
          namespace: kube-system
        data:
          ca.crt: |
            ${indent(8, var.private_ca_pem)}

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

    ${local.ntp_config}
    runcmd:
    - mkdir -p /var/lib/rancher/rke2/server/manifests
    - update-ca-trust
    - systemctl enable --now iptables
    - systemctl enable --now chronyd
    - systemctl restart chronyd
  EOF

  user_data_dualnic = <<-EOF
    #cloud-config
    # rotation-marker: ${var.rotation_marker}

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    packages:
      - chrony

    write_files:
    - path: /etc/sysctl.d/90-arp.conf
      permissions: '0644'
      content: |
        net.ipv4.conf.all.arp_ignore=1
        net.ipv4.conf.all.arp_announce=2

    - path: /usr/local/bin/ingress-routing.sh
      permissions: '0755'
      content: |
        #!/bin/bash
        set -euo pipefail
        # Maintain policy routing table 200 ("ingress") for eth1.
        # Ensures ingress traffic arriving on eth1 (VIP LB) exits via eth1.
        # Runs as a persistent service to survive NM route-table sync,
        # DHCP renewals, and interface bounces.
        IFACE="eth1"
        TABLE_ID="200"
        TABLE_NAME="ingress"
        POLL_INTERVAL=5
        setup_routes() {
          local subnet gw
          subnet=$(ip -4 route show dev "$IFACE" scope link 2>/dev/null | awk '{print $1}' | head -1)
          [ -z "$subnet" ] && return 1
          gw=$(ip -4 route show dev "$IFACE" 2>/dev/null | grep default | awk '{print $3}')
          [ -z "$gw" ] && gw=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
          [ -z "$gw" ] && return 1
          grep -q "^$${TABLE_ID} $${TABLE_NAME}" /etc/iproute2/rt_tables 2>/dev/null || \
            echo "$${TABLE_ID} $${TABLE_NAME}" >> /etc/iproute2/rt_tables
          ip rule add from "$subnet" table "$TABLE_NAME" priority 100 2>/dev/null || true
          ip route replace default via "$gw" dev "$IFACE" table "$TABLE_NAME" 2>/dev/null || true
          ip route replace "$subnet" dev "$IFACE" table "$TABLE_NAME" 2>/dev/null || true
          return 0
        }
        while true; do
          setup_routes || true
          sleep "$POLL_INTERVAL"
        done

    - path: /etc/systemd/system/ingress-routing.service
      permissions: '0644'
      content: |
        [Unit]
        Description=Maintain ingress policy routing table 200 for eth1
        After=network-online.target
        Wants=network-online.target
        [Service]
        Type=simple
        ExecStart=/usr/local/bin/ingress-routing.sh
        Restart=always
        RestartSec=5
        [Install]
        WantedBy=multi-user.target

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

    ${local.ntp_config}
    runcmd:
    - sysctl --system
    - restorecon -R /usr/local/bin/ || true
    - systemctl enable --now ingress-routing.service
    - update-ca-trust
    - systemctl enable --now iptables
    - systemctl enable --now chronyd
    - systemctl restart chronyd
  EOF

  # ---------------------------------------------------------------------------
  # Single-NIC worker cloud-init (Shape B-2 — for general/compute/database
  # pools when var.enable_dedicated_ingress_pool=true). Identical to dualnic
  # except: NO ingress-routing daemon, NO ingress-routing.service. ARP sysctl
  # rules are kept (defensive; harmless on single-NIC). All other config
  # (iptables / CA trust / chrony / NTP) identical.
  # ---------------------------------------------------------------------------
  user_data_singlenic = <<-EOF
    #cloud-config
    # rotation-marker: ${var.rotation_marker}

    ssh_authorized_keys:
    ${join("\n", [for key in var.ssh_authorized_keys : "  - ${key}"])}

    packages:
      - chrony

    write_files:
    - path: /etc/sysctl.d/90-arp.conf
      permissions: '0644'
      content: |
        net.ipv4.conf.all.arp_ignore=1
        net.ipv4.conf.all.arp_announce=2

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

    ${local.ntp_config}
    runcmd:
    - sysctl --system
    - update-ca-trust
    - systemctl enable --now iptables
    - systemctl enable --now chronyd
    - systemctl restart chronyd
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
    vm_affinity          = local.vm_affinity_cp

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
    user_data            = var.enable_dedicated_ingress_pool ? local.user_data_singlenic : local.user_data_dualnic
    vm_affinity          = local.vm_affinity_general

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.general_disk_size
        bootOrder = 1
      }]
    })

    network_info = var.enable_dedicated_ingress_pool ? local.network_info_cp : local.network_info_worker
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
    user_data            = var.enable_dedicated_ingress_pool ? local.user_data_singlenic : local.user_data_dualnic
    vm_affinity          = local.vm_affinity_compute

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.compute_disk_size
        bootOrder = 1
      }]
    })

    network_info = var.enable_dedicated_ingress_pool ? local.network_info_cp : local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# LB Pool — Cilium L2 announcer only (no Traefik backend). Shape B-2.
# Created only when var.enable_dedicated_ingress_pool = true.
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "lb" {
  count         = var.enable_dedicated_ingress_pool ? 1 : 0
  generate_name = "${var.cluster_name}-lb"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.lb_cpu
    memory_size          = var.lb_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_dualnic
    vm_affinity          = local.vm_affinity_lb

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.lb_disk_size
        bootOrder = 1
      }]
    })

    network_info = local.network_info_worker
  }
}

# -----------------------------------------------------------------------------
# Ingress Pool — Traefik DS only (no L2 announce). Shape B-2.
# Created only when var.enable_dedicated_ingress_pool = true.
# -----------------------------------------------------------------------------
resource "rancher2_machine_config_v2" "ingress" {
  count         = var.enable_dedicated_ingress_pool ? 1 : 0
  generate_name = "${var.cluster_name}-ingress"

  harvester_config {
    vm_namespace         = var.vm_namespace
    cpu_count            = var.ingress_cpu
    memory_size          = var.ingress_memory
    reserved_memory_size = "-1"
    ssh_user             = var.ssh_user
    user_data            = local.user_data_dualnic
    vm_affinity          = local.vm_affinity_ingress

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.ingress_disk_size
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
    user_data            = var.enable_dedicated_ingress_pool ? local.user_data_singlenic : local.user_data_dualnic
    vm_affinity          = local.vm_affinity_database

    disk_info = jsonencode({
      disks = [{
        imageName = local.image_full_name
        size      = var.database_disk_size
        bootOrder = 1
      }]
    })

    network_info = var.enable_dedicated_ingress_pool ? local.network_info_cp : local.network_info_worker
  }
}
