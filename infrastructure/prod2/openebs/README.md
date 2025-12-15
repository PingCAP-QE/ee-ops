# OpenEBS Mayastor (Replicated PV) — prod2

This folder deploys OpenEBS 4.2 (Mayastor/replicated PV) to the prod2 cluster via Flux. It also applies cluster-specific DiskPools and a default StorageClass.

Contents
- namespace.yaml — OpenEBS namespace
- source.yaml — HelmRepository for OpenEBS charts
- release.yaml — Flux Kustomization to install OpenEBS via HelmRelease
- post.yaml — Flux Kustomization that depends on the release and applies:
  - post/diskpools.yaml — Mayastor DiskPool CRs for your nodes
  - post/storageclass.yaml — Mayastor StorageClass (3 replicas)

Before you deploy, read the safety prerequisites carefully. Mayastor requires specific kernel modules, huge pages, and node labels. Skipping these steps will lead to failed installs or degraded/unsafe storage.

Official docs (recommended): https://openebs.io/docs/quickstart-guide/prerequisites#replicated-pv-mayastor-prerequisites

--------------------------------------------------------------------------------

## Safety prerequisites (cluster and nodes)

Mandatory
- Kubernetes version: 1.23 or higher
- OS/Arch: x86-64 with SSE4.2
- Linux kernel: 5.15 or higher (5.13+ minimum). Kernel modules present:
  - nvme-tcp
  - ext4 (and optionally xfs)
- Huge pages: at least 2 GiB of 2 MiB-sized pages (i.e., 1024 pages) available exclusively per node that will run io-engine
- Helm v3.7+ (Flux uses Helm under the hood)
- Minimum 3 worker nodes (for replication and quorum)
- Node labels: label nodes that will run io-engine with:
  - openebs.io/engine=mayastor
- Node labels for mounting Mayastor PVCs: The label `openebs.io/csi-node=mayastor` will be automatically added by the OpenEBS CSI node daemonset. But you should ensure the node has the `nvme-tcp` kernel module loaded to make the daemonset pod ready.
- Open network ports on storage nodes:
  - 10124 — Mayastor gRPC
  - 8420, 4421 — NVMe-oF target ports
- Kubelet root dir path: ensure it matches the configured value in this repo
  - We set KUBELET_DIR to /data/kubelet
  - All nodes must actually use that path for kubelet, or adjust the value before deploying

Recommended
- Enable NVMe multipath for HA: kernel parameter nvme_core.multipath=Y
- Prefer ext4 on application mountpoints (xfs also works)
- Ensure time sync and low packet loss between nodes for rebuild performance

Preflight checklist
1) Kernel and modules
   - uname -r
   - lsmod | egrep 'nvme_tcp|nvme|xfs|ext4' (ensure nvme_tcp is present/available)
2) Huge pages
   - grep HugePages_ /proc/meminfo
   - If HugePages_Total < 1024, set it (example):
     - echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
     - Persist: echo "vm.nr_hugepages = 1024" | sudo tee -a /etc/sysctl.conf
     - Important: restart kubelet or reboot the node so kubelet reports correct huge pages
3) Node labels
   - kubectl label node <node-name> openebs.io/engine=mayastor
4) Node labels for mounting Mayastor PVCs
   - The label `openebs.io/csi-node=mayastor` will be automatically added by the OpenEBS CSI node daemonset. Ensure the node has the `nvme-tcp` kernel module loaded.
4) Kubelet root dir
   - Confirm kubelet root is /data/kubelet on all worker nodes
   - If it differs in your cluster, update KUBELET_DIR substitution in openebs/release.yaml accordingly
5) Device selection
   - Verify the devices you list in post/diskpools.yaml are:
     - Dedicated to Mayastor (not partitioned/mounted/used by OS)
     - Referenced by stable IDs under /dev/disk/by-id
     - Wiped/clean if they were used before (sgdisk --zap-all, wipefs -a, etc.)
   - Transport URI scheme:
     - uring:///dev/disk/by-id/<id> — best for modern kernels (io_uring)
     - aio:///dev/disk/by-id/<id> — compatible fallback
     - This repo currently uses aio:///. You may switch to uring:/// for better performance if your kernel supports it.

Local PV (optional)
- This stack also configures:
  - OPENEBS_LOCAL_DIR=/data/openebs/local (LocalPV hostpath)
  - If you use Local PV, ensure the directory exists (and is bind-mounted in some environments like RKE per their docs).

--------------------------------------------------------------------------------

## What this deployment installs

- Chart: openebs (version 4.2.0)
- Engines:
  - Replicated: Mayastor enabled
  - Local: LVM/ZFS disabled, LocalPV hostpath base path set (optional)
- CSI and daemonsets configured with:
  - mayastor.csi.node.kubeletDir=/data/kubelet
- StorageClasses:
  - Chart-provided Mayastor StorageClass is set as default by Helm values (mayastor.storageClass.default: true). The name is defined by the chart; verify with: kubectl get storageclass
  - Custom StorageClass openebs-3-replicas (not default by default):
    - provisioner: io.openebs.csi-mayastor
    - protocol: nvmf
    - repl: "3"
    - allowVolumeExpansion: true
    - Requires at least 3 Healthy storage nodes
  - Exactly one default StorageClass should exist. To make openebs-3-replicas the default, set mayastor.storageClass.default: false and add annotation storageclass.kubernetes.io/is-default-class: "true" in post/storageclass.yaml

DiskPools
- Located under post/diskpools.yaml
- apiVersion: openebs.io/v1beta2
- One DiskPool per device, pinned to a node by its spec.node
- Uses by-id paths for stability across reboots

--------------------------------------------------------------------------------

## How to deploy (GitOps via Flux)

- Commit any changes under infrastructure/prod2/openebs and push
- Flux will:
  1) Create the openebs namespace
  2) Reconcile the HelmRelease (installs CRDs, control plane, and data plane)
  3) After the release is ready, apply post (DiskPools + StorageClass)

Verify
- kubectl -n openebs get pods
- kubectl -n openebs get diskpools
- kubectl get storageclass | grep openebs-3-replicas
- Create a test PVC (see test.yaml.example in this folder), bind it, and confirm the PV is Healthy

--------------------------------------------------------------------------------

## Operating safely

Volume replica health
- Ensure application volumes are Healthy before disruptive operations
- For zero-downtime maintenance, use at least repl=2 (or repl=3, as default here)

Node maintenance (Mayastor-aware)
- Cordon node at Kubernetes level if needed
- Mayastor also supports pool-level cordon/drain to move replicas off a specific pool

Device/pool planning
- Maintain spare capacity across pools to allow rebuilds and safe migrations
- Use by-id device paths in DiskPools
- Prefer uring:/// on modern kernels for better performance

Networking
- Keep nvme-tcp ports open between nodes
- Watch for packet loss/latency during rebuilds

--------------------------------------------------------------------------------

## Replacing a Mayastor DiskPool (safe procedure)

Goal: Move replicas away, delete the old DiskPool, and create a new one — without downtime if repl ≥ 2.

1) Identify the old pool and affected volumes
   - kubectl -n openebs get diskpools
   - kubectl -n openebs get volumes -o wide
   - Note which volumes have replicas on the pool you’ll replace

2) Create the replacement DiskPool on the new device
   - Add a new DiskPool CR (prefer /dev/disk/by-id and uring:/// if possible)
   - Commit and push; wait for the new pool to be Online

3) Cordon the old pool (prevent new placements)
   - Patch the DiskPool to set spec.cordon: true

4) Drain/migrate replicas
   - If your version supports a pool drain operation, use it
   - Otherwise, per volume:
     - Temporarily increase replica count by +1 (e.g., from 3 to 4)
     - Wait for the volume to become Healthy again
     - Reduce replica count back (the replica on the old pool should be removed)
   - Repeat until no replicas remain on the old pool

5) Verify
   - kubectl -n openebs get volumes -o wide
   - Ensure all volumes are Healthy and none have replicas on the old pool

6) Remove the old pool
   - kubectl -n openebs delete diskpool <old-pool-name>
   - Physically replace/wipe the old device if reusing

7) Cleanup/rebalance
   - If you temporarily changed replica counts, set them back to desired values
   - Confirm volumes remain Healthy

Notes
- If any volume had repl=1 on the old pool, you must raise it to ≥2 before draining to avoid downtime
- If the old node/pool is down, increase replica counts so new replicas are created elsewhere, then remove the faulted replica and delete the DiskPool CR

--------------------------------------------------------------------------------

## Common issues and fixes

- Not enough huge pages:
  - Increase vm.nr_hugepages and restart kubelet or reboot
- nvme-tcp not available:
  - Install/load nvme_tcp module on nodes; ensure kernel ≥ 5.13
- DiskPool Offline:
  - Check device path (by-id), permissions, and that the disk isn’t in use
- PVC Pending:
  - Ensure at least one Online pool exists with enough free space
  - Check that nodes are labeled openebs.io/engine=mayastor
- Pod Pending:
  - Ensure that nodes have the `nvme-tcp` kernel module loaded if mounting Mayastor PVCs. The label `openebs.io/csi-node=mayastor` is automatically added by the OpenEBS CSI node daemonset.
- CSI mount failures:
  - Verify KUBELET_DIR matches actual kubelet root directory on the nodes

--------------------------------------------------------------------------------

## Parameters and paths used here

- KUBELET_DIR: /data/kubelet
  - Update in openebs/release.yaml if your kubelet root differs
- OPENEBS_LOCAL_DIR: /data/openebs/local
  - Create the path on nodes if you use LocalPV hostpath
- StorageClasses:
  - Chart default: enabled via mayastor.storageClass.default: true (name per chart)
  - Custom: openebs-3-replicas (protocol: nvmf, repl: "3") — not default unless you annotate it and disable the chart default

--------------------------------------------------------------------------------

## References

- OpenEBS prerequisites (Replicated PV Mayastor):
  https://openebs.io/docs/quickstart-guide/prerequisites#replicated-pv-mayastor-prerequisites
- Mayastor operations and best practices:
  - High Availability, Replica Rebuilds, Node Cordon/Drain, etc. in the OpenEBS docs

If you want me to tailor the DiskPools to your exact node/device inventory (switch to uring:///, validate IDs, or add more pools), share the node names, by-id paths, and desired layout.
