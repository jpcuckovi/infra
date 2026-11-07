# Operations

How to run this repository against the estate. README.md and ARCHITECTURE.md
say what the repository builds and why it is built this way.

## Workstation

The workstation side of the prerequisites is rebuilt by one script. It is
idempotent, and `--recreate` deletes and rebuilds `~/.venv` when the venv is
corrupt rather than merely incomplete.

```bash
./scripts/bootstrap-workstation.sh
./scripts/bootstrap-workstation.sh --recreate
```

It creates `~/.venv`, installs the three pinned Python dependencies into it, and
installs the `helm-diff` plugin. It deliberately does not install `helm` or
`kubectl`, which come from a package manager this repository has no business
driving, and checks for them instead. Its success criterion is that
`roles/preflight/tasks/controller.yml` would pass, which it re-checks before
reporting ready.

## Prerequisites

- `~/.venv` with ansible-core, and `kubernetes` + `jmespath` importable from the
  **same interpreter**. `kubernetes.core` imports from whichever Python Ansible
  runs under, not from `PATH`
- `helm` and `kubectl` on `PATH`
- the `helm-diff` plugin. `kubernetes.core.helm` cannot distinguish a no-op
  upgrade from a real one without it, so the chart task would report `changed`
  on every run and the acceptance gate below could never be met. Install with
  `helm plugin install https://github.com/databus23/helm-diff --verify=false`;
  the flag is required because helm 4 verifies plugin provenance and this plugin
  publishes none
- `~/.ssh/config` aliases matching the inventory hostnames, whose `User` is a
  sudoer with NOPASSWD. Ansible has no way to supply a sudo password, and a
  renamed account keeps group-based sudo while silently losing the NOPASSWD
  entry that names it
- DNS: `phantom.lan` and the role aliases `registry.lan` and `metrics.lan`,
  resolving to whichever host serves them

## Running a target

Four commands, in this order: a dry run to read first, the run itself, the
gates, and a second run that is expected to report `changed=0`.

```bash
~/.venv/bin/ansible-playbook playbooks/phantom/main.yml --check --diff
~/.venv/bin/ansible-playbook playbooks/phantom/main.yml
~/.venv/bin/ansible-playbook playbooks/phantom/verify.yml
~/.venv/bin/ansible-playbook playbooks/phantom/main.yml
```

A second run reporting `changed=0` is the acceptance gate. It is the
idempotency claim the shell scripts asserted but never demonstrated.

The other targets (`revenant`, `wraith`, `necropolis`) each have the same
`main.yml` and `verify.yml` pair under `playbooks/`. `playbooks/site.yml` runs
every target in dependency order.

## Patching necropolis

`playbooks/necropolis/patch.yml` patches the cluster one node at a time, from
the workstation, with the `necropolis` kubeconfig context reachable. It drains
nothing unless every node is Ready, every etcd member is healthy and no
Longhorn volume is degraded. A node with no pending upgrades and no pending
reboot is skipped, and a node reboots only when the upgrade asks for one.

One node goes first as a canary. The cluster's gates are checked, and then the
rest are patched; the canary is skipped on the second run, since nothing is
pending on it:

```bash
~/.venv/bin/ansible-playbook playbooks/necropolis/patch.yml --limit banshee
~/.venv/bin/ansible-playbook playbooks/necropolis/verify.yml
~/.venv/bin/ansible-playbook playbooks/necropolis/patch.yml
```

## Local LLM on revenant

`playbooks/revenant/llm.yml` is optional and no other playbook runs it. Nothing
else can use the GPU while the server is up, and sharing must be off.

`llama_server_model` is required when installing and verifying, and must be a key
of `llama_server_models` in `roles/llama_server/defaults/main.yml`. Rerunning with
another name replaces the server. Weights stay in `/srv/models`, so each model
downloads once. A first download can take hours over a slow link. If the run times
out, the download continues, and running the playbook again resumes waiting.

```bash
~/.venv/bin/ansible-playbook playbooks/revenant/llm.yml -e llama_server_model=qwen3.8-flash-next
~/.venv/bin/ansible-playbook playbooks/revenant/llm.yml -e llama_server_model=qwen3.8-flash-next -e layer_mode=verify
```

The OpenAI-compatible API and web UI are on `http://revenant.lan:30800`, with the
API at `/v1`. Clients authenticate with a key kept on the workstation, generated
by the first run of this playbook or the necropolis one, and written into each
cluster on every run, so a reload of revenant does not change it:

```bash
cat ~/.local/share/infra/revenant-llama-api-key
```

Removal needs no model name. It frees the GPU and memory, and keeps the weights:

```bash
~/.venv/bin/ansible-playbook playbooks/revenant/llm.yml -e llama_server_state=absent
```

## Open WebUI on necropolis

Open WebUI is part of the necropolis cluster layer, the chat front end for
revenant's llama-server. It needs a `seance.lan` DNS record for the Gateway's
address, like `awx.lan`. The UI is on `https://seance.lan`.

The first account created there becomes the administrator, so create it straight
after the first install. Open WebUI copies the llama-server URL and key into its
own database on first start; a changed key is set under Admin Settings,
Connections, as well as by rerunning the playbook. The gates ask llama-server for
its models from inside the pod, so they fail while revenant or its server is down.

## AWX on necropolis

AWX is part of the necropolis cluster layer, so `playbooks/necropolis/main.yml`
installs it and `playbooks/necropolis/verify.yml` checks it. Before the first
run, `awx.lan` needs a DNS record for the Gateway's address, the same address as
`hubble.lan`, which the gateway role prints at the end of each run. The
workstation must also trust the necropolis CA, as described in phase 3 of
`docs/necropolis.md`.

The UI and API are on `https://awx.lan`. The operator generates the `admin`
password at first install and keeps it in the cluster. A rebuild from nothing
generates a new one.

```bash
kubectl --context necropolis -n awx get secret awx-admin-password -o jsonpath='{.data.password}' | base64 -d
```

The operator works through one reconcile at a time. A reconcile waiting on
something that cannot become ready, such as a database that cannot start, holds
back every later change to the `AWX` resource, so a corrected spec reaches the
resource but not its workloads. Restarting the operator abandons that
reconcile. The operator keeps no state of its own and starts again from the
resource:

```bash
kubectl --context necropolis -n awx rollout restart deployment awx-operator-controller-manager
```

## Vault on necropolis

Vault is part of the necropolis cluster layer, like AWX, and needs a `vault.lan`
DNS record for the same Gateway address before its first run. The UI and API
are on `https://vault.lan`.

The first run initializes Vault and writes its unseal key and root token to
`~/.local/share/infra/vault/necropolis/init.json`. Every later run unseals
Vault if it is sealed, so after a power cut the recovery is a run of the
necropolis playbook. The root token is read from that file:

```bash
jq -r .root_token ~/.local/share/infra/vault/necropolis/init.json
```

The file is the only way to unseal Vault, so `~/.local/share/infra/` must be
backed up. It also holds the cluster CAs and the shared NUT password.

The role refuses to initialize a Vault that reports uninitialized while the
file exists, because that would overwrite the key to the old data. When Vault's
storage has been rebuilt on purpose, move the file aside, then run the
playbook:

```bash
mv ~/.local/share/infra/vault/necropolis/init.json ~/.local/share/infra/vault/necropolis/init.json.old
~/.venv/bin/ansible-playbook playbooks/necropolis/main.yml
```

AWX can read only `secret/awx/*`, so secrets for its jobs go there. They are
written by hand and never committed:

```bash
export VAULT_ADDR=https://vault.lan
export VAULT_CACERT=~/.local/share/infra/pki/necropolis/ca.crt
export VAULT_TOKEN=$(jq -r .root_token ~/.local/share/infra/vault/necropolis/init.json)
vault kv put secret/awx/ssh private_key=@$HOME/.ssh/awx_ed25519
```

In AWX, a "HashiCorp Vault Secret Lookup" credential reaches them with
authentication method Kubernetes, role `awx`, auth path `kubernetes` and API
version v2. Its Test button logs in from AWX's own pod.
