# necropolis — the bare-metal kubeadm plan

**Status: phases 1–3 written 2026-09-28, none yet run against hardware.
Phase 4 outlined.** Supersedes
docs/spectre.md, the k8s-aio migration plan, which is in git history. The SER9
that plan was written for has left the estate, and with it every KVM guest,
the br0 bridge and Terraform. What it learned about kubeadm survives, and is
carried forward below.

## What necropolis is

One kubeadm HA cluster across three identical Beelink SER8s — `cadaver`,
`spectre`, `banshee` — each with a 512 GB boot drive and a 1 TB data drive
dedicated to Longhorn, all wired. Three control-plane nodes, stacked etcd 
(quorum 2 of 3), a kube-vip ARP-mode VIP for the API, Cilium with kube-proxy 
replacement. All three nodes are schedulable: with only three machines, 
reserving them for the control plane would leave nowhere for workloads.

infra builds all of it, host layer included.

`necropolis` names the cluster and no machine. The kubeconfig context and the
`cluster` metrics label both carry it, so neither changes when a node does.
That it collides with no hostname also means it can name the inventory group:
an Ansible group and host sharing a name is ambiguous, and `spectre` as a
cluster name would have forced a second, invented group name.

## Decisions

**One playbook, `playbooks/necropolis/`, targeting the group.** The per-host
playbooks that preceded this (cadaver's standalone k3s, spectre's cluster-only
layer over k8s-aio) are deleted rather than adapted: both composed a single
machine, and a cluster is not three machines composed separately.

**The cluster layer runs once.** `_layers.yml` targeted `{{ target }}` in both
plays, which for a group runs the host layer on every node — correct — and the
cluster layer once per node, installing every chart three times against the
same API. The cluster-layer play now targets `{{ target }}[0]`. A subscript on
a single host resolves to that host (checked with `--list-hosts`: `phantom[0]`
is phantom), so the single-host playbooks are unaffected.

**The cluster is a group, nested into the capability groups.** `necropolis`
in inventory/hosts.yml lists the three nodes; `kubeadm_clusters` and
`wired_hosts` include it with `children:`, so membership is stated once.
`group_vars/necropolis.yml` carries the cluster's identity. The nodes have no
host_vars.

**The VIP lives in DNS, not in the repository.** `necropolis.lan` is an A
record for the VIP, resolved on the node at run time and asserted before use.
The same mechanism as `registry.lan` and `metrics.lan`: no address is
committed, and moving the VIP is a DNS edit. The API server certificate
carries `necropolis.lan` as a SAN, so kubeconfigs name the cluster rather than
an address — the improvement docs/spectre.md deferred to "the next rebuild".

**Node addresses are facts.** `ansible_default_ipv4.address` and `.interface`
supply the node IP for kubeadm and the interface for kube-vip. Nothing
per-node is declared, so the three nodes need no host_vars at all.

**The init node is chosen by position, and guarded by the VIP.** The first
host of the play initialises; the rest join. That is `ansible_play_hosts_all[0]`,
which names no machine, so the role stays within the rule against
`when: inventory_hostname == …`. Position alone is unsafe: under `--limit
banshee`, banshee is first. The real guard is that **`kubeadm init` never runs
while `necropolis.lan:6443` answers** — a live VIP means a cluster exists, and
a node with no `/etc/kubernetes/admin.conf` then joins it instead. A second
cluster cannot be formed by accident.

**Longhorn on the 1 TB drives, mounted at `/var/lib/longhorn`** — Longhorn's
default data path, so the chart needs no disk configuration. Decided
2026-09-28. The disk is found by elimination (the one disk with no partition
table, no filesystem and no children), never by device name, since two NVMe
drives can enumerate in either order. Formatted XFS — matching the boot
drives, and without ext4's 5% root reservation, which would hide ~50 GB of a
disk only Longhorn writes to — with the label `longhorn`, which is how every
later run finds it and how fstab names it. The role refuses rather than guesses: 
no blank disk or more than one stops the run
with the list, a disk carrying any signature is never formatted, and nothing
forces. Mounted `nofail`, so a dead data disk leaves a reachable node rather
than one in emergency mode; Longhorn's per-disk UUID marks the empty
mountpoint unschedulable instead of filling the boot drive.

**containerd owns the registry configuration.** `roles/registry_mirror` writes
k3s's `registries.yaml`, which kubeadm nodes do not have. containerd reads
`/etc/containerd/certs.d/<host>/hosts.toml` on every pull, so the k3s ordering
constraint (read once, at start) does not apply, and the file belongs with the
`config_path` setting that makes containerd look for it. The semantics are
unchanged: `registry.lan` is a distinct registry, never a mirror for docker.io.

**Roles, by the fork test in ARCHITECTURE.md:**

| Role                    | New or existing | What it does                                                                             |
| ----------------------- | --------------- | ---------------------------------------------------------------------------------------- |
| `preflight`             | existing        | Gains the kubeadm branch of its k3s-only asserts (context named, cgroup controllers).    |
| `base`                  | existing        | Unchanged. Already carries rsyslog removal, inotify limits and chrony.                   |
| `wired_link`            | existing        | Unchanged. Discovers the wired interface and suppresses EEE.                             |
| `containerd`            | new             | Upstream tarball, templated config, `registry.lan` hosts.toml.                           |
| `kubeadm_node`          | new             | Kernel modules, sysctls, swap off, held kubelet/kubeadm/kubectl packages.                |
| `longhorn_node`         | new             | open-iscsi, NFS client, cryptsetup, modules, iscsid, multipath blacklist, the data disk. |
| `kubeadm_control_plane` | new             | kube-vip, `kubeadm init`, control-plane joins, untaint, serving-CSR approval.            |
| `kubeconfig`            | existing        | Gains a kubeadm mode: a different source path and server, the same merge. Values only.   |

`kubeadm_control_plane` is the name ARCHITECTURE.md already reserved for this
procedure when it argued spectre fails the fork test against `k3s_server`.

## Prerequisites (user-run, before phase 1)

1. Ubuntu Server 26.04 on each SER8, installed to the **512 GB** drive, with
   the machine's hostname set to its inventory name. The 1 TB drive is left
   blank: the installer offers to use every disk it sees, and `longhorn_node`
   will not format a disk that carries anything. A drive that shipped with an
   OS on it is cleared by hand (`wipefs -a`) before the first run.
2. A static address per node, outside the DHCP range.
3. Router DNS: A records for `cadaver.lan`, `spectre.lan` and `banshee.lan`;
   `spectre.lan` currently names the departed SER9 and must be repointed.
   `k8s-aio.lan` names that cluster's VIP and is removed.
4. Router DNS: `necropolis.lan` → one more free address outside the DHCP range,
   on the same subnet as the nodes, that nothing else will ever answer for.
5. `~/.ssh/config` entries for the three hostnames, with a `User` holding
   NOPASSWD sudo.

## Phase 1 — three prepared nodes

Inventory: the `necropolis` group, listed `cadaver`, `spectre`, `banshee` —
the first is the init node. `group_vars/necropolis.yml` carries
`kubeconfig_context: necropolis`. `playbooks/necropolis/{main,verify}.yml`,
imported last in site.yml.

Host roles: `preflight`, `base`, `wired_link`, `containerd`, `kubeadm_node`,
`longhorn_node`. preflight's context and cgroup asserts, previously k3s-only,
now cover `kubeadm_clusters`, and it refuses a host in both `k3s_servers` and
`kubeadm_clusters`.

**`containerd`**, ported from k8s-aio's guest cloud-init:

- Upstream release tarball and its published `.sha256sum`, downloaded under
  their published names and verified before extraction. Ubuntu 26.04's
  containerd package SIGSEGVs on any invocation; `runc` still comes from the
  archive, where it works.
- The upstream `containerd.service`, since the tarball installs to
  `/usr/local` and Ubuntu's unit points at `/usr/bin`.
- `config.toml` **templated**, not produced by `containerd config default` and
  a `sed`. A `sed` that matches nothing succeeds, so a changed default layout
  would silently leave `SystemdCgroup` false — and kubelet and containerd
  disagreeing about cgroup ownership fails pods with an error naming neither.
- `config_path = "/etc/containerd/certs.d"` and the `registry.lan` hosts.toml.
- Restart on config change only.

**`kubeadm_node`**:

- `overlay` and `br_netfilter` loaded now and at boot; `net.bridge.bridge-nf-
  call-ip{,6}tables = 1` and `net.ipv4.ip_forward = 1`. There is no host
  bridge any more, so the host/guest inversion k8s-aio documented is gone.
- **Swap off, and on bare metal this is real work.** k8s-aio's guests were
  cloud images with no swap, and the step was belt-and-braces. The Ubuntu
  Server installer creates `/swap.img` and an fstab line for it; both go.
- The pkgs.k8s.io apt repository for the pinned minor, keyring in
  `/etc/apt/keyrings`; kubelet, kubeadm and kubectl installed and **held**, so
  an unattended upgrade cannot step one node onto a different minor.
- kubelet enabled. It crash-loops until `kubeadm init` or `join` writes its
  config; that is expected and not a failure.

**`longhorn_node`**: open-iscsi, nfs-common, cryptsetup, dmsetup; `iscsi_tcp`
and `dm_crypt` loaded now and at boot, with iscsid restarted if a module
arrives after it started (Longhorn requires `iscsi_tcp` first); multipathd
kept off `/dev/sd*` with Longhorn's documented blacklist, as a drop-in, where
multipath-tools is installed; then the data disk as decided above.

**Not ported:** qemu-guest-agent (no hypervisor), and the conditional
prereqs marker, which existed because cloud-init does not stop on failure.
Ansible does.

**Verify:** containerd at the pin, active and enabled; `containerd config
dump` reports `SystemdCgroup = true` and the `config_path` (the *effective*
config, not the file); no active swap in `/proc/swaps`; modules loaded;
sysctls in effect; kubelet, kubeadm and kubectl at the pinned version and
held; `/var/lib/longhorn` a mount of the `longhorn`-labelled XFS filesystem
(a plain directory there looks identical until the boot drive fills); iscsid
active.

**Stop point:** three nodes that could form a cluster and have not. Second run
`changed=0`.

## Phase 2 — formation

Written 2026-09-28 as `roles/kubeadm_control_plane`, plus a kubeadm mode in
`roles/kubeconfig`. **Untested:** nothing here has run against a kubeadm
binary, so the first run is the shakedown, and the phased init (step 3) is
the step most likely to need correcting.

The ordering is k8s-aio's `lib/kubeadm.sh`, and **every step of it is
load-bearing**. Where the port departs from it, the reason is given.

1. **Pre-assert, every node.** `necropolis.lan` resolves on the node; the
   address is no node's own; `ip route get` reaches it without a gateway,
   because ARP only reaches the local segment.
2. **State.** A node is a member when it has `kubelet.conf`. The API is up
   when a TCP connect to the VIP succeeds. Formation happens only when no node
   in the play is a member **and** the API does not answer; otherwise
   non-members join. Before init, the VIP must also not answer ping — anything
   that does is another machine holding the address. A run where the API
   answers but no member is in the play stops: joining needs a member to issue
   credentials.
3. **Init, in phases — a deliberate departure.** k8s-aio rendered kube-vip
   from `super-admin.conf` *before* `kubeadm init`, through `sed … | tee`. But
   `super-admin.conf` does not exist until init writes it, so `sed` failed,
   `tee` wrote an empty file, and the pipe reported success. Here: `kubeadm
   init phase certs all`, then `phase kubeconfig all`, then kube-vip is
   pointed at a loopback copy of the now-existing `super-admin.conf`, then
   `kubeadm init --upload-certs --skip-phases=certs,kubeconfig,addon/kube-proxy`
   runs every remaining phase, including the wait for the VIP. The two traps
   the loopback copy exists for still apply:
   - Since 1.29, init's `admin.conf` has no cluster-admin binding until init
     completes. kube-vip mounting it crash-loops on RBAC, and init hangs in
     wait-control-plane for a VIP that never comes.
   - Both kubeconfigs name the VIP. kube-vip needs the API to take the lease
     that creates the VIP, so without the loopback rewrite it logs "no route
     to host" forever and never claims the address.
4. **The init configuration** is k8s-aio's v1beta4 template with three
   changes. `controlPlaneEndpoint` is the VIP's *address* (resolved from
   DNS), so kubelets and kube-vip never depend on the router's resolver; the
   *name* goes in `certSANs`. The node-specific SANs k8s-aio put in the
   cluster-wide `ClusterConfiguration` (node 1's IP, in every node's
   certificate) are dropped — kubeadm adds each node's own. And
   `kubernetesVersion` is the pin, which phase 1's gate already holds the
   binaries to. Kept: `clusterName: necropolis`, node IP pinned in
   `kubeletExtraArgs`, scheduler/controller-manager/etcd metrics bound
   off-loopback for phase 4, `cgroupDriver: systemd`,
   `serverTLSBootstrap: true`.
5. **Joins, with a `JoinConfiguration`** instead of replaying `--print-join-
   command`. The printed command cannot carry per-node settings, and k8s-aio
   pinned `node-ip` on node 1 only. The token (1 h TTL) and certificate key
   are issued **once per run** for all joiners: `upload-certs` re-encrypts the
   CA material under a new key each call, so a key per node would invalidate
   the previous node's. Joins run one at a time (`throttle: 1`), because each
   adds an etcd member. The join file carries secrets, is `0600`, and is
   deleted after the join.
6. **kube-vip on `admin.conf`, every node** — on the init node, the swap away
   from `super-admin.conf` (system:masters); on joiners, kube-vip's first
   appearance. `admin.conf` missing after a join is an **assert**, not a
   regeneration: k8s-aio's fallback ran `kubeadm init phase kubeconfig admin`
   with no configuration, which writes one against kubeadm's defaults rather
   than this cluster's endpoint.
7. **The swap reaches the running pod** through a checksum annotation on the
   manifest. Ansible replaces files by rename, so a container that
   bind-mounted the old kubeconfig keeps reading the old inode — super-admin
   credentials included — until the pod is recreated. A changed checksum
   changes the manifest and kubelet recreates the pod; an unchanged one leaves
   it alone. The VIP blinks during the init node's swap, so joins wait for it.
8. **Untaint** only nodes that still carry the taint, so a converged cluster
   reports no change.
9. **Approve kubelet-serving CSRs — new, and deliberately narrow.** k8s-aio
   left them Pending after every rebuild and rotation. Approved only when the
   requester is `system:node:<name>` for a node in the play, and every IP and
   DNS name requested belongs to that node's gathered facts. Anything else
   stays Pending for a human.
10. **`kubeconfig`, kubeadm mode.** `admin.conf` read once, from a member. Its
    server is *asserted* to be the VIP address, then replaced by
    `https://necropolis.lan:6443`. Cluster, user and context are all renamed
    `necropolis`: kubeadm names every cluster's user `kubernetes-admin`, and
    two of those merged into one workstation config would overwrite each
    other's credentials. Every workstation-side task runs once, so three nodes
    never race on the same file.

Nodes are `NotReady` at the end of phase 2. That is correct: there is no CNI
until phase 3.

**Recovery from a failed init:** the kubeconfig phase writes `kubelet.conf`
early, so a node whose init died later looks like a member. `kubeadm reset -f`
on that node, then run again. The role does not try to detect a half-formed
node: a wrong guess there re-initialises a cluster.

**Verify:** each node a member, and kube-vip's kubeconfig on admin credentials
through loopback; through the API, all three nodes registered as control plane
with no taint, three started etcd members, the `plndr-cp-lock` lease held by a
node, no Pending kubelet-serving CSR from a known node; and from the
workstation, `kubectl --context necropolis get --raw /readyz` by name — the one
check that exercises the DNS record, the certificate SAN and the merged
kubeconfig together.

**Stop point and shakedown:** `changed=0` on a second run, then a failover
drill — stop kubelet on the node holding the lease, and the VIP moves and
`necropolis.lan:6443` keeps answering.

## Phase 3 — addons

Written 2026-09-28 as the cluster layer of `playbooks/necropolis/`: `cilium`
(extended), `longhorn`, `cert_manager` and `gateway`. **Untested**, like phase
2: it parses and its expressions were checked against fixture data, and the
first run against the formed cluster is the shakedown.

The cluster layer runs **once**, on the first node's facts, from the
workstation, against the `necropolis` context.

**Before the first run (user-run):**

1. Router DNS: `hubble.lan` → the `.90` address. `grafana.lan` → a CNAME to
   `phantom.lan` (the estate's one Grafana, at `:30300`), replacing the dead
   k8s-aio record.
2. After the run that creates the CA: trust it in the macOS System keychain,
   once — the playbook prints the `security add-trusted-cert` command with
   the path. Firefox keeps its own store and needs it imported separately.

### cilium, extended

The existing role, with four capabilities that default **off**, so revenant's
single-node install is unchanged:

- **Gateway API CRDs** (v1.6.1, the version Cilium 1.20 documents) applied
  server-side *before* the chart. Cilium's Gateway controller starts only if
  the CRDs exist when the operator does; installed afterwards, a Gateway is
  accepted and programmed by nothing.
- **L2 announcements**, with k8s-aio's client rate limit (qps 50, burst 100):
  every announced Service holds a Lease, and the upstream defaults produce
  stalls that look like flapping.
- **LoadBalancer pools** from `lb_pools`, declared as **host offsets** (`90`,
  `91–99`) within the nodes' /24, which is a gathered fact — so no routable
  address is committed, the same rule that keeps `ansible_host` out of
  inventory. The role asserts a single /24 and that no pool address is a node
  or the VIP. A labelled pool serves only Services carrying its label; an
  unlabelled one only Services without it, so the pools partition every
  Service and nothing but the Gateway can take `.90`.
- **The L2 policy** names every node's LAN interface from facts, and carries
  **no nodeSelector**: Cilium's upstream example excludes control-plane nodes,
  and every node here is one — copied verbatim it selects nothing, and Services
  show an EXTERNAL-IP that nothing answers ARP for (found on k8s-aio).

Also generalised: the Ready wait and gate cover every node of `cluster_hosts`,
not only the host the layer runs on; the operator's replica count moved out of
`charts/values/cilium.yaml` into the role (2 here, 1 on a single node).

Cilium's own metrics stay off, as on revenant, so the kube-prometheus-stack
CRDs are **not** needed ahead of it — the ordering k8s-aio needed only because
it enabled ServiceMonitors.

### longhorn

Chart 1.12.1 on the disks phase 1 mounted: 3 replicas, the default
StorageClass, data path `/var/lib/longhorn` — the chart's defaults, stated so
a chart that changes its mind cannot change the cluster's. The install waits
until every node's disk is schedulable. The gate also checks **where** each
disk is: a disk registered at the right path on the *root* filesystem is
schedulable too, and fills the boot drive. The Longhorn UI is not published:
it has no authentication and can delete volumes.

### cert_manager

- **The root CA on the workstation**, in `cluster_ca_dir`
  (`~/.local/share/infra/pki/necropolis/`, a cross-role contract): RSA 4096,
  ten years, generated once and **never regenerated** by the role — a new root
  silently invalidates every browser that trusts the old one.
- cert-manager v1.21.2 with its CRDs, kept on uninstall (deleting them would
  delete every Certificate).
- The CA imported as a TLS Secret in cert-manager's own namespace — a
  ClusterIssuer reads its Secret from there, the commonest way one stays not
  Ready — and the `necropolis-ca` ClusterIssuer.
- Gates: the CA is a CA with a year left; the ClusterIssuer is Ready.

### gateway

One Gateway (`gateway/necropolis`, class `cilium`) on `.90`, requested through
`spec.addresses`, with the pool label set through `spec.infrastructure` so its
generated Service matches the `gateway` pool. HTTPS terminates there with a
90-day certificate from `necropolis-ca`, written as an explicit Certificate
rather than relying on cert-manager's opt-in gateway-shim. HTTP only
redirects. One HTTPRoute per entry in `gateway_routes`, living beside its
Service; `hubble.lan` is the only one.

The last gate is end to end from the workstation: each hostname resolves to
`.90`, and HTTPS to it returns 200 while verifying against the workstation CA
— DNS, L2 announcement, the Gateway, the certificate chain and the route,
proved together.

## Phase 4 — observability (outline)

`roles/observability`, whose `kubeadm_clusters` scrape branch already exists.
`prometheus_external_labels: {cluster: necropolis}` in group_vars; Grafana,
Jaeger and the discovery contract off, as on every host but phantom.

## Pins

Checked 2026-09-28 against upstream release lists and compatibility tables.
The binding constraint is Cilium, whose 1.20 line is tested through
Kubernetes 1.36.

| Component    | Pin                    | Why this one                                                             | Where                |
| ------------ | ---------------------- | ------------------------------------------------------------------------ | -------------------- |
| Kubernetes   | 1.36.5 (deb `-1.1`)    | 1.37.1 exists, but Cilium 1.20 does not list it. Same minor as revenant. | `group_vars/all.yml` |
| containerd   | 2.3.6                  | 2.3 is LTS to 2028 and supports 1.36 and 1.37; 2.4 supports 1.37 only.   | `group_vars/all.yml` |
| Cilium       | 1.20.1 (1.20.2 is out) | The estate pin, shared with revenant. Bumping it is its own change.      | `group_vars/all.yml` |
| kube-vip     | v1.2.4                 | Latest.                                                                  | `group_vars/all.yml` |
| Longhorn     | v1.12.1                | Latest; requires Kubernetes ≥ 1.25.                                      | `group_vars/all.yml` |
| cert-manager | v1.21.2                | Latest.                                                                  | `group_vars/all.yml` |
| Gateway API  | v1.6.1 (v1.6.2 is out) | The version Cilium 1.20 documents; its CRDs precede Cilium.              | `group_vars/all.yml` |

Ubuntu 26.04's own containerd package is still not used, for the SIGSEGV
recorded in roles/containerd. That finding is from k8s-aio's guests and was
not re-tested on bare metal; the upstream tarball is needed for the pin
regardless.

## Open questions

- **The UPS.** One UPS feeds all three nodes and is cabled over USB to
  spectre. `roles/nut` runs there as a netserver and on cadaver and banshee as
  a netclient, selected by `nut_server_host` in `group_vars/necropolis.yml`.
  The clients' shared password is held on the workstation in
  `~/.local/share/infra/nut/spectre/secondary-password`, so a client can be
  configured while spectre is down. `nut_killpower` stays false. 
  **ztlab.** Expected to return onto necropolis. Not planned here.
