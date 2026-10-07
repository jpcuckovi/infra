# infra

Ansible provisioning for a six-machine home lab: three single-node k3s hosts
and a three-node bare-metal kubeadm cluster. Hosts are inventory entries,
capabilities are roles, and every capability carries its own verification.

There are 24 roles, and 22 of them have a `tasks/verify.yml` that checks the
result through the system's own interface.

## What it builds

| Host                            | What it is for                                                                     | State                       |
| ------------------------------- | ---------------------------------------------------------------------------------- | --------------------------- |
| `phantom`                       | Container registry, observability and long-term metrics. The durable machine       | Managed                     |
| `revenant`                      | GPU work, network labs under clabernetes, Kubernetes failure injection. Cilium CNI | Managed. Reloaded routinely |
| `wraith`                        | A single-node k3s running the control side of a zero-trust lab                     | Managed                     |
| `spectre`, `cadaver`, `banshee` | `necropolis`: one kubeadm HA cluster on three identical mini PCs                   | Built and running           |

`phantom` is built first because it is the dependency root: every other host
pulls images through its registry and writes metrics to it. `wraith` is built
last because it depends on nothing.

`necropolis` is three control-plane nodes with stacked etcd, a kube-vip
address for the API, Cilium replacing kube-proxy, Longhorn on a dedicated disk
per node, cert-manager and a Gateway. All three nodes are schedulable. One UPS
feeds the cluster: the node it is cabled to serves it with NUT and the others
shut down on its word.

## Why it exists

Bringup used to be organised by machine. The measurable result was five copies
of one kubeconfig script across five repositories and three independent
implementations of the same stepped, idempotent bringup, with a fourth about to
be written. The unit of reuse had been the box. Here it is the capability.

## How it is organised

```
inventory/           hosts.yml, group_vars/, host_vars/    what differs per machine
playbooks/<host>/    main.yml, verify.yml                  what each machine composes
playbooks/_layers.yml                                      how the two layers run
roles/<capability>/  tasks/main.yml, tasks/verify.yml      how each capability is built
charts/values/       static Helm values                    workload requirements
docs/ARCHITECTURE.md                                       decisions, with rejected alternatives
docs/OPERATIONS.md                                         prerequisites and how to run a target
docs/necropolis.md                                         how the kubeadm cluster is built, phase by phase
```

**Roles are named for capabilities.** A host playbook lists the roles that
machine composes, in dependency order, and nothing else.

**Two layers, stated once.** The host layer runs over SSH as root on every
machine in the target. The cluster layer runs on the workstation against the
cluster's API, once per cluster. `playbooks/_layers.yml` holds the mechanics of
both, and asserts the ordering constraints between roles so they are not
restated as comments in every host playbook.

| Group                | Roles                                                                             |
| -------------------- | --------------------------------------------------------------------------------- |
| Host base            | `preflight`, `base`, `wired_link`, `wifi_link`, `nut`                             |
| Kubernetes           | `containerd`, `k3s_server`, `kubeadm_node`, `kubeadm_control_plane`, `kubeconfig` |
| Network and storage  | `cilium`, `longhorn_node`, `longhorn`, `cert_manager`, `gateway`                  |
| GPU                  | `nvidia_runtime`, `nvidia_device_plugin`                                          |
| Registry             | `registry`, `registry_mirror`                                                     |
| Observability        | `observability`, `victoriametrics`                                                |
| Network lab runtimes | `containerlab`, `clabernetes_host`, `clabernetes`                                 |

## Verification

**Each role owns its gates.** A role's `tasks/verify.yml` holds its checks and a
host's `verify.yml` lists the roles to check. An assertion copied per host is an
assertion that drifts per host.

**A gate asks the system, not the service manager.** An active unit proves a
process started. The NUT gate reads the UPS status over NUT's own protocol,
which proves the driver found the device, the server is serving it and the data
is live. The kubeadm gate asks etcd for its member list.

**A failure says what to look at.** Every assert carries a message naming the
likely cause and the command to run next.

**The acceptance gate is a second run reporting `changed=0`.** That is the
idempotency claim, demonstrated on every host.

## Check mode is kept trustworthy

Tasks use native modules. `command` and `shell` tasks skip under `--check` and
report nothing, so a playbook built from them produces a dry run that is
confidently wrong. Read-only probes are marked `check_mode: false` so the
asserts that consume them still have something to read.

`docs/ARCHITECTURE.md` also records what Ansible is worse at than the shell
scripts it replaced: long-running commands stop streaming their output, and
error messages are worse by default.

## No address and no secret is committed

**Inventory hostnames are ssh_config aliases.** `ansible_host` is absent
everywhere, so no address, username, port or key path is in the repository.

**Addresses are derived.** LoadBalancer pools are declared as host offsets and
combined with the subnet each node reports about itself.

**Secrets are generated where they are used.** A credential is created on its
host at first install and read back from that host on later runs, or generated
on the workstation outside the repository when several hosts must share it.

**Function lives in DNS.** Services are reached by role names such as
`registry.lan`, which point at whichever host serves them, so a service can move
without an image being re-tagged or a consumer edited.

## Where to start reading

| File                                         | Why                                                                      |
| -------------------------------------------- | ------------------------------------------------------------------------ |
| `playbooks/_layers.yml`                      | The two-layer model and the ordering assertions                          |
| `playbooks/necropolis/main.yml`              | What a cluster composes, with the reason for each role's position        |
| `roles/kubeadm_control_plane/tasks/main.yml` | Forming or joining an HA control plane safely, including under `--limit` |
| `roles/nut/`                                 | One role in three modes, with a credential shared across hosts           |
| `roles/nut/tasks/verify.yml`                 | Gates that read through the protocol                                     |
| `docs/ARCHITECTURE.md`                       | The decisions, each with what was rejected                               |

`docs/OPERATIONS.md` covers the prerequisites and how to run a target, and
`docs/necropolis.md` walks through the cluster build phase by phase.
