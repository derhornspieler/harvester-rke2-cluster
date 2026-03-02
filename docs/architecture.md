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

The system consists of five major components that work together to provision and manage the RKE2 cluster:

```mermaid
graph TB
    subgraph Rancher["Rancher Management Cluster (Local)"]
        RancherAPI["Rancher API Server<br/>(rancher.example.com)"]
        LocalK8s["Local K8s Cluster<br/>(cloud provider)"]
    end

    subgraph Harvester["Harvester Hypervisor"]
        HarvesterK8s["Harvester K8s Cluster<br/>(infrastructure)"]
        HarvesterVMs["Virtual Machines<br/>(RKE2 Cluster Nodes)"]
        GoldenImage["Golden Image<br/>(rke2-rocky9-golden)"]
        VMNetwork["VM Networks<br/>(eth0: vm-network, eth1: services)"]
    end

    subgraph RKE2["RKE2 Downstream Cluster"]
        ControlPlanes["Control Plane Nodes<br/>(3x CP+etcd)"]
        GeneralWorkers["General Workers<br/>(4-10 autoscale)"]
        ComputeWorkers["Compute Workers<br/>(0-10 scale-from-zero)"]
        DatabaseWorkers["Database Workers<br/>(4-10 autoscale)"]
        Cilium["Cilium CNI<br/>(L2 announcement)"]
        Traefik["Traefik Ingress<br/>(LB: 192.168.48.2)"]
    end

    subgraph Infrastructure["Supporting Infrastructure"]
        Harbor["Harbor Registry<br/>(Proxy-cache)"]
        DevVM["Dev VM<br/>(Proxy, NTP, DNS)"]
        Vault["Vault PKI<br/>(Cert Management)"]
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
    GeneralWorkers -->|Pulls from| Harbor
    ComputeWorkers -->|Pulls from| Harbor
    DatabaseWorkers -->|Pulls from| Harbor
    DevVM -->|Caches| Harbor
    Vault -->|Issues Certificates| Traefik
```

**Component Relationships:**

1. **Rancher Management Cluster** — The control point; provides API for Terraform and defines cloud credentials for Harvester
2. **Harvester Hypervisor** — Physical/virtualized infrastructure; hosts all RKE2 cluster VMs and the golden image
3. **RKE2 Cluster** — The downstream managed cluster with four node pools and Cilium + Traefik networking
4. **Infrastructure Services** — Harbor for container images, Dev VM for proxy caching, Vault for PKI

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

- **Stages 1-2**: Initialization (variables loaded, providers configured)
- **Stage 3**: Golden image lookup from Harvester (used by all machine configs)
- **Stage 4**: Cloud credential registration in Rancher (required for VM provisioning)
- **Stages 5a-5d**: Four machine configurations defined (CP, general, compute, database)
  - Each specifies disk (golden image), network, CPU/memory, cloud-init user data
  - Network info differs: CP has single NIC; workers have dual NIC (vm-network + services-network)
- **Stages 6a-6d**: EFI firmware patches applied via Rancher API
  - Patches HarvesterConfig CRDs to enable UEFI boot
  - Must complete before cluster creation (explicit dependency in cluster.tf)
- **Stage 7**: RKE2 cluster creation
  - Depends on all EFI patches and cloud credential
  - Provisions VMs via Rancher machine pool orchestration
  - Configures CNI (Cilium), ingress (Traefik), registries (Harbor), cloud provider (Harvester)
- **Stages 8-9**: Operator setup (kubeconfig retrieval, image push to Harbor)
  - Gated by `var.deploy_operators` flag
  - Image push requires Harbor credentials
- **Stages 10a-10b**: Operator deployments (node-labeler, storage-autoscaler)
  - Run in parallel after image push
  - Waits for nodes to be Ready before applying manifests

---

## 3. Network Architecture

The cluster uses a dual-network design with policy routing to separate management and service traffic:

```mermaid
graph TB
    subgraph Harvester["Harvester Infrastructure"]
        VLAN1["VLAN 1: VM Network<br/>(10.0.0.0/24)"]
        VLAN5["VLAN 5: Services Network<br/>(192.168.48.0/24)"]
    end

    subgraph ControlPlane["Control Plane Nodes<br/>(Single NIC: eth0)"]
        CP["eth0: vm-network<br/>(10.0.0.x/24)"]
    end

    subgraph Workers["Worker Nodes<br/>(Dual NIC)"]
        WorkerEth0["eth0: vm-network<br/>(10.0.0.x/24)<br/>Primary cluster traffic"]
        WorkerEth1["eth1: services-network<br/>(192.168.48.x/24)<br/>Ingress & external LB"]
    end

    subgraph Cilium["Cilium CNI"]
        L2Pool["L2 LoadBalancer IP Pool<br/>(192.168.48.2-20)"]
        L2Policy["L2 Announcement Policy<br/>(On eth1 only)"]
        KubeProxy["Kube-proxy disabled<br/>(eBPF native)"]
    end

    subgraph Traefik["Traefik Ingress"]
        TraefikLB["LoadBalancer Service<br/>(192.168.48.2)"]
        HTTP["HTTP: :80 → :443"]
        HTTPSPort["HTTPS: :443"]
    end

    subgraph PolicyRouting["Worker Policy Routing<br/>(eth1 up)"]
        ARPConfig["ARP Configuration<br/>(arp_ignore=1, arp_announce=2)"]
        RT200["Routing Table 200: ingress<br/>(priority 100)"]
        RuleEth1["ip rule: from eth1_IP → table ingress"]
    end

    subgraph Registry["Container Registry Flow"]
        Bootstrap["Bootstrap Registry<br/>(Initially in cloud-init)"]
        Containerd["containerd mirrors config<br/>(8 upstream registries)"]
        Harbor["Harbor Proxy-Cache<br/>(Docker Hub, quay.io, ghcr.io, etc.)"]
        Upstreams["Upstream Registries"]
    end

    VLAN1 --> CP
    VLAN1 --> WorkerEth0
    VLAN5 --> WorkerEth1
    CP -->|Provides API| ControlPlane
    WorkerEth0 -->|Cluster mesh| Workers
    WorkerEth1 -->|Service IPs| Workers
    L2Pool -->|IP Range| L2Policy
    L2Policy -->|Announces VIPs| WorkerEth1
    L2Policy -->|Skips CP nodes| KubeProxy
    KubeProxy -->|Runs on| Workers
    WorkerEth1 -->|Binds to| TraefikLB
    TraefikLB -->|Listen| HTTPSPort
    HTTP -->|Redirects| HTTPSPort
    ARPConfig -->|Silences on| WorkerEth1
    ARPConfig -->|Applied via| RT200
    RT200 -->|Configured by| RuleEth1
    RuleEth1 -->|Dispatcher script| PolicyRouting
    Bootstrap -->|Phase 0-3| Containerd
    Containerd -->|Rewrites paths| Harbor
    Harbor -->|Proxies| Upstreams

    style VLAN1 fill:#e3f2fd
    style VLAN5 fill:#fce4ec
    style CP fill:#c8e6c9
    style WorkerEth0 fill:#c8e6c9
    style WorkerEth1 fill:#ffccbc
    style L2Pool fill:#fff9c4
    style TraefikLB fill:#f8bbd0
```

**Network details:**

- **Control Plane (eth0 only)**
  - Single NIC simplifies networking for API servers and etcd
  - Cilium L2 policy explicitly excludes CP nodes (matchExpressions excludes control-plane role)
  - CP handles kubeconfig requests and API proxy via eth0

- **Workers (Dual NIC)**
  - **eth0 (vm-network, 10.0.0.0/24)**: Primary cluster communication, Kubernetes service mesh, CNI overlay
  - **eth1 (services-network, 192.168.48.0/24)**: Dedicated to Cilium L2 LoadBalancer IP announcement

- **Policy Routing (Worker-only)**
  - NetworkManager dispatcher script (`10-ingress-routing`) activates when eth1 comes up
  - Adds routing table 200 ("ingress") with priority 100
  - Rule: `ip rule add from <eth1_ip> table ingress` ensures responses on services-network stay on eth1 (not asymmetric routing)
  - Kernel ARP tuning (`arp_ignore=1, arp_announce=2`) prevents eth0 from answering ARP for eth1 addresses

- **Cilium L2 Announcement**
  - Pool: 192.168.48.2 – 192.168.48.20 (adjustable via `cilium_lb_pool_start/stop`)
  - Traefik LoadBalancer IP: 192.168.48.2 (via `traefik_lb_ip` var)
  - Policy matches all services (`serviceSelector: matchLabels: {}`), excludes CP nodes
  - Announces on `eth1` only (`interfaces: ["^eth1$"]`)

- **Container Registry Flow**
  - **Phase 0-3 (Bootstrap)**: Pulls via bootstrap registry (defined in machine_config.tf registries block)
  - **Phase 4+**: `configure_rancher_registries()` patches the cluster to use Harbor proxy-cache
  - **Mirror config**: 8 upstream registries (docker.io, quay.io, ghcr.io, gcr.io, registry.k8s.io, docker.elastic.co, registry.gitlab.com, docker-registry3.mariadb.com) → containerd → Harbor with path rewrites
  - **Harbor TLS**: Private CA certificate in cloud-init enables HTTPS to Harbor

---

## 4. Node Pool Design

The cluster uses four specialized pools for different workload types. Each pool is independently autoscalable with dedicated node labels.

```mermaid
graph TB
    subgraph Pools["Machine Pools (rancher2_cluster_v2.rke2)"]
        CP["Pool 1: Control Plane<br/>---<br/>Quantity: Fixed (default 3)<br/>CPU: 8 (configurable)<br/>Memory: 32 GiB<br/>Disk: 80 GiB<br/>Network: Single NIC (eth0)<br/>Roles: control-plane + etcd<br/>No worker role"]

        General["Pool 2: General<br/>---<br/>Quantity: 4 (initial, autoscaled)<br/>CPU: 4<br/>Memory: 8 GiB<br/>Disk: 60 GiB<br/>Network: Dual NIC (eth0 + eth1)<br/>Min: 4 | Max: 10<br/>Label: workload-type=general<br/>Use: Default app deployments"]

        Compute["Pool 3: Compute<br/>---<br/>Quantity: 0 (initial, scale-from-zero)<br/>CPU: 8<br/>Memory: 32 GiB<br/>Disk: 80 GiB<br/>Network: Dual NIC<br/>Min: 0 | Max: 10<br/>Label: workload-type=compute<br/>Scale-from-zero annotations<br/>Use: Heavy workloads (jobs, ML)"]

        Database["Pool 4: Database<br/>---<br/>Quantity: 4 (initial, autoscaled)<br/>CPU: 4<br/>Memory: 16 GiB<br/>Disk: 80 GiB<br/>Network: Dual NIC<br/>Min: 4 | Max: 10<br/>Label: workload-type=database<br/>Use: Stateful apps (CNPG, etc.)"]
    end

    subgraph Autoscaler["Cluster Autoscaler (Rancher)"]
        ScaleDown["Scale-Down Config<br/>---<br/>Unneeded time: 30m<br/>Delay after add: 15m<br/>Delay after delete: 30m<br/>Utilization threshold: 0.5"]

        Annotations["Pool Annotations"]

        ScaleZero["Scale-from-Zero<br/>(Compute Pool Only)<br/>---<br/>cpu: 8<br/>memory: 32Gi<br/>storage: 80Gi<br/>Tells autoscaler:<br/>'new compute node<br/>would have this capacity'"]
    end

    subgraph Labels["Node Labels Applied"]
        CPLabels["node-role.kubernetes.io/control-plane<br/>(via label_unlabeled_nodes<br/>in deploy-cluster.sh,<br/>NOT kubelet --node-labels)"]

        PoolLabels["workload-type=general<br/>workload-type=compute<br/>workload-type=database<br/>(via machine_selector_config<br/>in Terraform)"]
    end

    Pools --> Autoscaler
    Pools --> Labels
    Autoscaler --> ScaleDown
    Autoscaler --> Annotations
    Autoscaler --> ScaleZero

    style CP fill:#c8e6c9
    style General fill:#bbdefb
    style Compute fill:#ffe0b2
    style Database fill:#f8bbd0
    style ScaleDown fill:#fff9c4
    style ScaleZero fill:#fff9c4
    style CPLabels fill:#e1bee7
    style PoolLabels fill:#e1bee7
```

**Pool architecture notes:**

1. **Control Plane Pool**
   - Fixed quantity (no autoscaling); typically 3 for etcd quorum
   - Single NIC to simplify network requirements
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
- Control-plane labels applied by `label_unlabeled_nodes()` in deploy-cluster.sh (Phase 3), not at kubelet launch
  - Reason: NodeRestriction admission plugin prevents kubelet from setting `node-role.kubernetes.io/*` labels
- Workload-type labels applied at provisioning time via `machine_selector_config` in Terraform
  - kubelet receives `--node-labels=workload-type=general` etc. via RKE2 machine config

---

## 5. Container Registry Architecture

All container image pulls flow through a tiered registry system designed for airgap resilience and rate-limit avoidance:

```mermaid
graph LR
    subgraph NodeContainerd["Node (containerd)"]
        MirrorConfig["Mirror Config<br/>(registries.yaml)"]
    end

    subgraph BootstrapPhase["Phases 0–3<br/>(Bootstrap)"]
        BootstrapRegistry["Bootstrap Registry<br/>(e.g., 172.16.3.200:5000)<br/>---<br/>May be local Docker<br/>or small registry pod<br/>Used only at cluster<br/>provisioning time"]
    end

    subgraph HarborPhase["Phase 4+<br/>(Harbor Mirrors)"]
        Harbor["Harbor Proxy-Cache<br/>(harbor.aegisgroup.ch)<br/>---<br/>Full Harbor deployment<br/>with 8 upstream mirrors<br/>configured"]
    end

    subgraph Upstreams["Upstream Registries"]
        Docker["docker.io<br/>(Docker Hub)"]
        Quay["quay.io"]
        GHCR["ghcr.io"]
        GCR["gcr.io"]
        K8sReg["registry.k8s.io"]
        Elastic["docker.elastic.co"]
        GitLab["registry.gitlab.com"]
        MariaDB["docker-registry3.<br/>mariadb.com"]
    end

    MirrorConfig -->|"registries.yaml<br/>[docker.io]<br/>endpoints: bootstrap"| BootstrapRegistry
    BootstrapRegistry -->|"rewrites path<br/>docker.io/library/alpine<br/>→ alpine"| Docker

    MirrorConfig -->|"patched in Phase 4<br/>registries.yaml<br/>[docker.io]<br/>endpoints: harbor"| Harbor

    Harbor -->|"proxy GET<br/>docker.io/library/alpine<br/>→ caches locally"| Docker
    Harbor -->|"proxy GET"| Quay
    Harbor -->|"proxy GET"| GHCR
    Harbor -->|"proxy GET"| GCR
    Harbor -->|"proxy GET"| K8sReg
    Harbor -->|"proxy GET"| Elastic
    Harbor -->|"proxy GET"| GitLab
    Harbor -->|"proxy GET"| MariaDB

    style MirrorConfig fill:#e3f2fd
    style BootstrapRegistry fill:#fff3e0
    style HarborPhase fill:#f3e5f5
    style Harbor fill:#f3e5f5
    style BootstrapPhase fill:#fff3e0
```

**Registry flow details:**

1. **Node Container Runtime (containerd)**
   - Reads `registries.yaml` injected by Terraform via `rke_config.registries` block
   - Specifies mirrors and rewrite rules for each upstream registry

2. **Bootstrap Phase (Phases 0–3)**
   - Registry endpoint: `var.bootstrap_registry` (e.g., `172.16.3.200:5000`)
   - Mirror config rewrites: e.g., `docker.io/library/alpine` → `bootstrap_registry/docker.io/library/alpine`
   - Small registry can pre-cache images needed for RKE2 startup (e.g., containerd, CNI plugins, system pods)
   - TLS trust: `bootstrap_registry_ca_pem` (defaults to `private_ca_pem` if not specified)

3. **Harbor Proxy-Cache Phase (Phase 4+)**
   - `configure_rancher_registries()` patches `rke_config.registries` to point to Harbor
   - Same mirror rewrites but now endpoint is `var.harbor_fqdn` (e.g., `harbor.aegisgroup.ch`)
   - Harbor configured with 8 upstream projects (one per upstream registry)
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
- No separate `bootstrap_registry_ca_pem` defaults to the same CA chain

---

## 6. Cloud Provider Integration

The Harvester cloud provider enables native Kubernetes integration for LoadBalancer services, persistent volumes, and node lifecycle management:

```mermaid
graph TB
    subgraph KubeAPIServer["kube-apiserver"]
        CloudProvider["Cloud Provider Flag<br/>(--cloud-provider=harvester)"]
    end

    subgraph HarvesterCloudProvider["Harvester Cloud Provider<br/>(RKE2 system pod)"]
        Config["Cloud Config<br/>(harvester_cloud_provider_kubeconfig_path)"]
        LoadBalancerController["LoadBalancer Controller"]
        CSIDriver["CSI Driver"]
        NodeController["Node Controller"]
    end

    subgraph HarvesterCluster["Harvester Cluster<br/>(Infrastructure)"]
        HarvesterVMs["Virtual Machines"]
        HarvesterNetwork["Harvester Network<br/>(IPAM)"]
        HarvesterVolumePool["Harvester Storage Pool<br/>(SAN/Ceph)"]
    end

    subgraph Cilium["Cilium CNI"]
        L2["L2 Announcement<br/>(Cilium LB)"]
        BGP["BGP Control Plane<br/>(Optional)"]
    end

    subgraph WorkerNodes["Worker Nodes"]
        Kubelet["kubelet"]
        CiliumAgent["Cilium agent"]
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

    LoadBalancerController -->|"Creates LoadBalancer svc<br/>Watches Kubernetes"| Cilium
    Cilium -->|"L2 Announce<br/>Service VIP"| WorkerNodes
    L2 -->|"ARP/NDP"| HarvesterNetwork

    CSIDriver -->|"createVolume<br/>attachVolume"| HarvesterVolumePool
    Kubelet -->|"mount/unmount"| CSIPlugin
    CSIPlugin -->|"iSCSI/NFS to"| HarvesterVolumePool
    PVC -->|"bound to"| StorageClass

    NodeController -->|"Watch VM lifecycle"| HarvesterVMs
    Kubelet -->|"Report status"| NodeController

    style CloudProvider fill:#e3f2fd
    style LoadBalancerController fill:#fff3e0
    style CSIDriver fill:#f3e5f5
    style NodeController fill:#e8f5e9
    style Cilium fill:#fce4ec
```

**Cloud provider functionality:**

1. **LoadBalancer Controller**
   - Intercepts Kubernetes `Service type: LoadBalancer` requests
   - For Cilium L2 announcement (L2 pool mode): controller ensures VIP is allocated from pool, Cilium announces it
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
   - ServiceAccount-based authentication (not user token)
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

    subgraph MachinePool["Machine Pool State<br/>(rancher2_cluster_v2.rke2)"]
        QtyAnnotation["quantity: 4 (initial)"]
        MinAnnotation["autoscaler-min-size: 4"]
        MaxAnnotation["autoscaler-max-size: 10"]
        Labels["labels: workload-type=general"]
    end

    subgraph BootstrapRegistry2["Scale-from-Zero<br/>(Compute Pool)"]
        ResourceAnnotations["autoscaler-resource-cpu: 8<br/>autoscaler-resource-memory: 32Gi<br/>autoscaler-resource-storage: 80Gi"]
        Rationale["Autoscaler uses these to simulate:<br/>'If I add 1 new compute node,<br/>it would have 8 CPU, 32 Gi RAM, 80 Gi disk'<br/>---<br/>Allows scheduling of large pods<br/>that exceed current pool capacity"]
    end

    PodScheduling --> SchedulingDecision
    SchedulingDecision -->|Yes| Pod1
    SchedulingDecision -->|No| NoCapacity
    NoCapacity --> Autoscaler
    Autoscaler --> ReadAnnotations
    ReadAnnotations --> ScaleDecision
    ScaleDecision -->|Yes| AddNode
    AddNode -->|Provisions VM| MachinePool

    MachinePool --> QtyAnnotation
    MachinePool --> MinAnnotation
    MachinePool --> MaxAnnotation
    MachinePool --> Labels

    Autoscaler -.->|Parallel| ScaleDown
    FindUnneeded -->|30m rule| CheckTiming
    CheckTiming -->|OK| RemoveNode

    Pod2 --> BootstrapRegistry2
    BootstrapRegistry2 --> ResourceAnnotations
    ResourceAnnotations --> Rationale

    style CanSchedule fill:#fff3e0
    style NoCapacity fill:#ffcdd2
    style ScaleDecision fill:#fff9c4
    style AddNode fill:#c8e6c9
    style FindUnneeded fill:#ffe0b2
    style RemoveNode fill:#ffcdd2
```

**Autoscaler configuration (via cluster annotations):**

| Annotation | Default | Purpose |
|-----------|---------|---------|
| `cluster.provisioning.cattle.io/autoscaler-scale-down-unneeded-time` | `30m0s` | How long a node must be underutilized before removal |
| `cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-add` | `15m0s` | Cooldown after adding a node before scale-down considered |
| `cluster.provisioning.cattle.io/autoscaler-scale-down-delay-after-delete` | `30m0s` | Cooldown after removing a node before next removal |
| `cluster.provisioning.cattle.io/autoscaler-scale-down-utilization-threshold` | `0.5` | CPU/mem threshold below which node is unneeded (0.0–1.0) |

**Per-pool annotations (in machine_pools block):**

```hcl
# General & Database pools: Traditional autoscaling
annotations = {
  "cluster.provisioning.cattle.io/autoscaler-min-size" = "4"
  "cluster.provisioning.cattle.io/autoscaler-max-size" = "10"
}

# Compute pool ONLY: Scale-from-zero
annotations = {
  "cluster.provisioning.cattle.io/autoscaler-min-size" = "0"
  "cluster.provisioning.cattle.io/autoscaler-max-size" = "10"
  "cluster.provisioning.cattle.io/autoscaler-resource-cpu"     = "8"
  "cluster.provisioning.cattle.io/autoscaler-resource-memory"  = "32Gi"
  "cluster.provisioning.cattle.io/autoscaler-resource-storage" = "80Gi"
}
```

**Scale-from-zero behavior:**
1. Pod with `nodeSelector: workload-type: compute` cannot schedule
2. Autoscaler checks compute pool: current = 0, min = 0, max = 10
3. Autoscaler simulates: "If I add one node with 8 CPU, 32 Gi RAM, 80 Gi disk, can pod fit?"
4. If yes: scales up from 0 → 1 (provisions new VM)
5. Pod schedules; workload runs
6. After scale-down-unneeded-time (30m) with low utilization: node is drained and removed back to 0

---

## 8. TLS/CA Trust Chain

The cluster uses a private certificate authority for internal service TLS and secure registry access:

```mermaid
graph TB
    subgraph CA["Private CA Infrastructure<br/>(Outside this repo)"]
        RootCA["Root CA<br/>(30yr, offline)<br/>---<br/>aegisgroup.ch"]

        VaultIntermediate["Vault Intermediate CA<br/>(10yr)"]
        RKE2Intermediate["RKE2 Intermediate CA<br/>(5yr)<br/>--- (May be delegated)"]
    end

    subgraph TerraformInput["Terraform Input<br/>(terraform.tfvars)"]
        PrivateCA["private_ca_pem<br/>---<br/>Complete CA chain:<br/>Root + Intermediates<br/>(PEM format)"]
    end

    subgraph CloudInit["Cloud-Init on Nodes"]
        CAFile["/etc/pki/ca-trust/source/anchors/private-ca.pem"]
        UpdateTrust["update-ca-trust<br/>(rebuilds /etc/pki/ca-trust/extracted)"]
    end

    subgraph Containerd["containerd Configuration"]
        RegistryConfig["registries.yaml<br/>[var.harbor_fqdn]<br/>ca_bundle: private_ca_pem"]
        BootstrapConfig["registries.yaml<br/>[var.bootstrap_registry]<br/>ca_bundle: bootstrap_registry_ca_pem<br/>(defaults to private_ca_pem)"]
    end

    subgraph Traefik["Traefik Ingress"]
        TraefikVault["Vault CA Init Container<br/>(Phase 6+)<br/>---<br/>Fetches vault-root-ca<br/>from kube-system ConfigMap"]
        CombineCA["CA Combining<br/>---<br/>Merges system CA bundle<br/>+ Vault CA<br/>→ /combined-ca/ca-certificates.crt"]
        TraefikUse["Traefik Process<br/>---<br/>SSL_CERT_FILE=/combined-ca/ca-certificates.crt<br/>Enables upstream HTTPS"]
    end

    subgraph Services["Services Using CA"]
        Harbor["Harbor Registry<br/>(HTTPS with private cert)"]
        Vault["Vault Service<br/>(HTTPS with Vault intermediate)"]
        ExternalAPIs["External APIs<br/>(If signed by private CA)"]
    end

    CA --> TerraformInput
    TerraformInput --> PrivateCA
    PrivateCA -->|"inject via cloud-init"| CloudInit
    CloudInit --> CAFile
    CAFile --> UpdateTrust

    PrivateCA -->|"inject into registries block"| Containerd
    Containerd --> RegistryConfig
    Containerd --> BootstrapConfig

    CAFile -->|"System CA bundle trusts private CA"| Traefik
    UpdateTrust -->|"After trust rebuild"| Traefik
    Traefik --> TraefikVault
    TraefikVault -->|"Fetches from kube-system"| Traefik
    TraefikVault --> CombineCA
    CombineCA --> TraefikUse

    RegistryConfig -->|"TLS to"| Harbor
    BootstrapConfig -->|"TLS to"| Harbor
    CAFile -->|"TLS to"| Vault
    TraefikUse -->|"Upstream TLS"| ExternalAPIs

    style CA fill:#ffe0b2
    style PrivateCA fill:#fff9c4
    style CAFile fill:#e8f5e9
    style UpdateTrust fill:#c8e6c9
    style RegistryConfig fill:#f3e5f5
    style TraefikVault fill:#fff3e0
    style CombineCA fill:#fff3e0
```

**TLS trust flow:**

1. **Input: terraform.tfvars**
   - `private_ca_pem`: Complete PEM-encoded certificate chain (root + all intermediates)
   - Validated by `regex("-----BEGIN CERTIFICATE-----[\\s\\S]+-----END CERTIFICATE-----")`
   - May be same for all services or split per service (e.g., `bootstrap_registry_ca_pem` optional)

2. **Cloud-Init Injection**
   - All nodes: write `private_ca_pem` to `/etc/pki/ca-trust/source/anchors/private-ca.pem`
   - Run `update-ca-trust` to rebuild system CA bundle (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`)
   - Every application (containerd, curl, openssl, etc.) automatically trusts the CA

3. **Containerd Registry Configuration**
   - Harbor config: `ca_bundle: var.private_ca_pem` in registries block
   - Bootstrap registry config: `ca_bundle: coalesce(var.bootstrap_registry_ca_pem, var.private_ca_pem)`
   - Containerd uses these certs for HTTPS validation on pull requests

4. **Traefik Ingress (Phase 6+)**
   - Placeholder ConfigMap created at cluster boot: `vault-root-ca` in kube-system (empty initially)
   - Phase 6 post-deploy: Vault PKI CA populated into ConfigMap
   - Init container: combines system CA bundle + Vault CA → `/combined-ca/ca-certificates.crt`
   - Traefik env var: `SSL_CERT_FILE=/combined-ca/ca-certificates.crt`
   - Enables upstream HTTPS connections to Vault, Harbor, etc.

**Security implications:**
- Private CA is **sensitive** and must be protected
- Stored in `terraform.tfvars` (gitignored)
- Injected to every node's CA trust store (no secrets)
- Traefik ConfigMap update (Phase 6) requires manual Vault unsealing or automation

---

## 9. EFI Firmware Patching

Harvester virtual machines require UEFI (EFI) firmware for proper boot support. The Terraform provider doesn't directly expose this flag, so it must be patched via the Kubernetes API:

```mermaid
graph TD
    A["rancher2_machine_config_v2<br/>.controlplane / .general / .compute / .database"]
    B["Terraform creates<br/>HarvesterConfig CRD<br/>in fleet-default namespace<br/>---<br/>enableEfi NOT set<br/>(defaults to false/BIOS)"]
    C["null_resource.efi_*<br/>(local-exec provisioner)"]
    D["curl -X PATCH<br/>→ Rancher API<br/>/apis/rke-machine-config.cattle.io/v1/...<br/>-d '{enableEfi:true}'"]
    E["Rancher API<br/>applies PATCH<br/>to HarvesterConfig CRD"]
    F["Harvester reads<br/>enableEfi=true<br/>when provisioning VM"]
    G["VM boots with<br/>OVMF (UEFI)<br/>instead of BIOS"]
    H["rancher2_cluster_v2.rke2<br/>depends_on = [efi_*...]"]
    I["Cluster creation<br/>waits for all<br/>EFI patches to complete"]

    A --> B
    B --> C
    C --> D
    D --> E
    E --> F
    F --> G
    H --> I
    I -.->|"All pools ready"| A

    style A fill:#fff3e0
    style B fill:#ffcdd2
    style C fill:#fff9c4
    style D fill:#c8e6c9
    style E fill:#e3f2fd
    style F fill:#f3e5f5
    style G fill:#e8f5e9
```

**Why EFI patching is necessary:**

- **Provider limitation**: The Rancher Terraform provider's `harvester_config` block doesn't expose the `enableEfi` field
- **CRD structure**: HarvesterConfig CRDs live in `fleet-default` namespace as `rke-machine-config.cattle.io/v1` resources
- **Field name**: camelCase `enableEfi` (not `enableEFI`)
- **Patching approach**: Use Rancher API directly (PATCH, not PUT) to avoid overwriting the machine config

**Patch flow (in efi.tf):**

```hcl
resource "null_resource" "efi_controlplane" {
  triggers = {
    name = rancher2_machine_config_v2.controlplane.name  # e.g., "cluster-cp-abc123"
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -X PATCH \
        -H "Authorization: Bearer ${var.rancher_token}" \
        -H "Content-Type: application/merge-patch+json" \
        "${var.rancher_url}/apis/rke-machine-config.cattle.io/v1/namespaces/fleet-default/harvesterconfigs/${rancher2_machine_config_v2.controlplane.name}" \
        -d '{"enableEfi":true}'
    EOT
  }
}
```

**Dependency in cluster.tf:**

```hcl
resource "rancher2_cluster_v2" "rke2" {
  # ... cluster config ...

  depends_on = [
    null_resource.efi_controlplane,
    null_resource.efi_general,
    null_resource.efi_compute,
    null_resource.efi_database,
  ]
}
```

This ensures all four EFI patches complete before Rancher attempts to provision VMs.

---

## 10. Decision Record: OIDC Deferred to Post-Deploy (Phase 6)

OIDC (OpenID Connect) authentication for the kube-apiserver is intentionally NOT configured at cluster creation time. This decision prioritizes cluster availability and simplifies the bootstrap sequence.

```mermaid
graph TB
    subgraph ClusterCreate["Cluster Creation (Phase 1-2, Terraform)"]
        TFVars["terraform.tfvars<br/>---<br/>No OIDC variables<br/>No --oidc-* flags"]

        GlobalConfig["machine_global_config<br/>---<br/>cni: cilium<br/>disable-kube-proxy: true<br/>ingress-controller: traefik<br/>---<br/>NO kube-apiserver --oidc-* args"]

        KubeAPI["kube-apiserver launches<br/>---<br/>No OIDC auth<br/>Uses basic auth / cert auth<br/>during bootstrap"]
    end

    subgraph BootstrapReasons["Why OIDC Not at Cluster Creation"]
        Chicken["Chicken-and-egg:<br/>---<br/>OIDC requires external<br/>identity provider<br/>(Keycloak)"]

        Keycloak["Keycloak deployed in Phase 6<br/>(post-cluster-up)<br/>---<br/>Can't reference<br/>before cluster running"]

        RaceCondition["Race condition:<br/>---<br/>kube-apiserver starts<br/>before Keycloak realm exists<br/>→ Auth loops/delays"]
    end

    subgraph PostDeploy["Post-Deploy (Phase 6)"]
        DeployKeycloak["Deploy Keycloak<br/>+ OIDC realm + clients"]

        PatchAPIServer["Patch kube-apiserver<br/>config via Rancher<br/>---<br/>Add --oidc-issuer-url<br/>--oidc-client-id<br/>--oidc-username-claim<br/>--oidc-groups-claim<br/>--oidc-ca-file"]

        APIServerRestarts["kube-apiserver restarts<br/>with OIDC enabled<br/>---<br/>Gracefully drains requests<br/>Reconnects with OIDC auth"]
    end

    subgraph Result["End State"]
        OIDCEnabled["kube-apiserver<br/>enforces OIDC auth<br/>---<br/>Users must authenticate<br/>via Keycloak<br/>before any kubectl access"]
    end

    ClusterCreate --> GlobalConfig
    GlobalConfig --> KubeAPI
    KubeAPI -->|"Cluster UP,<br/>NO OIDC yet"| PostDeploy

    BootstrapReasons --> Chicken
    BootstrapReasons --> Keycloak
    BootstrapReasons --> RaceCondition

    Chicken -.->|"Justifies deferral"| PostDeploy

    PostDeploy --> DeployKeycloak
    PostDeploy --> PatchAPIServer
    PatchAPIServer --> APIServerRestarts
    APIServerRestarts --> OIDCEnabled

    style TFVars fill:#fff3e0
    style GlobalConfig fill:#fff9c4
    style KubeAPI fill:#c8e6c9
    style Chicken fill:#ffcdd2
    style Keycloak fill:#ffcdd2
    style RaceCondition fill:#ffcdd2
    style DeployKeycloak fill:#e8f5e9
    style PatchAPIServer fill:#fff3e0
    style OIDCEnabled fill:#e3f2fd
```

**Decision rationale:**

| Aspect | Decision | Reason |
|--------|----------|--------|
| **OIDC at cluster creation?** | No | Keycloak doesn't exist yet; would cause auth failures |
| **When enabled?** | Phase 6 (post-cluster-up) | After Keycloak deployed and realm configured |
| **How applied?** | Rancher cluster config patch | Not at terraform time; allows rollback if needed |
| **Auth during bootstrap?** | Basic/cert auth via kubeconfig | Terraform and early deployments use direct certs |
| **User experience** | Transparent; kubeconfig switch at Phase 6 | Users switch credentials after cluster ready |

**Benefits:**
1. **Cluster reliability**: No auth delays or loops during bootstrap
2. **Decoupled deployment**: OIDC setup independent of cluster infrastructure
3. **Simpler troubleshooting**: Early phase issues not entangled with identity system
4. **Reversibility**: OIDC can be disabled if Keycloak fails

**Related:**
- Identity Portal integration: Phase 6 post-deploy (same script that configures OIDC)
- OIDC client creation: Phase 5 (bootstrap-platform.sh B4 tier) in the main project
- Token refresh: Handled by oauth2-proxy (separate from kube-apiserver OIDC)

---

## 11. Known Constraints & Warnings

### Expected During Deployment

**ImagePullBackOff on Operators (Phases 0–3)**
- **Symptom**: Custom operators (node-labeler, storage-autoscaler) ImagePullBackOff until Phase 4
- **Cause**: Bootstrap registry not yet configured on cluster (only exists at cluster creation time)
- **When resolves**: Phase 4 when Harbor comes online and registries are patched
- **Action**: Expected; no intervention needed

**identity-portal-backend CrashLoopBackOff (Phases 0–5)**
- **Symptom**: identity-portal-backend pods crash
- **Cause**: Keycloak realm doesn't exist until Phase 6
- **When resolves**: Phase 6 when Keycloak realm is created
- **Action**: Expected; recover in Phase 6

**oauth2-proxy 500s (Phases 0–5)**
- **Symptom**: oauth2-proxy returns HTTP 500
- **Cause**: OIDC provider (Keycloak) not yet configured
- **When resolves**: Phase 6 when OIDC is enabled
- **Action**: Expected; users cannot authenticate until Phase 6

**Cilium LB pool initialization**
- **Symptom**: Traefik LoadBalancer unscheduled if traefik_lb_ip outside hardcoded range
- **Default range**: 192.168.48.2–192.168.48.20 (from cloud-init cilium-lb-ippool.yaml)
- **Fix**: If needed, patch `CiliumLoadBalancerIPPool` ingress-pool after cluster is running
  ```bash
  kubectl patch ciliumloadbalancerippool ingress-pool -p '{"spec":{"blocks":[{"start":"192.168.48.2","stop":"192.168.48.50"}]}}'
  ```

### Permanent Constraints

**No direct pulls from Docker Hub, GHCR, quay.io**
- Always via Harbor proxy-cache (or bootstrap registry in Phases 0–3)
- Ensures registry control and rate-limit management

**Private CA mandatory**
- `private_ca_pem` is required (validation fails otherwise)
- Must contain complete chain (root + intermediates)
- Injected to all nodes and containerd config

**Golden image required**
- No vanilla Rocky 9 download path
- `golden_image_name` must exist on Harvester before terraform apply
- Validation ensures non-empty string

**OIDC not at cluster creation**
- Kube-apiserver OIDC args added in Phase 6 post-deploy
- No OIDC flags in Terraform (cluster-wide auth unavailable until then)
- Justification: dependency on Keycloak which doesn't exist yet

**EFI patching via curl**
- Terraform provider doesn't expose `enableEfi` flag
- Patched by local-exec curl + Rancher API after machine config creation
- Node pool names must be deterministic (used in curl targets)

---

## 12. Terraform Variables Reference

**Connection & Authentication**
- `rancher_url`: Rancher API endpoint
- `rancher_token`: API token for Rancher
- `harvester_kubeconfig_path`: Path to Harvester cluster kubeconfig (for Terraform state + image lookups)
- `harvester_cloud_credential_kubeconfig_path`: ServiceAccount kubeconfig for cloud credential registration
- `harvester_cluster_id`: Rancher cluster ID of Harvester (e.g., `c-bdrxb`)

**Cluster Naming & Kubernetes Version**
- `cluster_name`: Name of RKE2 cluster (becomes Rancher cluster name)
- `kubernetes_version`: RKE2 version (default: `v1.34.2+rke2r1`)
- `cni`: CNI plugin (default: `cilium`)

**Networking**
- `vm_namespace`: Harvester namespace for VMs
- `harvester_network_name`: VM network name (eth0)
- `harvester_network_namespace`: Namespace of VM network
- `harvester_services_network_name`: Services network name (eth1, default: `services-network`)
- `harvester_services_network_namespace`: Namespace of services network (default: `default`)
- `traefik_lb_ip`: Static LoadBalancer IP for Traefik (default: `192.168.48.2`)
- `cilium_lb_pool_start`: Start of Cilium L2 pool (default: `192.168.48.2`)
- `cilium_lb_pool_stop`: End of Cilium L2 pool (default: `192.168.48.20`)

**Node Pools**

Control Plane:
- `controlplane_count`: Number of CP nodes (default: 3)
- `controlplane_cpu`: vCPUs per CP (default: 8)
- `controlplane_memory`: Memory GiB per CP (default: 32)
- `controlplane_disk_size`: Disk GiB per CP (default: 80)

General Workers:
- `general_cpu`: vCPUs (default: 4)
- `general_memory`: Memory GiB (default: 8)
- `general_disk_size`: Disk GiB (default: 60)
- `general_min_count`: Min nodes (default: 4)
- `general_max_count`: Max nodes (default: 10)

Compute Workers (scale-from-zero):
- `compute_cpu`: vCPUs (default: 8)
- `compute_memory`: Memory GiB (default: 32)
- `compute_disk_size`: Disk GiB (default: 80)
- `compute_min_count`: Min nodes (default: 0) — scale-from-zero
- `compute_max_count`: Max nodes (default: 10)

Database Workers:
- `database_cpu`: vCPUs (default: 4)
- `database_memory`: Memory GiB (default: 16)
- `database_disk_size`: Disk GiB (default: 80)
- `database_min_count`: Min nodes (default: 4)
- `database_max_count`: Max nodes (default: 10)

**Autoscaler Behavior**
- `autoscaler_scale_down_unneeded_time`: Cooldown before scale-down (default: `30m0s`)
- `autoscaler_scale_down_delay_after_add`: Delay after node add (default: `15m0s`)
- `autoscaler_scale_down_delay_after_delete`: Delay after node delete (default: `30m0s`)
- `autoscaler_scale_down_utilization_threshold`: Utilization threshold (default: `0.5`)

**Container Registry**
- `harbor_fqdn`: Harbor registry hostname (required)
- `harbor_registry_mirrors`: List of upstream registries to mirror (default: 8 registries)
- `bootstrap_registry`: Pre-existing registry for Phases 0–3 (required)
- `bootstrap_registry_ca_pem`: CA for bootstrap registry (optional; defaults to `private_ca_pem`)
- `private_ca_pem`: Complete PEM-encoded CA chain (required)

**Docker Hub (optional, rate-limit workaround)**
- `dockerhub_username`: Docker Hub username (default: empty, disables auth)
- `dockerhub_token`: Docker Hub personal access token (default: empty)

**SSH & Cloud Provider**
- `ssh_user`: SSH user for cloud image (default: `rocky`)
- `ssh_authorized_keys`: List of SSH public keys
- `harvester_cloud_credential_name`: Name of pre-existing Harvester cloud credential in Rancher
- `harvester_cloud_provider_kubeconfig_path`: Path to cloud provider kubeconfig

**Golden Image**
- `golden_image_name`: Pre-existing image name on Harvester (required, non-empty validation)

**Operators**
- `deploy_operators`: Deploy node-labeler & storage-autoscaler (default: true)
- `harbor_admin_password`: Harbor admin password for image push (required if `deploy_operators = true`)

---

## Summary

This architecture represents a production-hardened, airgap-ready Kubernetes platform on Harvester. Key design principles:

1. **Golden image first**: All nodes from pre-baked image, no downloads
2. **Airgap ready**: Bootstrap registry for Phases 0–3, Harbor proxy-cache Phase 4+
3. **Specialized pools**: CP, general workers, compute (scale-from-zero), database; each autoscalable
4. **Cilium L2**: Native LoadBalancer support without external controller
5. **Private CA throughout**: Injected to all nodes, registries, Traefik
6. **Deferred OIDC**: Cluster available immediately; identity configured post-deploy (Phase 6)
7. **Custom operators**: Automated node labeling and storage autoscaling
8. **Rancher integration**: Cluster lifecycle managed via Rancher API, not kubectl

The Terraform codebase in `/home/rocky/code/harvester-rke2-cluster` implements this architecture, orchestrating the provisioning of a fully functional RKE2 cluster on Harvester hypervisor infrastructure.
