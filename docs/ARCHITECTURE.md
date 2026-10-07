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

## revenant's CNI

**revenant runs Cilium, not the flannel k3s bundles.** revenant holds the
installation role in ztlab, a zero-trust lab, and ztlab's acceptance tests depend
on network policy that can be observed as well as enforced: Hubble records each
dropped flow and the policy that dropped it. It also gives revenant the same
dataplane as necropolis, which runs Cilium without kube-proxy.

The cost is install-time. `--flannel-backend=none`, `--disable-network-policy`
and `--disable-kube-proxy` are `k3s_server_args`, which are declared rather than
reconciled (see "What is reconciled, and what is only declared"), so adopting
them is a reload, which is cheap on revenant by design. `roles/cilium` refuses
to install onto a node that flannel still manages, rather than running two CNIs.

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
durable machine means a manually-obtained image survives every revenant reload.

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

## Metrics

Local Prometheus is a scrape buffer with short retention on every host; history
lives in one VictoriaMetrics. The decisive property is that **data leaves the
machine that produced it**. revenant is reloaded routinely, and history kept on
revenant dies with it.

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

## Secrets

**There is no secret store, because no secret is committed.**

Host configuration is paths and version pins. The registry has no authentication.
cEOS images are fetched by hand and copied over, so no credential is stored.
Each cluster's root CA is generated on the workstation, outside every repository
and every cluster, so that it survives any rebuild and is trusted once. Its key
is copied into a cluster Secret because cert-manager has to sign with it, which
is a lab trade-off and not production key management. Grafana's password and the
k3s token are generated at install and read back on demand. NUT's monitoring
password follows the same rule: generated on the UPS host at first install, read
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

Revisit when a real credential appears, such as registry authentication if the
registry is ever reachable beyond the LAN. Vault on a machine this repository
does *not* own remains the right answer for workload secrets at that point.

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
