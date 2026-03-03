# RKE2 Cluster Architecture

## Overview

This document provides a technical deep-dive into the Harvester-based RKE2 cluster provisioning system. The Terraform codebase in this repository orchestrates the creation of a production-grade Kubernetes cluster on Harvester hypervisor infrastructure, integrated with Rancher management, Harbor container registry, and automated node management via custom operators.

**Key characteristics:**
- Golden image-first deployment (no vanilla OS downloads)
- Airgap-ready with Harbor proxy-cache for all upstream registries
- Four specialized node pools with autoscaling and scale-from-zero
- Cilium networking with L2 LoadBalancer announcement
- Private CA TLS trust chain
- EFI/UEFI boot requirement (OVMF firmware)
- Custom operators for node labeling and storage autoscaling
- Rancher 2 API integration for cluster lifecycle management

---

## 1. System Architecture Overview

The system consists of four major components that work together to provision and manage the RKE2 cluster:

```mermaid
graph TB
    subgraph Rancher["Rancher Management Cluster"]
        RancherAPI["Rancher API Server<br/>(rancher.example.com)"]
    end

    subgraph Harvester["Harvester Hypervisor"]
        HarvesterK8s["Harvester K8s Cluster<br/>(infrastructure)"]
        HarvesterVMs["Virtual Machines<br/>(RKE2 Cluster Nodes)"]
        GoldenImage["Golden Image<br/>(rke2-rocky9-golden)"]
        VMNetwork["VM Networks<br/>(eth0: cluster, eth1: services)"]
    end

    subgraph RKE2["RKE2 Downstream Cluster"]
        ControlPlanes["Control Plane Nodes<br/>(3x CP+etcd)"]
        GeneralWorkers["General Workers<br/>(4-10 autoscale)"]
        ComputeWorkers["Compute Workers<br/>(0-10 scale-from-zero)"]
        DatabaseWorkers["Database Workers<br/>(4-10 autoscale)"]
        Cilium["Cilium CNI<br/>(L2 LB)"]
        Traefik["Traefik Ingress<br/>(LoadBalancer)"]
    end

    subgraph Registry["Container Registry"]
        Bootstrap["Bootstrap Registry<br/>(Initial provisioning)"]
        Harbor["Harbor Proxy-Cache<br/>(Production pulls)"]
        Upstreams["Upstream Registries<br/>(docker.io, quay.io, etc.)"]
    end

    RancherAPI -->|Terraform Provider| HarvesterK8s
    RancherAPI -->|Cloud Credential| HarvesterVMs
    HarvesterK8s -->|Hosts| HarvesterVMs
    GoldenImage -->|Boot Image| HarvesterVMs
    HarvesterVMs -->|Runs| ControlPlanes
    HarvesterVMs -->|Runs| GeneralWorkers
    HarvesterVMs -->|Runs| ComputeWorkers
    HarvesterVMs -->|Runs| DatabaseWorkers
    VMNetwork -->|Connects| HarvesterVMs
    ControlPlanes -->|Installs| Cilium
    ControlPlanes -->|Installs| Traefik
    Cilium -->|L2 Announces| Traefik
    GeneralWorkers -->|Pulls from| Bootstrap
    ComputeWorkers -->|Pulls from| Bootstrap
    DatabaseWorkers -->|Pulls from| Bootstrap
    Bootstrap -->|Upstream| Upstreams
    GeneralWorkers -->|After cluster ready| Harbor
    Harbor -->|Proxy| Upstreams

    style Rancher fill:#4285f4,color:#fff
    style Harvester fill:#ff6b35,color:#fff
    style RKE2 fill:#00a878,color:#fff
    style Registry fill:#ffa500,color:#000
```

**Component Relationships:**

1. **Rancher Management Cluster** — The control point; provides API for Terraform and defines cloud credentials for Harvester
2. **Harvester Hypervisor** — Physical/virtualized infrastructure; hosts all RKE2 cluster VMs and the golden image
3. **RKE2 Cluster** — The downstream managed cluster with four node pools and Cilium + Traefik networking
4. **Container Registry** — Bootstrap registry for initial node provisioning, Harbor for production image pulls

---

## 2. Terraform Resource Dependency Graph

The Terraform configuration follows this dependency chain. Understanding the flow is critical for deployment troubleshooting:

```mermaid
graph TD
    A["1. Variables<br/>(terraform.tfvars)"]
    B["2. Providers<br/>(rancher2, harvester)"]
    C["3. Data: Golden Image<br/>(data.harvester_image.golden)"]
    D["4. Cloud Credential<br/>(rancher2_cloud_credential.harvester)"]

    E1["5a. Machine Config: CP<br/>(rancher2_machine_config_v2.controlplane)"]
    E2["5b. Machine Config: General<br/>(rancher2_machine_config_v2.general)"]
    E3["5c. Machine Config: Compute<br/>(rancher2_machine_config_v2.compute)"]
    E4["5d. Machine Config: Database<br/>(rancher2_machine_config_v2.database)"]

    F1["6a. EFI Patch: CP<br/>(null_resource.efi_controlplane)"]
    F2["6b. EFI Patch: General<br/>(null_resource.efi_general)"]
    F3["6c. EFI Patch: Compute<br/>(null_resource.efi_compute)"]
    F4["6d. EFI Patch: Database<br/>(null_resource.efi_database)"]

    G["7. RKE2 Cluster<br/>(rancher2_cluster_v2.rke2)"]

    H["8. Operator Kubeconfig<br/>(null_resource.operator_kubeconfig)"]
    I["9. Operator Image Push<br/>(null_resource.operator_image_push)"]

    J1["10a. Deploy: node-labeler<br/>(null_resource.deploy_node_labeler)"]
    J2["10b. Deploy: storage-autoscaler<br/>(null_resource.deploy_storage_autoscaler)"]

    A --> B
    B --> C
    B --> D
    C --> E1
    C --> E2
    C --> E3
    C --> E4
    E1 --> F1
    E2 --> F2
    E3 --> F3
    E4 --> F4
    D --> G
    F1 --> G
    F2 --> G
    F3 --> G
    F4 --> G
    G --> H
    H --> I
    I --> J1
    I --> J2

    style A fill:#e1f5ff
    style B fill:#e1f5ff
    style C fill:#fff3e0
    style D fill:#fff3e0
    style E1 fill:#f3e5f5
    style E2 fill:#f3e5f5
    style E3 fill:#f3e5f5
    style E4 fill:#f3e5f5
    style F1 fill:#fce4ec
    style F2 fill:#fce4ec
    style F3 fill:#fce4ec
    style F4 fill:#fce4ec
    style G fill:#e8f5e9
    style H fill:#fff9c4
    style I fill:#fff9c4
    style J1 fill:#ffe0b2
    style J2 fill:#ffe0b2
```

**Dependency explanation:**

- **Stage 1 (Variables/Providers)**: Core Terraform configuration and provider setup
- **Stage 2 (Data/Credentials)**: Queries golden image, creates Harvester cloud credential in Rancher
- **Stage 3 (Machine Configs)**: Defines node configuration for each pool (CP, general, compute, database)
- **Stage 4 (EFI Patches)**: Applies initial bootstrap patches to node configurations (registries, CA certs)
- **Stage 5 (RKE2 Cluster)**: Creates the actual cluster in Rancher; depends on machine configs and credentials
  - **Critical**: The cluster resource must set `cloud_credential_secret_name = rancher2_cloud_credential.harvester.id` at the cluster level (not just per-pool)
  - This tells Rancher which cloud credential to use for all machine pools
  - Without this, Rancher cannot provision VMs correctly and may create duplicate machine deployments
- **Stage 6 (Operators)**: Once cluster is running, deploys node-labeler and storage-autoscaler operators

---

## 3. Network Architecture

The cluster uses two physical networks on Harvester: one for cluster communication (eth0) and one dedicated for Cilium LoadBalancer announcement (eth1).

```mermaid
graph TB
    subgraph Networks["Harvester Networks"]
        VLAN1["VLAN1: Cluster Network<br/>(10.0.0.0/24)<br/>eth0 on all nodes"]
        VLAN5["VLAN5: Services Network<br/>(192.168.48.0/24)<br/>eth1 on workers only"]
    end

    subgraph ControlPlane["Control Plane (eth0 only)"]
        APIServer["kube-apiserver"]
        Scheduler["kube-scheduler"]
        ControlManager["kube-controller-manager"]
        etcd["etcd"]
    end

    subgraph Cilium["Cilium CNI<br/>(L2 Announcements)"]
        L2Pool["L2 IP Pool<br/>192.168.48.2-20"]
        L2Policy["L2 Announcement Policy<br/>interfaces: eth1<br/>nodeSelector: !control-plane"]
    end

    subgraph Workers["Worker Nodes (Dual NIC)"]
        WorkerEth0["eth0: Cluster mesh<br/>Flannel overlay<br/>Service mesh"]
        WorkerEth1["eth1: LoadBalancer VIPs<br/>Ingress traffic only"]
        PolicyRouting["Policy Routing<br/>table 200 for eth1<br/>ARP tuning"]
    end

    subgraph Ingress["Ingress Controller"]
        TraefikLB["Traefik<br/>Service=LoadBalancer<br/>IP: 192.168.48.2"]
        HTTP["HTTP: 80"]
        HTTPS["HTTPS: 443"]
    end

    VLAN1 --> ControlPlane
    VLAN1 --> WorkerEth0
    VLAN5 --> WorkerEth1
    ControlPlane -->|Provides API| APIServer
    WorkerEth0 -->|Cluster mesh| Workers
    WorkerEth1 -->|Service VIPs| Workers
    L2Pool -->|IP Range| L2Policy
    L2Policy -->|Announces| WorkerEth1
    PolicyRouting -->|Routes via eth1| WorkerEth1
    WorkerEth1 -->|Binds to| TraefikLB
    TraefikLB -->|Listen| HTTP
    TraefikLB -->|Listen| HTTPS

    style VLAN1 fill:#e3f2fd,color:#000
    style VLAN5 fill:#fce4ec,color:#000
    style ControlPlane fill:#c8e6c9,color:#000
    style Workers fill:#bbdefb,color:#000
    style Cilium fill:#fff9c4,color:#000
    style Ingress fill:#ffccbc,color:#000
```

**Network details:**

- **Control Plane (eth0 only)**
  - Single NIC simplifies networking for API servers and etcd
  - Cilium L2 policy explicitly excludes CP nodes
  - No ingress traffic received on CP

- **Workers (Dual NIC)**
  - **eth0 (cluster network, 10.0.0.0/24)**: Primary cluster communication, Kubernetes service mesh, CNI overlay
  - **eth1 (services network, 192.168.48.0/24)**: Dedicated to Cilium L2 LoadBalancer IP announcement

- **Policy Routing (Worker-only)**
  - NetworkManager dispatcher script activates when eth1 comes up
  - Adds routing table 200 ("ingress") with priority 100
  - Rule: `ip rule add from <eth1_ip> table ingress` ensures responses on services-network stay on eth1
  - Kernel ARP tuning (`arp_ignore=1, arp_announce=2`) prevents eth0 from answering ARP for eth1 addresses

- **Cilium L2 Announcement**
  - Pool: 192.168.48.2 – 192.168.48.20 (adjustable via `cilium_lb_pool_start/stop`)
  - Traefik LoadBalancer IP: 192.168.48.2
  - Policy matches all services, excludes CP nodes
  - Announces on `eth1` only

---

## 4. Node Pool Design

The cluster uses four specialized pools for different workload types. Each pool is independently autoscalable with dedicated node labels.

```mermaid
graph TB
    subgraph Pools["Machine Pools (rancher2_cluster_v2.rke2)"]
        CP["Pool 1: Control Plane<br/>---<br/>Quantity: Fixed (3)<br/>CPU: 8<br/>Memory: 32 GiB<br/>Disk: 80 GiB<br/>Roles: control-plane + etcd<br/>No workload placement"]

        General["Pool 2: General<br/>---<br/>Quantity: 4 (autoscaled)<br/>CPU: 4<br/>Memory: 8 GiB<br/>Disk: 60 GiB<br/>Min: 4 | Max: 10<br/>Label: workload-type=general<br/>Use: Default app deployments"]

        Compute["Pool 3: Compute<br/>---<br/>Quantity: 0 (scale-from-zero)<br/>CPU: 8<br/>Memory: 32 GiB<br/>Disk: 80 GiB<br/>Min: 0 | Max: 10<br/>Label: workload-type=compute<br/>Use: Heavy workloads"]

        Database["Pool 4: Database<br/>---<br/>Quantity: 4 (autoscaled)<br/>CPU: 4<br/>Memory: 16 GiB<br/>Disk: 80 GiB<br/>Min: 4 | Max: 10<br/>Label: workload-type=database<br/>Use: Stateful apps"]
    end

    subgraph Autoscaler["Cluster Autoscaler (Rancher)"]
        ScaleDown["Scale-Down Config<br/>---<br/>Unneeded time: 30m<br/>Delay after add: 15m<br/>Delay after delete: 30m<br/>Utilization threshold: 0.5"]

        ScaleZero["Scale-from-Zero<br/>(Compute Pool Only)<br/>---<br/>cpu: 8<br/>memory: 32Gi<br/>storage: 80Gi"]
    end

    Pools --> Autoscaler
    Autoscaler --> ScaleDown
    Autoscaler --> ScaleZero

    style CP fill:#c8e6c9,color:#000
    style General fill:#bbdefb,color:#000
    style Compute fill:#ffe0b2,color:#000
    style Database fill:#f8bbd0,color:#000
    style ScaleDown fill:#fff9c4,color:#000
    style ScaleZero fill:#fff9c4,color:#000
```

**Pool architecture notes:**

1. **Control Plane Pool**
   - Fixed quantity (no autoscaling); typically 3 for etcd quorum
   - Single NIC (eth0 only) to simplify network requirements
   - All CP components run without workload placement restrictions

2. **General Worker Pool**
   - Autoscaled (4–10 nodes, configurable)
   - Default destination for most Kubernetes workloads
   - Dual NIC for ingress traffic separation

3. **Compute Worker Pool**
   - **Scale-from-zero enabled** via annotations that tell autoscaler the capacity of a hypothetical new node
   - Starts at 0 nodes (no idle compute cost)
   - When a Pod with `workload-type=compute` nodeSelector cannot be scheduled, autoscaler knows a new node would fit and adds one
   - Useful for batch jobs, ML training, etc.

4. **Database Worker Pool**
   - Autoscaled (4–10 nodes)
   - Dedicated for stateful workloads (CNPG, Redis, etc.)
   - Same dual-NIC as general workers

**Node label application:**
- Workload-type labels applied at provisioning time via machine pool configuration
- kubelet receives labels via RKE2 machine config

---

## 5. Container Registry Architecture

All container image pulls flow through a tiered registry system designed for airgap resilience and rate-limit avoidance:

```mermaid
graph LR
    subgraph NodeContainerd["Node (containerd)"]
        MirrorConfig["Mirror Config<br/>(registries.yaml)"]
    end

    subgraph BootstrapPhase["Cluster Startup"]
        BootstrapRegistry["Bootstrap Registry<br/>(e.g., harbor.example.com)<br/>---<br/>Used only at cluster<br/>provisioning time"]
    end

    subgraph HarborPhase["After Cluster Ready"]
        Harbor["Harbor Proxy-Cache<br/>(harbor.example.com)<br/>---<br/>Full Harbor deployment<br/>with upstream mirrors"]
    end

    subgraph Upstreams["Upstream Registries"]
        Docker["docker.io"]
        Quay["quay.io"]
        GHCR["ghcr.io"]
        GCR["gcr.io"]
        K8sReg["registry.k8s.io"]
        Elastic["docker.elastic.co"]
        GitLab["registry.gitlab.com"]
        MariaDB["docker-registry3.mariadb.com"]
    end

    MirrorConfig -->|"containerd mirror config"| BootstrapRegistry
    BootstrapRegistry -->|"proxy GET"| Docker
    BootstrapRegistry -->|"proxy GET"| Quay
    BootstrapRegistry -->|"proxy GET"| GHCR
    BootstrapRegistry -->|"proxy GET"| GCR

    MirrorConfig -->|"updated after cluster ready"| Harbor
    Harbor -->|"proxy GET"| Docker
    Harbor -->|"proxy GET"| Quay
    Harbor -->|"proxy GET"| GHCR
    Harbor -->|"proxy GET"| GCR
    Harbor -->|"proxy GET"| K8sReg
    Harbor -->|"proxy GET"| Elastic
    Harbor -->|"proxy GET"| GitLab
    Harbor -->|"proxy GET"| MariaDB

    style MirrorConfig fill:#e3f2fd,color:#000
    style BootstrapRegistry fill:#fff3e0,color:#000
    style HarborPhase fill:#f3e5f5,color:#000
    style Harbor fill:#f3e5f5,color:#000
    style BootstrapPhase fill:#fff3e0,color:#000
```

**Registry flow details:**

1. **Node Container Runtime (containerd)**
   - Reads `registries.yaml` injected by Terraform via `rke_config.registries` block
   - Specifies mirrors and rewrite rules for each upstream registry

2. **Bootstrap Phase (Cluster Startup)**
   - Registry endpoint: `var.bootstrap_registry` (e.g., `harbor.example.com`)
   - Mirror config rewrites: e.g., `docker.io/library/alpine` → `bootstrap_registry/docker.io/library/alpine`
   - Small registry can pre-cache images needed for RKE2 startup (e.g., containerd, CNI plugins, system pods)
   - TLS trust: `bootstrap_registry_ca_pem` (defaults to `private_ca_pem` if not specified)

3. **Harbor Proxy-Cache Phase (After Cluster Ready)**
   - Registry config is configured to point to Harbor
   - Same mirror rewrites but now endpoint is `var.harbor_fqdn` (e.g., `harbor.example.com`)
   - Harbor configured with upstream projects (one per upstream registry)
   - Caching behavior: pull from upstream on first request, cache locally
   - Dramatically reduces bandwidth and upstream rate-limit pressure

4. **Upstream Registries**
   - Docker Hub, Quay, GHCR, GCR, K8s registry, Elastic, GitLab, MariaDB
   - Configurable via `harbor_registry_mirrors` variable (defaults to the 8 listed above)
   - Can be extended or modified based on organization needs

**Private CA Trust:**
- `private_ca_pem` provided at Terraform time
- Injected into all nodes via cloud-init (`write_files` → `/etc/pki/ca-trust/source/anchors/private-ca.pem`)
- Both bootstrap and Harbor registries use this CA for TLS validation

---

## 6. Cloud Provider Integration

The Harvester cloud provider enables native Kubernetes integration for LoadBalancer services, persistent volumes, and node lifecycle management:

```mermaid
graph TB
    subgraph KubeAPIServer["kube-apiserver"]
        CloudProvider["Cloud Provider Flag<br/>(--cloud-provider=harvester)"]
    end

    subgraph HarvesterCloudProvider["Harvester Cloud Provider<br/>(RKE2 system pod)"]
        Config["Cloud Config<br/>(kubeconfig to Harvester)"]
        LoadBalancerController["LoadBalancer Controller"]
        CSIDriver["CSI Driver"]
        NodeController["Node Controller"]
    end

    subgraph HarvesterCluster["Harvester Cluster<br/>(Infrastructure)"]
        HarvesterVMs["Virtual Machines"]
        HarvesterNetwork["Harvester Network<br/>(IPAM)"]
        HarvesterVolumePool["Harvester Storage Pool"]
    end

    subgraph Cilium["Cilium CNI"]
        L2["L2 Announcement<br/>(Cilium LB)"]
    end

    subgraph WorkerNodes["Worker Nodes"]
        Kubelet["kubelet"]
        CSIPlugin["CSI plugin"]
    end

    subgraph PersistentVolumes["Kubernetes Storage"]
        PVC["PersistentVolumeClaim"]
        StorageClass["StorageClass<br/>(harvester)"]
    end

    KubeAPIServer --> CloudProvider
    CloudProvider -->|"Kubeconfig with SA token"| HarvesterCloudProvider
    HarvesterCloudProvider --> Config
    Config -->|"Kubeconfig to Harvester"| HarvesterCluster

    HarvesterCloudProvider --> LoadBalancerController
    HarvesterCloudProvider --> CSIDriver
    HarvesterCloudProvider --> NodeController

    LoadBalancerController -->|"Watches Kubernetes"| Cilium
    Cilium -->|"L2 Announce Service VIP"| WorkerNodes

    CSIDriver -->|"createVolume<br/>attachVolume"| HarvesterVolumePool
    Kubelet -->|"mount/unmount"| CSIPlugin
    CSIPlugin -->|"iSCSI/NFS to"| HarvesterVolumePool
    PVC -->|"bound to"| StorageClass

    NodeController -->|"Watch VM lifecycle"| HarvesterVMs
    Kubelet -->|"Report status"| NodeController

    style CloudProvider fill:#e3f2fd,color:#000
    style LoadBalancerController fill:#fff3e0,color:#000
    style CSIDriver fill:#f3e5f5,color:#000
    style NodeController fill:#e8f5e9,color:#000
    style Cilium fill:#fce4ec,color:#000
```

**Cloud provider functionality:**

1. **LoadBalancer Controller**
   - Intercepts Kubernetes `Service type: LoadBalancer` requests
   - For Cilium L2 announcement: controller ensures VIP is allocated from pool, Cilium announces it
   - Creates no additional Harvester resources; Cilium L2 handles the announcement natively

2. **CSI Driver**
   - Enables `PersistentVolumeClaim` consumption from Harvester storage pools
   - Typical flow: Create PVC → CSI controller provisions volume on Harvester → CSI kubelet plugin mounts via iSCSI/NFS
   - StorageClass `provisioner: harvester.cattle.io` required in cluster

3. **Node Controller**
   - Monitors Harvester VM lifecycle (created, running, terminated)
   - Updates Kubernetes `Node` resource status accordingly
   - Handles node draining on VM termination (graceful shutdown)

4. **Authentication**
   - Uses `harvester_cloud_provider_kubeconfig_path` (separate from main Rancher integration)
   - ServiceAccount-based authentication
   - Kubeconfig injected into RKE2 system pod by Terraform

---

## 7. Cluster Autoscaler

Rancher's cluster autoscaler drives node pool sizing based on workload demand. The system supports both traditional autoscaling and scale-from-zero:

```mermaid
graph TB
    subgraph PodScheduling["Pod Scheduling"]
        Pod1["Pod with<br/>nodeSelector:<br/>workload-type: general"]
        Pod2["Pod with<br/>nodeSelector:<br/>workload-type: compute"]
    end

    subgraph SchedulingDecision["Scheduler Decision"]
        CanSchedule["Can schedule<br/>on existing nodes?"]
        NoCapacity["No capacity<br/>in pool"]
    end

    subgraph Autoscaler["Cluster Autoscaler<br/>(Rancher)"]
        ReadAnnotations["Read Pool Annotations<br/>---<br/>autoscaler-min-size<br/>autoscaler-max-size<br/>autoscaler-resource-cpu (compute only)<br/>autoscaler-resource-memory<br/>autoscaler-resource-storage"]

        ScaleDecision["Can scale up?<br/>---<br/>Current < Max?<br/>OR<br/>Scale-from-zero capacity?"]

        AddNode["Add Machine to Pool<br/>(via Rancher API)<br/>Triggers VM provisioning"]
    end

    subgraph ScaleDown["Scale-Down Logic<br/>(Periodic)"]
        FindUnneeded["Find underutilized nodes<br/>(CPU/mem < 0.5)"]
        CheckTiming["Check timing<br/>30m unneeded<br/>15m after add<br/>30m after delete"]
        RemoveNode["Drain + remove node"]
    end

    PodScheduling --> SchedulingDecision
    SchedulingDecision -->|Yes| Pod1
    SchedulingDecision -->|No| NoCapacity
    NoCapacity --> Autoscaler
    Autoscaler --> ReadAnnotations
    ReadAnnotations --> ScaleDecision
    ScaleDecision -->|Yes| AddNode

    Autoscaler -.->|Parallel| ScaleDown
    FindUnneeded -->|30m rule| CheckTiming
    CheckTiming -->|OK| RemoveNode

    Pod2 --> ReadAnnotations

    style CanSchedule fill:#fff3e0,color:#000
    style NoCapacity fill:#ffcdd2,color:#000
    style ScaleDecision fill:#fff9c4,color:#000
    style AddNode fill:#c8e6c9,color:#000
    style FindUnneeded fill:#ffe0b2,color:#000
    style RemoveNode fill:#ffcdd2,color:#000
```

**Autoscaler behavior:**

- **Scale-up**: When a pod is unschedulable due to insufficient capacity, autoscaler checks if it can add a new node to the affected pool
- **Scale-down**: Periodically scans for underutilized nodes; if a node is idle for 30 minutes with < 50% utilization, it's drained and removed
- **Scale-from-zero**: Compute pool starts at 0 nodes; annotations tell autoscaler the capacity of a hypothetical new node, allowing scale-up decisions even with 0 current nodes
- **Cooldowns**: After adding a node, no scale-down for 15 minutes; after removing, no scale-down for 30 minutes

---

## 8. EFI Firmware Patching

Initial node bootstrap requires EFI firmware patches to inject bootstrap registry credentials and CA certificates before cloud-init runs:

```mermaid
graph TD
    A["Golden Image<br/>(UEFI bootable)"] --> B["VM Boot"]
    B --> C["EFI Firmware<br/>(OVMF)"]
    C --> D["EFI Variables<br/>from Terraform"]
    D -->|"Injected via<br/>efi.tf"| E["KernelCmdLine<br/>rke2.io/custom-init"]
    E --> F["Cloud-init Runs"]
    F --> G["Bootstrap Registry Config<br/>/etc/rancher/rke2/registries.yaml"]
    G --> H["Private CA Cert<br/>/etc/pki/ca-trust/source/anchors/"]
    H --> I["containerd Starts<br/>with mirror config"]
    I --> J["RKE2 Binary Pulls<br/>from Bootstrap Registry"]
    J --> K["Cluster Join"]

    style A fill:#fff3e0,color:#000
    style B fill:#e3f2fd,color:#000
    style C fill:#fff3e0,color:#000
    style D fill:#fce4ec,color:#000
    style E fill:#fce4ec,color:#000
    style F fill:#e8f5e9,color:#000
    style G fill:#bbdefb,color:#000
    style H fill:#bbdefb,color:#000
    style I fill:#c8e6c9,color:#000
    style J fill:#ffe0b2,color:#000
    style K fill:#ffccbc,color:#000
```

**Why EFI patches are needed:**
- Cloud-init runs after boot, but containerd needs registry config before pulling RKE2 images
- EFI variables allow passing configuration that survives the bootloader → kernel transition
- Private CA must be available during first container pull (even from bootstrap registry)

**Implementation:**
- `efi.tf` resource: generates EFI patches for each node pool
- Patches injected into `machine_config.tf` via `efi_patch` block
- Terraform applies patches when creating machine configs

---

## 9. Operator Deployment

Two custom Kubernetes operators are optionally deployed after cluster creation:

### node-labeler (v0.2.0)

Watches Harvester VM annotations and syncs them to Kubernetes node labels. Enables workload affinity based on VM properties.

### storage-autoscaler (v0.2.0)

Monitors Harvester VM disk usage and automatically expands PersistentVolumes on nodes near capacity.

**Deployment flow:**
1. Operator images built from source (must exist in `operators/images/`)
2. Terraform runs `push-images.sh` via `null_resource.operator_image_push`
3. Images pushed to Harbor via `crane` CLI
4. Manifests rendered from `operators/templates/` via `templatefile()` function
5. Operators deployed via kubectl using RKE2 kubeconfig

**Operator images:**
- Image tarballs are NOT committed to git
- To deploy operators, build images from source in `operators/` directory
- Place tarballs in `operators/images/` before `terraform apply`
- If `deploy_operators = false`, operators are not deployed

---

## 10. Rancher API vs Harvester Kubeconfig — RBAC & Visibility Gap

A critical operational detail: Rancher's Steve API and direct Harvester kubeconfig provide **different visibility** into cluster resources due to RBAC role differences.

```mermaid
graph TB
    subgraph Rancher["Rancher Management Cluster<br/>(rancher.example.com)"]
        RancherAPI["Rancher Steve API<br/>/v1/provisioning.cattle.io.clusters<br/>/v1/rke-machine.cattle.io.harvestermachines<br/>/v1/cluster.x-k8s.io.machines"]
        RancherRBAC["RBAC: cluster-admin<br/>or Rancher user token"]
    end

    subgraph Harvester["Harvester K8s Cluster<br/>(kubeconfig-harvester.yaml)"]
        HarvesterAPI["Native K8s API<br/>/api/v1/namespaces<br/>/api/v1/persistentvolumeclaims<br/>custom.harvesterhci.io resources"]
        HarvesterRBAC["RBAC: service account<br/>with VM/disk permissions<br/>(narrower scope)"]
    end

    subgraph Resources["Cluster Resources"]
        HM["HarvesterMachine objects<br/>(Rancher management cluster)"]
        CAPI["CAPI Machine objects<br/>(Rancher management cluster)"]
        VM["Virtual Machine objects<br/>(Harvester infrastructure cluster)"]
        PVC["PersistentVolumeClaims<br/>(Harvester infrastructure cluster)"]
        DV["DataVolume objects<br/>(Harvester infrastructure cluster)"]
    end

    RancherAPI -->|visible| HM
    RancherAPI -->|visible| CAPI
    RancherAPI -->|NOT directly visible| VM
    RancherAPI -->|NOT directly visible| PVC
    HarvesterAPI -->|visible| VM
    HarvesterAPI -->|visible| PVC
    HarvesterAPI -->|visible| DV
    HarvesterAPI -->|NOT visible| HM
    HarvesterAPI -->|NOT visible| CAPI

    RancherRBAC -->|cluster-admin| Rancher
    HarvesterRBAC -->|limited SA| Harvester

    style Rancher fill:#4285f4,color:#fff
    style Harvester fill:#ff6b35,color:#fff
    style RancherAPI fill:#90caf9,color:#000
    style HarvesterAPI fill:#ffb74d,color:#000
    style HM fill:#ffccbc,color:#000
    style CAPI fill:#ffccbc,color:#000
    style VM fill:#ffe0b2,color:#000
    style PVC fill:#ffe0b2,color:#000
    style DV fill:#ffe0b2,color:#000
```

**Key visibility differences:**

1. **Rancher Steve API** (used by `terraform.sh destroy` cleanup)
   - Can see HarvesterMachine, CAPI Machine, provisioning cluster resources
   - **Cannot directly delete VMs** — only the Harvester kubeconfig can
   - Operates on Rancher management cluster; uses `cluster-admin` or higher privileges
   - Used by `post_destroy_cleanup()` to clear finalizers and metadata

2. **Harvester kubeconfig** (direct K8s API)
   - Can see/delete VMs, VMIs, PVCs, DataVolumes
   - **Cannot see HarvesterMachine or CAPI resources** — those live on Rancher
   - Uses ServiceAccount with limited VM/storage permissions
   - Used by `nuke-cluster.sh` to force-delete stuck VMs and orphaned disks

**Operational implication:**

When destroying a cluster, both must be used:
1. **Rancher API** clears finalizers on HarvesterMachine/CAPI objects
2. **Harvester API** force-deletes orphaned VMs and disks

If only one approach is used, resources will remain orphaned. This is why `destroy-cluster.sh` (which calls both via Terraform's cleanup logic) and `nuke-cluster.sh` (which handles both explicitly) both exist and may both be needed in failure scenarios.

---

## 11. Summary

This architecture delivers a production-ready RKE2 cluster on Harvester with:

- **Reliability**: Three-node CP, etcd quorum, pod disruption budgets
- **Scalability**: Autoscaling pools, scale-from-zero for compute workloads
- **Networking**: Cilium CNI with L2 LB, dual-NIC separation of cluster/ingress traffic
- **Air-gap**: Bootstrap registry + Harbor proxy-cache isolation from public internet
- **Observability**: Cluster autoscaler, node-labeler, storage-autoscaler custom operators
- **Security**: Private CA trust chain, node encryption, service account RBAC

All infrastructure is managed by Terraform, enabling repeatable, auditable cluster deployments.
