# necropolis: the bare-metal kubeadm build

**Status: built and running. Phases 1 to 4 are complete. The clabernetes
controller is installed with no topology deployed, and AWX and Vault are
running.**

## What necropolis is

One kubeadm HA cluster across three identical Beelink SER8s (`cadaver`,
`spectre`, `banshee`), each with a 512 GB boot drive and a 1 TB data drive
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

**One playbook, `playbooks/necropolis/`, targeting the group.** A cluster is
not three machines composed separately, so there are no per-node playbooks.

**The cluster layer runs once.** `_layers.yml` targeted `{{ target }}` in both
plays, which for a group runs the host layer on every node, which is correct, and the
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
an address.

**Node addresses are facts.** `ansible_default_ipv4.address` and `.interface`
supply the node IP for kubeadm and the interface for kube-vip. Nothing
per-node is declared, so the three nodes need no host_vars at all.

**The init node is chosen by position, and guarded by the VIP.** The first
host of the play initialises; the rest join. That is `ansible_play_hosts_all[0]`,
which names no machine, so the role stays within the rule against
`when: inventory_hostname == …`. Position alone is unsafe: under `--limit
banshee`, banshee is first. The real guard is that **`kubeadm init` never runs
while `necropolis.lan:6443` answers**. A live VIP means a cluster exists, and
a node with no `/etc/kubernetes/admin.conf` then joins it instead. A second
cluster cannot be formed by accident.

**Longhorn on the 1 TB drives, mounted at `/var/lib/longhorn`**, Longhorn's
default data path, so the chart needs no disk configuration.
The disk is found by elimination (the one disk with no partition
table, no filesystem and no children), never by device name, since two NVMe
drives can enumerate in either order. Formatted XFS (matching the boot
drives, and without ext4's 5% root reservation, which would hide ~50 GB of a
disk only Longhorn writes to) with the label `longhorn`, which is how every
later run finds it and how fstab names it. The role refuses rather than guesses:
no blank disk or more than one stops the run
with the list, a disk carrying any signature is never formatted, and nothing
forces. Mounted `nofail`, so a dead data disk leaves a reachable node rather
than one in emergency mode; Longhorn's per-disk UUID marks the empty
mountpoint unschedulable instead of filling the boot drive.

**One UPS feeds all three nodes, and spectre serves it.** The UPS is cabled
over USB to spectre. `roles/nut` runs there as a netserver and as a netclient
on every other host the UPS powers: cadaver, banshee, phantom and wraith. Those
hosts form the `ups_main` inventory group, and `nut_server_host` in
`group_vars/ups_main.yml` names the server once for all of them, because the
UPS belongs to the power domain rather than to the cluster. The clients' shared
password is held on the workstation, outside the repository, so a client can be
configured while spectre is down. `nut_killpower` stays false.

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
| `kubeadm_node`          | new             | Kernel modules, sysctls, swap off, held kubelet/kubeadm/kubectl packages, crictl.        |
| `longhorn_node`         | new             | open-iscsi, NFS client, cryptsetup, modules, iscsid, multipath blacklist, the data disk. |
| `kubeadm_control_plane` | new             | kube-vip, `kubeadm init`, control-plane joins, untaint, serving-CSR approval.            |
| `kubeconfig`            | existing        | Gains a kubeadm mode: a different source path and server, the same merge. Values only.   |

`kubeadm_control_plane` is the role ARCHITECTURE.md names when it argues that
the necropolis nodes fail the fork test against `k3s_server`.

## Prerequisites, done by hand before phase 1

1. Ubuntu Server 26.04 on each SER8, installed to the **512 GB** drive, with
   the machine's hostname set to its inventory name. The 1 TB drive is left
   blank: the installer offers to use every disk it sees, and `longhorn_node`
   will not format a disk that carries anything. A drive that shipped with an
   OS on it is cleared by hand (`wipefs -a`) before the first run.
2. A static address per node, outside the DHCP range.
3. Router DNS: A records for `cadaver.lan`, `spectre.lan` and `banshee.lan`.
4. Router DNS: `necropolis.lan` → one more free address outside the DHCP range,
   on the same subnet as the nodes, that nothing else will ever answer for.
5. `~/.ssh/config` entries for the three hostnames, with a `User` holding
   NOPASSWD sudo.

## Phase 1: three prepared nodes

Inventory: the `necropolis` group, listed `cadaver`, `spectre`, `banshee`.
The first is the init node. `group_vars/necropolis.yml` carries
`kubeconfig_context: necropolis`. `playbooks/necropolis/{main,verify}.yml`,
imported last in site.yml.

Host roles: `preflight`, `base`, `wired_link`, `containerd`, `kubeadm_node`,
`longhorn_node`. preflight's context and cgroup asserts, previously k3s-only,
now cover `kubeadm_clusters`, and it refuses a host in both `k3s_servers` and
`kubeadm_clusters`.

**`containerd`**:

- Upstream release tarball and its published `.sha256sum`, downloaded under
  their published names and verified before extraction. Ubuntu 26.04's
  containerd package SIGSEGVs on any invocation; `runc` still comes from the
  archive, where it works.
- The upstream `containerd.service`, since the tarball installs to
  `/usr/local` and Ubuntu's unit points at `/usr/bin`.
- `config.toml` **templated**, not produced by `containerd config default` and
  a `sed`. A `sed` that matches nothing succeeds, so a changed default layout
  would silently leave `SystemdCgroup` false, and kubelet and containerd
  disagreeing about cgroup ownership fails pods with an error naming neither.
- `config_path = "/etc/containerd/certs.d"` and the `registry.lan` hosts.toml.
- `/etc/crictl.yaml` naming containerd's socket, since the socket is this
  role's. Without it `crictl` tries several sockets in turn and warns on each.
- Restart on config change only.

**`kubeadm_node`**:

- `overlay` and `br_netfilter` loaded now and at boot; `net.bridge.bridge-nf-
  call-ip{,6}tables = 1` and `net.ipv4.ip_forward = 1`.
- **Swap off, and on bare metal this is real work.** The Ubuntu Server
  installer creates `/swap.img` and an fstab line for it; both go.
- The pkgs.k8s.io apt repository for the pinned minor, keyring in
  `/etc/apt/keyrings`; kubelet, kubeadm and kubectl installed and **held**, so
  an unattended upgrade cannot step one node onto a different minor.
- `cri-tools` (`crictl`) from the same repository, neither pinned nor held. It
  versions on its own, so the kubelet pin cannot name it, and as a client it
  carries no skew risk. The per-minor repository keeps it on the cluster's
  minor. The upstream containerd tarball does not include it.
- kubelet enabled. It crash-loops until `kubeadm init` or `join` writes its
  config; that is expected and not a failure.

**`longhorn_node`**: open-iscsi, nfs-common, cryptsetup, dmsetup; `iscsi_tcp`
and `dm_crypt` loaded now and at boot, with iscsid restarted if a module
arrives after it started (Longhorn requires `iscsi_tcp` first); multipathd
kept off `/dev/sd*` with Longhorn's documented blacklist, as a drop-in, where
multipath-tools is installed; then the data disk as decided above.

**Verify:** containerd at the pin, active and enabled; `containerd config
dump` reports `SystemdCgroup = true` and the `config_path` (the *effective*
config, not the file); no active swap in `/proc/swaps`; modules loaded;
sysctls in effect; kubelet, kubeadm and kubectl at the pinned version and
held; `/var/lib/longhorn` a mount of the `longhorn`-labelled XFS filesystem
(a plain directory there looks identical until the boot drive fills); iscsid
active.

**Result:** three nodes that could form a cluster and have not. Second run
`changed=0`.

## Phase 2: formation

Built as `roles/kubeadm_control_plane`, plus a kubeadm mode in
`roles/kubeconfig`. **Every step of the ordering below is load-bearing.**

1. **Pre-assert, every node.** `necropolis.lan` resolves on the node; the
   address is no node's own; `ip route get` reaches it without a gateway,
   because ARP only reaches the local segment.
2. **State.** A node is a member when it has `kubelet.conf`. The API is up
   when a TCP connect to the VIP succeeds. Formation happens only when no node
   in the play is a member **and** the API does not answer; otherwise
   non-members join. Before init, the VIP must also not answer ping: anything
   that does is another machine holding the address. A run where the API
   answers but no member is in the play stops: joining needs a member to issue
   credentials.
3. **Init, in phases.** kube-vip's manifest needs `super-admin.conf`, which
   does not exist until init writes it, so a manifest rendered before
   `kubeadm init` is rendered from nothing. So: `kubeadm
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
4. **The init configuration** is a v1beta4 template.
   `controlPlaneEndpoint` is the VIP's *address* (resolved from
   DNS), so kubelets and kube-vip never depend on the router's resolver; the
   *name* goes in `certSANs`. No node-specific SANs go in the cluster-wide
   `ClusterConfiguration`, because kubeadm adds each node's own.
   `kubernetesVersion` is the pin, which phase 1's gate already holds the
   binaries to. Also set: `clusterName: necropolis`, node IP pinned in
   `kubeletExtraArgs`, scheduler/controller-manager/etcd metrics bound
   off-loopback for phase 4, `cgroupDriver: systemd`,
   `serverTLSBootstrap: true`.
5. **Joins, with a `JoinConfiguration`** instead of replaying `--print-join-
   command`. The printed command cannot carry per-node settings such as
   `node-ip`. The token (1 h TTL) and certificate key
   are issued **once per run** for all joiners: `upload-certs` re-encrypts the
   CA material under a new key each call, so a key per node would invalidate
   the previous node's. Joins run one at a time (`throttle: 1`), because each
   adds an etcd member. The join file carries secrets, is `0600`, and is
   deleted after the join.
6. **kube-vip on `admin.conf`, every node.** On the init node, the swap away
   from `super-admin.conf` (system:masters); on joiners, kube-vip's first
   appearance. `admin.conf` missing after a join is an **assert**, not a
   regeneration: `kubeadm init phase kubeconfig admin` with no configuration
   writes one against kubeadm's defaults rather than this cluster's endpoint.
7. **The swap reaches the running pod** through a checksum annotation on the
   manifest. Ansible replaces files by rename, so a container that
   bind-mounted the old kubeconfig keeps reading the old inode, super-admin
   credentials included, until the pod is recreated. A changed checksum
   changes the manifest and kubelet recreates the pod; an unchanged one leaves
   it alone. The VIP blinks during the init node's swap, so joins wait for it.
8. **Untaint** only nodes that still carry the taint, so a converged cluster
   reports no change.
9. **Approve kubelet-serving CSRs, deliberately narrowly.**
   `serverTLSBootstrap` otherwise leaves them Pending after every build and
   rotation. Approved only when the
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
workstation, `kubectl --context necropolis get --raw /readyz` by name, the one
check that exercises the DNS record, the certificate SAN and the merged
kubeconfig together.

**Result and acceptance:** `changed=0` on a second run, then a failover
drill: stop kubelet on the node holding the lease, and the VIP moves and
`necropolis.lan:6443` keeps answering.

## Phase 3: addons

Built as the cluster layer of `playbooks/necropolis/`: `cilium` (extended),
`longhorn`, `cert_manager` and `gateway`.

The cluster layer runs **once**, on the first node's facts, from the
workstation, against the `necropolis` context.

**Done by hand before the first run:**

1. Router DNS: `hubble.lan`, `awx.lan` and `vault.lan` → the `.90` address.
   `grafana.lan` → a CNAME to `phantom.lan` (the estate's one Grafana, at
   `:30300`).
2. After the run that creates the CA: trust it in the macOS System keychain,
   once. The playbook prints the `security add-trusted-cert` command with
   the path. Firefox keeps its own store and needs it imported separately.

### cilium, extended

The existing role, with four capabilities that default **off**, so revenant's
single-node install is unchanged:

- **Gateway API CRDs** (v1.6.1, the version Cilium 1.20 documents) applied
  server-side *before* the chart. Cilium's Gateway controller starts only if
  the CRDs exist when the operator does; installed afterwards, a Gateway is
  accepted and programmed by nothing.
- **L2 announcements**, with a raised client rate limit (qps 50, burst 100):
  every announced Service holds a Lease, and the upstream defaults produce
  stalls that look like flapping.
- **LoadBalancer pools** from `lb_pools`, declared as **host offsets** (`90`,
  `91–99`) within the nodes' /24, which is a gathered fact, so no routable
  address is committed, the same rule that keeps `ansible_host` out of
  inventory. The role asserts a single /24 and that no pool address is a node
  or the VIP. A labelled pool serves only Services carrying its label; an
  unlabelled one only Services without it, so the pools partition every
  Service and nothing but the Gateway can take `.90`.
- **The L2 policy** names every node's LAN interface from facts, and carries
  **no nodeSelector**: Cilium's upstream example excludes control-plane nodes,
  and every node here is one. Copied verbatim it selects nothing, and Services
  show an EXTERNAL-IP that nothing answers ARP for.

Also generalised: the Ready wait and gate cover every node of `cluster_hosts`,
not only the host the layer runs on; the operator's replica count moved out of
`charts/values/cilium.yaml` into the role (2 here, 1 on a single node).

Cilium's own metrics stay off, as on revenant, so the kube-prometheus-stack
CRDs are **not** needed ahead of it. That ordering is needed only when
Cilium's ServiceMonitors are enabled.

### longhorn

Chart 1.12.1 on the disks phase 1 mounted: 3 replicas, the default
StorageClass, data path `/var/lib/longhorn`. These are the chart's defaults, stated so
a chart that changes its mind cannot change the cluster's. The install waits
until every node's disk is schedulable. The gate also checks **where** each
disk is: a disk registered at the right path on the *root* filesystem is
schedulable too, and fills the boot drive. The Longhorn UI is not published:
it has no authentication and can delete volumes.

### cert_manager

- **The root CA on the workstation**, in `cluster_ca_dir`
  (outside the repository, a cross-role contract): RSA 4096,
  ten years, generated once and **never regenerated** by the role, because a new root
  silently invalidates every browser that trusts the old one.
- cert-manager v1.21.2 with its CRDs, kept on uninstall (deleting them would
  delete every Certificate).
- The CA imported as a TLS Secret in cert-manager's own namespace (a
  ClusterIssuer reads its Secret from there, the commonest way one stays not
  Ready), and the `necropolis-ca` ClusterIssuer.
- Gates: the CA is a CA with a year left; the ClusterIssuer is Ready.

### gateway

One Gateway (`gateway/necropolis`, class `cilium`) on `.90`, requested through
`spec.addresses`, with the pool label set through `spec.infrastructure` so its
generated Service matches the `gateway` pool. HTTPS terminates there with a
90-day certificate from `necropolis-ca`, written as an explicit Certificate
rather than relying on cert-manager's opt-in gateway-shim. HTTP only
redirects. One HTTPRoute per entry in `gateway_routes`, living beside its
Service: `hubble.lan`, `awx.lan` and `vault.lan`. Every hostname shares the one
address, and the Gateway chooses the route by the requested hostname.

The role creates each route's namespace before the route. A route's Service
usually comes from a role later in the cluster layer, whose namespace would not
yet exist on a fresh build. Helm installs into an existing namespace without
complaint, so the later role is unaffected.

The last gate is end to end from the workstation: each hostname resolves to
`.90`, and HTTPS to it returns 200 while verifying against the workstation CA:
DNS, L2 announcement, the Gateway, the certificate chain and the route,
proved together.

## Phase 4: observability

`roles/observability`, last in the cluster layer, with no role change: its
`kubeadm_clusters` branch scrapes the scheduler, the controller manager and
etcd on the ports phase 2 bound off-loopback, and leaves kube-proxy off
because Cilium replaced it.

Prometheus remote-writes to phantom's VictoriaMetrics through `metrics.lan`,
the URL the role builds for every cluster outside `metrics_stores`. The series
carry `cluster="necropolis"`, and phantom's Grafana shows them under that
label with no change on phantom.

Set in `group_vars/necropolis.yml`:

- `prometheus_external_labels: {cluster: necropolis}`. `necropolis` is nested
  into `observability_hosts`, so preflight asserts the label before anything
  is installed.
- Grafana, Jaeger and the discovery contract off, as on every host but
  phantom.
- `prometheus_storage_class: longhorn`. The role's default, `local-path`,
  exists only on k3s. The 20Gi scrape buffer is replicated three times by the
  default class.

The gates are the role's own: one Prometheus StatefulSet on a persistent
volume, the live retention, cluster label and remote-write target, and
`/-/ready` answering on the Prometheus NodePort.

## clabernetes (controller only)

The controller and its host prerequisites, and no topology. Topologies belong
to the repository that varies them, and none is deployed here.

`necropolis` is nested into `clabernetes_hosts`. `clabernetes_host` joins the
host layer on all three nodes and `clabernetes` ends the cluster layer.

**Host layer.** The five kernel modules ship in the nodes' generic kernel, so
`clabernetes_modules_extra_package` stays empty. `base_sysctl` is restated in
`group_vars/necropolis.yml` with the inotify ceiling at 32768, as on revenant:
the role's gate requires headroom for 14 cEOS nodes at 1250 instances each,
and the estate default of 8192 fails it. Every node carries the full ceiling,
because nothing pins how a topology spreads across them.

**Cluster layer.** `roles/clabernetes` was written for k3s, and two of its
settings name where the node's containerd lives. Both are now discriminated on
`kubeadm_clusters` membership in the role's defaults:

| Setting           | k3s                                                 | kubeadm                           |
| ----------------- | --------------------------------------------------- | --------------------------------- |
| `criSockOverride` | `/run/k3s/containerd/containerd.sock`               | `/run/containerd/containerd.sock` |
| `criHostsDir`     | `/var/lib/rancher/k3s/agent/etc/containerd/certs.d` | `/etc/containerd/certs.d`         |

The role passes them, and the manager's replica count, as chart values.
`charts/values/clabernetes.yaml` keeps only what every cluster shares. The
gate compares the live Config against the same variables, so it checks the
kubeadm paths here and the k3s paths on revenant.

One manager replica, as on revenant. The controller acts only while a topology
is applied or changed, so standbys buy nothing a lab would notice.

`socketLB.hostNamespaceOnly`, which clabernetes' VXLAN links depend on, is in
the shared `charts/values/cilium.yaml` and is already live here.

**Not yet known.** A topology on necropolis is spread across nodes, so its
links cross the pod network between machines. The lab-link MTU that
ceos-diag-agent measured on a single node is not established for that path.

## AWX

`roles/awx`, last in the cluster layer: after `longhorn`, because its database
claims a volume, and after `gateway`, because the Gateway is its only way in.
AWX is the upstream of Ansible Automation Platform and has the same model of
projects, inventories, credentials and job templates, behind the same REST API.

**Installed through its operator, in two steps.** The role installs the AWX
Operator chart, then applies one `AWX` resource rendered from
`templates/awx.yaml.j2`. The operator builds everything else from that
resource: Postgres, the web and task Deployments, their Services and Secrets,
and the database migrations. Helm's wait covers only the operator's own pod, so
the role then waits for the resource's `Successful` condition, which the
operator sets when a reconcile completes. A first build takes several minutes.

**Postgres runs on Longhorn and needs `postgres_data_volume_init`.** The
operator's Postgres image runs as a non-root user, and a new Longhorn volume is
mounted owned by root. Without the setting, Postgres cannot create its data
directory and crash-loops, and the web and task pods wait on it indefinitely.
The setting adds an init container that hands the volume to the Postgres user.
The storage class is named in the resource rather than left to the cluster
default. The Postgres major version, and with it the claim's name, is the one
the operator release ships.

**No ingress of its own.** The Service is `ClusterIP`, and the operator's
`ingress_type` and `hostname` are left unset. `awx.lan` is an entry in
`gateway_routes`, so AWX gets the cluster certificate and the HTTP redirect
like every other UI.

**The admin password stays in the cluster.** The operator generates it into the
`awx-admin-password` Secret at first install. Nothing in the repository
carries it.

The gates:

- the `AWX` resource reports `Successful`, which covers every workload the
  operator built, where a Deployment's replica count could be healthy while a
  migration failed
- the Postgres claim is `Bound`, on the storage class the role names
- `https://awx.lan/api/v2/ping/` answers 200 while verifying against the
  workstation CA, and reports a `controlplane` instance group with capacity
  above zero, which proves the web pod reached the database and the task pod
  registered. The `default` instance group is not checked: it is a container
  group that starts a pod per job, so it always reports zero capacity.

## Vault

`roles/vault`, after `gateway`, because the role initializes and unseals
Vault through its route. It holds the secrets AWX's jobs use and nothing else;
`docs/ARCHITECTURE.md` records why no playbook reads from it.

**One server on Raft storage.** Raft is Vault's integrated storage, so no
external database is needed, and it supports snapshots. One replica, because
Longhorn already keeps three copies of the volume, and every additional server
is one more to unseal after each power cut. Losing a node costs a minute or two
while the pod moves and is unsealed again. The Raft configuration carries a
`retry_join` to `vault-0`, so raising `vault_replicas` adds members to the
existing cluster rather than rebuilding it. The chart's agent injector is off:
AWX reads Vault's API, and nothing needs secrets injected into pods.

**TLS ends at the Gateway.** `vault.lan` is an entry in `gateway_routes`, like
the other UIs, and Vault's listener is plain HTTP inside the cluster. The route
targets the `vault` Service, which publishes pods that are not Ready, so the API
and UI answer while Vault is sealed. The `vault-active` Service would go dark at
exactly the moment it was needed.

**Helm does not wait.** The chart's readiness probe is `vault status`, which
fails while Vault is sealed, so a Helm wait would always time out. The role
waits for the pods to be Running instead.

**Initialization and unsealing go through Vault's HTTP API**, on endpoints that
need no token:

1. `/v1/sys/seal-status` reports whether Vault is initialized and sealed.
2. If Vault is uninitialized and the init file already exists, the role stops.
   That combination means Vault's storage was lost or replaced, and
   initializing would overwrite the only key to the old data.
3. Otherwise an uninitialized Vault is initialized through `/v1/sys/init` with
   one key share, and the response is written straight to the init file on the
   workstation, mode 0600 in a 0700 directory. The response is shown once.
4. A sealed Vault is unsealed through `/v1/sys/unseal`, with the key read from
   that file. A Vault initialized in the same run is still sealed, so this
   runs then too, and recovery after a power cut is a run of the playbook.

The key and token are sent and received with `no_log`, so neither appears in
the run's output. Using the API rather than `vault` commands in the pod keeps
the key out of process arguments as well.

**AWX is the only client, through Kubernetes auth.** Once Vault is unsealed,
`tasks/configure.yml` sets up three things, reading each first and writing it
only when it is missing or different:

- a KV v2 engine at `secret/`. An existing v1 engine there stops the run,
  because the policy below would apply to it and never match.
- an `awx` policy granting `read` on `secret/data/awx/*` and nothing else. KV v2
  serves values under `data/`, so that is the path granted.
- a `kubernetes` auth method with an `awx` role, bound to the `awx` service
  account in the `awx` namespace. The operator names that account after the
  `AWX` object.

AWX logs in with the token Kubernetes mounts into its pods, so no login secret
exists to store, copy or leak. No reviewer token is configured: Vault calls
TokenReview with its own service account, which the chart binds to
`system:auth-delegator`. The role's audience is kubeadm's service account
issuer, the default audience of a mounted token. AWX's tokens last 20 minutes,
capped at an hour by the mount. AWX logs in again at each job launch, so a
short lifetime costs nothing.

**Configuration does not use the root token directly.** `uri` logs its request
headers at `-vvv`, so a root token in a header would reach the terminal of
anyone debugging a run. The root token is used once, with `no_log`, to issue a
child token that expires after five minutes. That token is revoked when
configuration ends, even if a step fails.

The gates:

- `/v1/sys/health` returns 200 through the Gateway, verifying against the
  workstation CA, which means initialized, unsealed and active. The failure
  names the state the status code encodes: 429 standby, 501 uninitialized,
  503 sealed
- every server pod is Ready, which the readiness probe allows only once
  unsealed
- every data volume is Bound on the storage class the role names
- the init file exists with mode 0600, because without it Vault cannot be
  unsealed after its next restart
- a token issued to AWX's service account logs in through the `awx` role, and
  `sys/capabilities-self` reports `read` on `secret/data/awx/` and `deny` on
  another KV path and on AWX's own policy. The token is requested without an
  audience, so a mismatch with the pods' mounted tokens fails here rather than
  at a job launch.
- the `default` service account in the same namespace is refused, which
  proves the role is bound to the account and not just to the namespace

## Pins

Chosen against upstream release lists and compatibility tables.
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
| AWX Operator | chart 3.2.1            | Latest. Operator 2.19.1, which deploys AWX 24.6.1.                       | `group_vars/all.yml` |
| Vault        | chart 0.34.1           | Latest. Deploys Vault 2.0.4.                                             | `group_vars/all.yml` |

Ubuntu 26.04's own containerd package is still not used, for the SIGSEGV
recorded in roles/containerd. That finding comes from virtual machines and was
not re-tested on bare metal; the upstream tarball is needed for the pin
regardless.
