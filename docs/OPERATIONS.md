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
