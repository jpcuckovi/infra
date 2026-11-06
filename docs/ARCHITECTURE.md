# Architecture

Decisions, with the alternatives that were rejected and why. A decision is
recorded here once it has been adopted. A value still under test is an
experiment and belongs in a run record, not in this file.

## Why this repository exists

Bringup was organized by machine and tangled with the experiments running on it.
The measurable result:

- `kubeconfig.sh` existed in five repositories: two byte-identical, three forks,
  all carrying the same doctrine and the same anecdote
- three independent `bringup.sh` + `ops/scripts/lib/` implementations of the
  same stepped, idempotent, dry-runnable pattern, each with its own `verify.sh`
- a fourth copy of the k3s/NVIDIA/registry install was about to be written

None of that was accidental. `k8s-aio/docs/ARCHITECTURE.md` records that its
bringup "follows the structure established in `gpu-bench`" and its
`kubeconfig.sh` "adapts `k8s-diag-agent`'s". The duplication was deliberate,
attributed, and copied forward because there was nowhere shared to put it.

## Naming

**Repositories are named for what they build. Machines are named for nothing.**

A hostname in a repository name asserts that capabilities belong to boxes.
Revenant is the counterexample: the same machine is either a standalone k3s
server or a bare-metal kubeadm worker, and switching modes is an OS reload. Any
function-derived name for it is wrong half the time; an arbitrary one is correct
in both modes.

Machine names are therefore stable and arbitrary, drawn from one word pool.
Function lives in two other places:

| Layer            | Carries                                              | Example          |
| ---------------- | ---------------------------------------------------- | ---------------- |
| Machine name     | Identity only. Changes when the hardware is retired. | `phantom`        |
| Group membership | Which capabilities apply.                            | `registry_hosts` |
| DNS role alias   | Where a service currently lives.                     | `registry.lan`   |

`.lan` and not `.local`: RFC 6762 reserves `.local` for mDNS, so a `.local`
unicast name resolves through mDNSResponder on macOS and misbehaves.

**Rejected:** function-descriptive machine names (`pi4-k3s`, `netlab`). They
encode hardware model, Kubernetes distribution, or job, and each of those can
change without the machine changing.

## Role design

**Roles are named for capabilities, never for hosts.**

A `phantom_bringup` role makes the machine the unit of reuse. Revenant then gets
`revenant_bringup`, spectre gets `spectre_bringup`, and the three-copies problem
is reproduced with better indentation. The overlap is real: every host needs
base packages and observability, and several need k3s and a registry mirror.

**The fork test: does the task list change, or only the values?**

Only the values change → one parameterised role. Half the tasks would need a
`when:` → a separate role.

Phantom and revenant pass this easily: the same k3s install procedure with
different `INSTALL_K3S_EXEC` arguments and a different architecture. The
necropolis nodes fail it decisively: `kubeadm init`, a kube-vip static pod and
control-plane joins are a different procedure, so they get
`kubeadm_control_plane` rather than becoming a `k3s_server` variant.

**Discriminate in this order:**

1. **Variables**: `defaults/main.yml` for the default, `host_vars/` for the deviation
2. **Facts**: anything the machine can report rather than declare;
   `ansible_architecture` covers arm64 versus amd64
3. **Groups**: capability composition, carrying `group_vars`
4. **A separate role**: only when the procedure genuinely differs

**Never `when: inventory_hostname == …` inside a role.** It inverts the
dependency: the role begins to know which machines exist, so adding a host means
editing every role rather than adding one `host_vars` file. It is also
undiscoverable, because what a host receives cannot be read off anything short
of every role, and it makes `--limit` misleading.

Work genuinely specific to one playbook goes inline in `playbooks/<host>/*.yml`,
where it is visible at the call site, rather than into a nested `roles/`
directory where it has to be found.

## Variables that cross roles

**Values one role writes and another reads live in `group_vars/all.yml`.**
`playbooks/_layers.yml` includes roles dynamically, which scopes each role's
defaults to that role. A static `roles:` list had made cross-role reads work by
accident, and a refactor that broke them looked fine wherever the same name also
happened to be set in `host_vars`. `public: true` shares defaults only with roles
included later, so role order matters for variables as well as side effects.
Roles keep their own defaults for the same names, so each still reads on its own.

**A group value must be right for every member because of what it is.** A value
that merely suits the hosts built so far belongs in `host_vars`. The rule came
from a `max-pods` setting copied from one host's build into a group that also
held a Pi running no labs.

**A DNS alias exists only where nothing regenerates the reference.** The
observability role rewrites its discovery files on every run, so an address there
corrects itself and needs no alias. A consumer configured once and never
regenerated fails silently when the service moves, and only telemetry going quiet
reveals it. That is why there is a `traces.lan` and no Prometheus alias.

## Two layers per target

Each target runs a host layer over SSH and a cluster layer from the workstation.
The cluster layer targets `{{ target }}[0]` with a local connection rather than
`localhost`: the `[0]` installs each chart once per cluster, not once per node,
and keeping the target's name keeps its `host_vars`, so a variable means the
same thing in both layers. It gathers no facts, so the workstation's facts are
never stored under the target's name, and it pins the Python interpreter to the
one running Ansible. The interpreter recorded over SSH is a path on the target;
used locally it fails with rc 127, which a tolerant probe then misreports as a
missing tool.

The ordering asserts pick the two roles out of the list and reject the one wrong
arrangement, rather than comparing list positions, so a host that composes only
one of the pair needs no guard.

## Topology hosts, and why there are two kinds

**`containerlab_hosts` and `clabernetes_hosts` are separate groups, not one wider
one.** Both run network topologies. `roles/containerlab` drives containerlab
directly, wiring veth pairs between containers with no Kubernetes involved.
`roles/clabernetes` installs a controller, and a topology is a custom resource
that the controller schedules as pods. The fork test decides it: only the kernel
modules are shared, and the runtime, the lifecycle, the reachable transports and
the failure modes all differ. Half the tasks would need a `when:`.

The host split is forced rather than chosen. cEOS images are amd64 and wraith is
a Pi, so the cEOS topologies run on revenant under clabernetes.

**`roles/containerlab` is kept although no playbook composes it.** wraith stays
in `containerlab_hosts` because it remains eligible, and the role holds the
kernel modules, the runtime and the pin that the next directly driven topology
host needs. A role that is not composed is not converged.

**The clabernetes chart is pinned harder than the other pins.** Every version in
`group_vars/all.yml` is deliberate, but this one guards against something other
than drift: the launcher runtime the topologies are written against has already
been deleted upstream, and its replacement is explicitly breaking. An unpinned
upgrade would not update a controller, it would change the execution model
underneath a converged lab. `roles/clabernetes` also refuses to install alongside
the pre-0.7 `clabernetes.containerlab.dev` API group, because the rename in 0.7.0
has no upgrade path and the two CRDs can coexist while the controller reconciles
only one, so the failure mode is a topology that applies cleanly and is never
acted upon.

Several clabernetes settings exist because the defaults fail quietly:

- **The chart installs without `--wait`.** It ships its startup configuration as a
  ConfigMap that the manager reads and then deletes, so waiting for the release
  waits for something designed to disappear, and a healthy install is marked
  failed. The role waits for the manager and the merged configuration instead.
- **`mergeMode: overwrite`.** Under the default merge, a changed value reaches the
  startup ConfigMap and is then ignored by the live configuration. A verify gate
  checks that the values actually landed.
- **Image pulls go through the node's containerd** (`imagePullThroughMode:
  always`, plus the CRI socket and hosts-directory overrides k3s needs), because
  that containerd already knows `registry.lan`. A fallback to direct pulls would
  work for public images and hide the broken path until a cEOS pull fails.
- **One manager replica.** The controller acts only when a topology changes, so
  standby replicas cost memory and protect nothing a lab would notice.

A topology host also needs kernel modules that fail silently when missing.
Without `sch_netem`, `tc` accepts a netem qdisc and impairs nothing, so a fault
scenario runs, the agent reports a healthy network, and the run is scored as the
agent's miss. Modules are made persistent and checked under `/sys/module`, which
also counts built-in modules. The inotify ceiling is sized for two labs at once,
since cEOS needs about 1,250 instances per node and too low a ceiling converges a
lab partially rather than failing it.

## revenant's CNI

**revenant runs Cilium, not the flannel k3s bundles.** revenant holds the
installation role in ztlab, a zero-trust lab, and ztlab's acceptance tests depend
on network policy that can be observed as well as enforced: Hubble records each
dropped flow and the policy that dropped it. It also gives revenant the same
dataplane as necropolis, which runs Cilium without kube-proxy.

The cost is install-time. `--flannel-backend=none`, `--disable-network-policy`
and `--disable-kube-proxy` are `k3s_server_args`, which are declared rather than
reconciled (see "What is reconciled, and what is only declared"), so adopting
them takes an OS reload. `roles/cilium` refuses to install onto a node that
flannel still manages, rather than running two CNIs.

Three consequences carry into the layers:

- **Cilium is the first cluster role**, asserted in `playbooks/_layers.yml`.
  Until a CNI exists no pod receives an address, so a chart installed ahead of it
  times out on pods that cannot start. The same file asserts that a host
  installing k3s without flannel composes a CNI at all.
- **`k3s_server` waits for the node to register, not to become Ready**, when k3s
  brings no CNI. A node without a pod network stays NotReady by design;
  `roles/cilium` waits for Ready once the dataplane is up.
- **Socket-level load balancing is confined to the host namespace**
  (`socketLB.hostNamespaceOnly`), so pod traffic to a Service is translated per
  packet at the pod's veth. Kube-proxy replacement otherwise translates a
  ClusterIP only when a process sends through a socket, and clabernetes' links
  are kernel VXLAN devices inside launcher pods addressed to each peer's `-vx`
  ClusterIP. Their packets never pass a socket hook, so they left untranslated,
  were masqueraded out of the node's uplink, and no lab link carried traffic.
  The evidence was conntrack reporting `BackendID=0` on every tunnel flow,
  unchanged across a launcher restart. Every clabernetes topology depends on
  these links. The cost is a per-packet service lookup for pod traffic. ztlab's
  pod-to-Service traffic takes that path too, which should be transparent; its
  acceptance tests are what confirm it.

`k8sServiceHost` is `127.0.0.1`. With kube-proxy gone, Cilium cannot reach the
API through the `kubernetes` Service, which kube-proxy would have programmed. On
a single-node k3s the agent and operator run on the host network beside the API
server, so loopback reaches it and keeps reaching it when DHCP moves the node. A
second node would need an address every node can reach.

**Rejected: flannel with k3s's bundled policy controller.** It enforces the same
standard NetworkPolicy objects and records nothing about what it denies.

**Rejected: Cilium's SPIFFE mutual authentication.** ztlab's Envoy sidecars and
SPIRE own workload identity. Two enforcement layers keyed on the same identities
would leave no clear owner of a denied connection.

## What the registry is for

**The registry holds images that cannot be obtained again, and nothing else.**

`host_vars/phantom.yml` gives the reason it exists at all: cEOS images are fetched
by hand from Arista and cannot be re-pulled from anywhere, so hosting them on the
durable machine means a manually-obtained image survives the loss of any lab host.

The converse is the policy. An image that upstream will serve again on request
has no claim on the registry, and copying one in creates a second place the same
image lives with nothing to say which is authoritative. The netshoot hosts in
the cEOS lab are pulled from Docker Hub for that reason.

Upstream images are pinned by tag rather than mirrored. A lab whose images change
silently between two runs is not reproducible, which is the property a
fault-injection lab cannot do without. That is an argument for pinning, not for
copying.

Revisit if rate limits or an upstream withdrawal ever make a pinned tag
unobtainable. At that point the image has genuinely become one with no other
source, and it belongs in the registry by the same rule that put cEOS there.

**The registry serves over a wired link, because the link bounds it and nothing
it holds does.** Measured while phantom served over wireless: 302 MB/s reading
its own blobs from disk, and about 300 KB/s to any consumer across the network,
which makes a 1 GiB pull a multi-hour operation. phantom is therefore in
`wired_hosts`, and `roles/wired_link` disables Energy-Efficient Ethernet there,
which stalled interactive traffic once the cable carried the address.

## Ordering

Two constraints live in a static role list rather than being derived per host,
because ordering is a property of the dependency graph and not of a host's
wishes.

**Registry mirror before k3s.** k3s reads `/etc/rancher/k3s/registries.yaml` once,
at start. This is the constraint `gpu-bench/ops/scripts/lib/install-registry.sh:136`
got wrong: it wrote the file only when `/etc/rancher/k3s` already existed, but
the registry step runs before k3s is installed, so on a fresh host the branch
never fired and the mirror was silently never configured. Nothing failed; pulls
simply went upstream forever. The fix is creating the directory explicitly.

The constraint names `registry_mirror`, not `registry`. Serving images and knowing
where to pull them from are separate capabilities, and only the second has an
ordering relationship with k3s. The file is what k3s reads, and whether a registry
container is running is not something it consults. They were one role until a host
needed to pull without serving, at which point bundling them meant that host could
not have the mirror config without also starting a second registry on the LAN.

**VictoriaMetrics before observability.** Prometheus should have a remote-write
target before it starts writing, or every install drops its first minutes of
samples and logs a connection error that reads like a misconfiguration.

Both constraints are asserted in `playbooks/_layers.yml` rather than described
in each target's playbook. Four targets times two playbooks is eight places for
a comment to drift out of agreement with the constraint it describes.

## What is reconciled, and what is only declared

Not every value in inventory is enforced against a running machine, and the line
is drawn at what changing it would cost.

**Reconciled: anything a restart can apply.** `registries.yaml` is the example.
The file is rewritten on every run, and when it changes on a host where k3s is
already running the role says so loudly and does nothing else.
`registry_restart_k3s_on_change` defaults to false because restarting k3s
bounces every pod on the node, and doing that as a side effect of an unrelated
run is how a diagnosis in progress gets destroyed. The operator chooses the
moment. The value is still enforced; only the timing is deferred.

**Declared only: install-time configuration.** `k3s_server_args` is passed as
`INSTALL_K3S_EXEC` and read once, when k3s is installed. Changing it configures
the NEXT install and has no effect on a running server. Applying it to an
existing one means `k3s-uninstall.sh` and a rebuild, which destroys the
datastore and every local-path volume on the node.

That is not a gap to be closed. A repository that silently reinstalled a
Kubernetes server because a flag in a YAML file changed would be a worse tool
than one that does not, and no amount of gating makes the operation safe enough
to trigger from a variable. The flags are a record of how the host was built and
how it will be built again.

The consequence is honest and worth stating: a host installed before a change to
`k3s_server_args` keeps the arguments it was installed with, and `verify.yml`
does not detect the difference. `roles/k3s_server/tasks/verify.yml` asserts the
running version against `k3s_version`, because a version mismatch means the pin
was never applied to anything, and deliberately stops there.

## Pins are enforced, not declared

**A pin that cannot be contradicted is not a pin.** Both the k3s and the NVIDIA
driver pins once existed without ever taking effect: the install was guarded by
`creates:` or by a check that some version was present, so it skipped on any
host that already had one, and verification checked only that a binary existed.
A pin now has three parts: the install compares the installed version, the
verify gate checks for equality, and the packages are held so unattended upgrades
cannot move them.

Only what this repository installs is pinned. helm is a workstation prerequisite
that preflight checks and nothing installs, so a pinned helm version would be a
number nothing could keep.

**The NVIDIA driver follows its branch; the toolkit is held.** The branch is part
of the driver's package name, so changing branch is a deliberate edit, but within
it the driver takes Ubuntu's fixes along with the kernels they are built for. A
held driver on a long-lived host can be left with no module for a new kernel, and
the GPU then disappears at the next reboot. `nvidia_driver_held` restores the hold
for an explicit version, and the role refuses an explicit version without it. The
container toolkit has no kernel half, so it installs at `latest` and is held there.
Only metapackages are held, because the rest depend on their exact versions and
apt holds the whole set back. Verification checks the hold in both directions.

**kubeadm nodes run containerd from the upstream release**, checksum-verified with
its own systemd unit, because the Ubuntu 26.04 package crashes on any invocation.
The installed version is read from the binary itself.

## A second run must report changed=0

The acceptance gate is a converge followed by a second run that reports
`changed=0`. Every role is written to keep that claim honest: temporary files and
apt cache refreshes report unchanged, the kubeconfig merge reports a change only
when the file is really replaced, and the `helm-diff` plugin is a prerequisite,
because without it every chart task reports `changed` and the gate can never pass.

## Forming the kubeadm cluster

necropolis is three control-plane nodes behind a kube-vip address. Its formation
has several constraints that are easy to get wrong:

- **kube-vip cannot reach the API through its own address.** It takes a lease
  through the API to create the VIP, so its kubeconfig points at the local API
  server instead. Since Kubernetes 1.29 `admin.conf` has no permissions until
  init completes, so kube-vip starts on `super-admin.conf` and is switched to
  `admin.conf` straight afterwards. Verification checks the super-admin
  credentials are gone.
- **Init runs in phases.** Certificates and kubeconfigs are generated first, so the
  kube-vip manifest can be rendered from a file that exists, and init then runs
  with those phases skipped.
- **The first host initialises only when the cluster provably does not exist.**
  Position in the play chooses the host, but position alone is unsafe under
  `--limit`, so no host may already be a member and nothing may answer on the
  VIP. A failed init is recovered by hand rather than guessed at.
- **Joins are serial and share one credential set.** Each upload of control-plane
  certificates rotates the key and invalidates the previous one, and etcd adds
  members one at a time, so concurrent joins can stall on quorum.
- **kube-proxy is never installed**, because Cilium replaces it and removing it
  later leaves stale rules behind.
- **Kubelet serving certificates are approved by rule.** A request is approved only
  from a node in the play, and only when every requested name and address belongs
  to that node. Anything else waits for a human.
- **The control-plane taint is removed.** With three machines there is nowhere
  else for workloads to run.
- **kubelet, kubeadm and kubectl are held**, so no single node moves to a new minor
  version on its own. Upgrades go through a pin change and kubeadm's upgrade.

## Storage

**On the single-node k3s hosts, PVCs go through the local-path StorageClass,
never raw `hostPath` mounts in pod specs.** The StorageClass gives a volume a
lifecycle the cluster manages; a raw `hostPath` is invisible to it and does not
survive a node change. The distinction is easy to lose because local-path is
*implemented* with host directories.

**Retention is the bound, not the volume size.** local-path enforces no quota, so
a PVC's declared size is advisory and a process will write past it until the
filesystem fills. Both Prometheus (`retentionSize`) and VictoriaMetrics
(`-retentionPeriod`) are therefore bounded explicitly.

**Rejected:** LVM-backed local PV, which would give real expansion and enforced
quotas, at the cost of partitioning the boot SSD. Longhorn was rejected for these
hosts separately: on a single node it replicates to itself, so the durability
benefit is nil while the control-plane overhead is real on a Pi 4. necropolis
has three nodes with a dedicated disk in each, and runs Longhorn.

**Preparing a Longhorn disk is the only destructive task in the repository, so it
chooses by elimination.** Exactly one non-removable, writable disk with no
partition table, filesystem or children may qualify; anything else stops the run.
A disk with any signature is never wiped, and `force` stays off as a second guard.
The mount uses `nofail`, so a dead disk leaves a node that still boots, and
Longhorn will not fall back to the root disk because it refuses a disk whose
identity no longer matches. XFS matches the boot drives and reserves no space,
where ext4's 5% reservation would hide about 50 GB of each data disk.

Longhorn is necropolis's only StorageClass, so even the disposable Prometheus
buffer gets three replicas. The roughly 60 GiB of raw disk that costs is cheaper
than maintaining a second class.

## Metrics

Local Prometheus is a scrape buffer with short retention on every host; history
lives in one VictoriaMetrics. The decisive property is that **data leaves the
machine that produced it**. History kept on a lab host such as revenant is lost
with that host.

**Rejected: Thanos and Mimir.** Both are built for object storage and horizontal
scale, so both mean running MinIO plus three or four components, which is all
cost and no benefit on one Pi.

**Rejected: Prometheus federation.** It carries only the series explicitly
enumerated in the scrape config, so it silently loses whatever nobody thought to
list. That is the opposite of what a long-term archive is for.

**`external_labels` is required, with no default.** Every Prometheus writing to
the shared store must carry a unique cluster label. Without it, identically-named
series from different clusters merge into a single series. The merge is invisible
in a graph, cannot be separated afterwards, and corrupts every query that spans
the period. The label is asserted before anything is installed and re-checked
against the live configuration afterwards.

**Some components exist once in the estate.** Jaeger, Grafana and the discovery
contract run on the shared services host and are switched off on the others.
Tracing must not compete with the GPU work it observes, a Grafana on a lab host
would be lost with it, and the one Grafana already sees every cluster through
VictoriaMetrics, filtered by the `cluster` label. The discovery contract, the files
that tell other repositories where telemetry endpoints are, has exactly one
writer, because a second would overwrite it on every run and each host's
verification would then fail the other's.

**Verification finds chart workloads by label and counts them.** Generated names
change with the release name and chart values, so a lookup by name once made a
healthy stack look absent. A count of 0 and a count of 2 are different faults:
absent, or two releases writing under one cluster label. Storage is checked
explicitly, because a failed volume template change leaves Prometheus on
`emptyDir` while every other check passes.

Alertmanager is off because nothing pages anyone. The default rules stay, because
recording rules back the stock dashboards and the `ALERTS` series remains
queryable.

## Secrets

**Bringup uses no secret store, because no secret is committed.**

Host configuration is paths and version pins. The registry has no authentication.
cEOS images are fetched by hand and copied over, so no credential is stored.
Each cluster's root CA is generated on the workstation, outside every repository
and every cluster, so that it survives any rebuild and is trusted once. Its key
is copied into a cluster Secret because cert-manager has to sign with it, which
is a lab trade-off and not production key management. Grafana's password, the
k3s token and the AWX admin password are generated at install and read back on
demand. NUT's monitoring password follows the same rule: generated on the UPS
host at first install, read
back from that host's configuration on every run, and never committed. Where one
UPS feeds several hosts, the password the client hosts log in with is shared and
so cannot live on one of them. It is generated on the workstation, beside the
cluster CAs.

Encrypting non-secrets costs readability and adds key management for data that is
not sensitive. The no-real-identifiers rule is satisfied structurally instead:
inventory hostnames are ssh_config aliases, so `ansible_host` is omitted and
nothing routable enters git.

**Rejected: `ansible-vault` for host configuration.** It encrypts whole files, so
diffs become meaningless and merges unresolvable, to protect LAN addresses that
are not confidential.

**Rejected: HashiCorp Vault as the bringup secret store.** The store would run on
a machine this repository provisions, so provisioning would depend on a service
that provisioning creates. A sealed Vault after a power cut would mean nothing
could be built at all.

**Vault on necropolis holds workload secrets only.** AWX's jobs need real
credentials, and AWX reads them from Vault through its credential plugin. No
playbook in this repository reads from Vault, so the dependency above does not
arise: a sealed Vault stops AWX jobs that need a credential, and nothing else.
Every host can still be rebuilt from the workstation.

**Vault's unseal key and root token live on the workstation**, in
`~/.local/share/infra/vault/<context>/init.json`, beside the cluster CAs. The
role writes the file once, when it initializes Vault, and reads the key from it
to unseal on every later run. A Kubernetes Secret beside Vault was rejected:
anyone able to read Secrets in the cluster would hold Vault's root, and Secrets
are stored unencrypted in etcd, on every node's disk, so the seal would protect
nothing. There is one key share, because there is one keyholder.

**Rejected: Vault off the estate.** It would put a cloud dependency and a link
out of the LAN under every job that needs a credential.

## Kubeconfigs

**Every cluster reaches the workstation under a chosen name.** k3s names its
cluster, context and user `default`, and a `default` context is what gets used
when nobody chose one. Every kubeadm cluster names its user `kubernetes-admin`,
so two merged configurations would overwrite each other's credentials. The role
renames everything to the cluster's context name before the file leaves the host,
and removes `current-context`, so it never chooses which cluster the workstation
points at.

The new fragment is listed ahead of the existing configuration when merging,
because kubectl resolves a conflict in favour of the first file. Otherwise a
reloaded host's new certificate authority and address lose to the stale entry,
and the run reports success while changing nothing. A k3s host is addressed by
IP, the only name in its serving certificate; a kubeadm cluster by its endpoint
name, so the workstation follows the VIP if it moves in DNS.

## Certificates, the Gateway and LoadBalancer addresses

Each cluster's root certificate lasts ten years and is never regenerated by the
role, because a new root silently breaks every browser that trusted the old one.
Leaf certificates last 90 days and cert-manager rotates them. Verification warns a
year before the root expires, since replacing it is a planned re-trust and not a
renewal.

HTTPS enters through the Gateway API implemented by Cilium, which is already the
CNI, so no further controller is needed. **Rejected: ingress-nginx**, retired
upstream in March 2026 with no further releases or security fixes.

LoadBalancer pools are stored as host offsets on the nodes' own network, so no
address is committed, and are checked against node and VIP addresses before any
install. The `gateway` pool holds one address and serves only Services carrying
its label, so nothing else can take the Gateway's address. The API VIP is in no
pool, because two components answering ARP for one address is the failure to
avoid. The L2 announcement policy has no node selector, because the usual example
excludes control-plane nodes, which here is every node.

## Network links

Both link roles find interfaces from sysfs rather than by name, because the estate
mixes chipsets and naming schemes.

**Wired links disable Energy-Efficient Ethernet.** On the Pi's NIC, waking from
low-power idle drops a packet. Bulk transfers never idle and look healthy, but
idle interactive traffic has no duplicate acknowledgements to trigger a fast
retransmit, so recovery waits for a backed-off timeout and sessions freeze for
seconds at a time.

**Wireless links disable power save.** A sleeping radio misses reassociation, and
a host once stayed up and healthy but unreachable for hours. The gate checks the
radio's actual state, because a driver reload can undo the setting.

## GPU hosts

**The NVIDIA container toolkit is installed before k3s.** k3s looks for the NVIDIA
runtime on its PATH at start and adds it to the containerd configuration it
generates, which it rewrites from its own template on every restart. Ordering is
therefore the whole integration: the role writes no containerd configuration, and
a missing `nvidia` RuntimeClass fails the run rather than being created, because
creating it would hide a runtime k3s never registered.

The node is labelled directly instead of running Node Feature Discovery. Without a
label the device plugin wants zero pods and helm reports success, and group
membership plus the runtime checks already prove the card exists. Verification
expects an exact GPU count, because a sharing mode that never took effect still
passes a "more than zero" test.

**GPU sharing is off by default.** Two replicas sharing one GPU lost 30-41% of
throughput under time slicing and 24-34% under MPS, at every concurrency tested,
because each replica streams its own copy of the weights. Sharing is node-wide,
lasting, and invisible from a workload's spec, so it is applied only by its own
playbook and the next routine converge deliberately reverts it. Time slicing also
provides no memory isolation, so an oversubscribed workload fails at run time
rather than at scheduling.

**Local LLM serving is opt-in.** `llama_server` is composed only by
`playbooks/revenant/llm.yml`, because a running model holds the only GPU and most
of the node's memory, which would quietly contend with the host's other work if
every converge installed it. No converge removes it either, so its lifetime is
set by that one playbook.

The role uses llama.cpp because the model does not fit in VRAM. Its server splits
a model between GPU and system memory, which a VRAM-only server cannot do, and it
works out that split at load time, so the role pins the context size and leaves
the rest to it.

The weights live on a host path outside `/var/lib`. A `local-path` volume would
tie tens of GiB to the life of a claim and of the cluster that holds it. Each
model is pinned to a commit and per-file SHA-256s, and a file takes its final name
only after its checksum passes.

The model is named on every run and has no default, because a default would let a
rerun swap the served model without anyone asking for it. The gates check the
named model is the one deployed.

The gates ask for a real completion and read the GPU's memory use, because a
server that fell back to the CPU would still load, answer and report healthy. The
clients are on other machines, so the Service is a NodePort. Its API key lives on
the workstation, beside the cluster CAs, and is written into a Secret on every
run: revenant's cluster does not survive a reload, and Open WebUI on necropolis
holds the same key, so a key generated inside the cluster would change under it.
A gate checks that the LAN address refuses a request without the key.

## UPS and shutdown

One UPS feeds several hosts. The host it is cabled to serves it over NUT and the
others watch it as clients, shutting down on its word. `upsd` listens on every
interface because binding a named address races DHCP at boot. The clients' shared
password is kept on the workstation, so a client can be configured while the
server is down and a host this repository does not manage can be given it; that
account can attach but not force a shutdown.

`killpower` stays off. On, it cuts every outlet after shutdown, so hosts return by
themselves when power does, provided firmware powers on after AC loss. Off, hosts
stay down until powered on by hand, which suits outages that flicker on and off.
The setting is verified in both directions, because either mistake only shows up
during a power cut.

## Base operating system

rsyslog is removed because journald is the log store and rsyslog has no
consumer. Its AppArmor profile once looped on revenant and filled the kernel audit
backlog until logins blocked, leaving the host up but unreachable. A loaded
profile outlives its service, so it is unloaded before the package is purged, and
the gate checks the loaded profile rather than the package.

Cgroup support is read from `/sys/fs/cgroup/cgroup.controllers` rather than the
kernel command line, because on a Pi the boot configuration can select a command
line file other than the one usually edited.

## Ansible, and what it is worse at

Native modules throughout, rather than roles that shell out to the scripts they
replaced. This is the only version in which `--check --diff` is trustworthy:
`command` and `shell` tasks skip under check mode and report nothing, so a
playbook built from shell-outs produces a dry run that is confidently wrong.
Every `command:` converted to a real module buys back check-mode fidelity, and
that conversion is the actual payoff of the migration.

Honest regressions against the shell it replaces:

- **Long-running commands stop streaming.** `kubeadm init` printed its progress
  under the shell script; the equivalent task buffers until exit. This is a real
  loss, and it is worst on exactly the longest steps.
- **Error messages are worse by default.** `die "API_VIP is unset: copy
  cluster.env.example"` beats an undefined-variable traceback. The `preflight`
  role and `fail_msg` on every assert exist to claw that back, and are the first
  thing that will be quietly dropped under time pressure.
- **Registered-variable chains break under `--check`**, because the task that
  registers them was skipped. Read-only probes are marked `check_mode: false` so
  the asserts consuming them still have something to read.

What is better, and why the trade is worth taking: inventory and `host_vars`,
`--limit` and `--tags`, handlers that fire once rather than being open-coded,
`reboot` with a wait built in, and a machine-checkable idempotency claim in the
form of a second run reporting `changed=0`.
