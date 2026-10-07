#!/usr/bin/env bash
# Rebuild the workstation side of this repository's prerequisites.
#
# Everything here is user-scoped: a virtualenv under $HOME and a helm plugin.
# Nothing needs sudo, and nothing outside $HOME is touched.
#
# What it deliberately does NOT do is install helm or kubectl. Those come from a
# package manager this repository has no business driving, and a script that
# silently brew-installs a binary is a script that has to be read before it can
# be trusted. They are checked and reported instead.
#
# The success criterion is not "the commands ran" — it is that
# roles/preflight/tasks/controller.yml would now pass. That file is the contract;
# this script exists to satisfy it, and re-checks it at the end.
#
#   ./scripts/bootstrap-workstation.sh
#
# Safe to re-run. Pass --recreate to delete and rebuild the venv from scratch,
# which is the answer when it is corrupt rather than merely incomplete.
set -euo pipefail

VENV="${VENV:-$HOME/.venv}"
RECREATE=0
[[ "${1:-}" == "--recreate" ]] && RECREATE=1

# Pinned deliberately, and these three are the whole Python dependency.
#
# `ansible` rather than `ansible-core`: the collections this repository uses —
# kubernetes.core, ansible.posix, community.general — ship bundled inside the
# ansible package at versions that release together. Installing ansible-core
# alone leaves requirements.yml unsatisfied and produces "couldn't resolve module"
# for modules that are plainly documented.
#
# kubernetes and jmespath must live in the SAME interpreter as ansible, which is
# the entire reason this is one venv rather than three pip invocations against
# whatever python happens to be first on PATH. kubernetes.core imports the
# kubernetes library from the interpreter Ansible itself runs under; a brew
# ansible with a pip-installed kubernetes puts them in different interpreters and
# reports "No module named 'kubernetes'" on a machine where it is plainly there.
PINS=(
  "ansible==14.3.1"
  "kubernetes==36.0.3"
  "jmespath==1.1.0"
)

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  ! \033[0m%s\n' "$*"; }
die()  { printf '\033[31m  ✗ \033[0m%s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m  ✓ \033[0m%s\n' "$*"; }

# --- the virtualenv ----------------------------------------------------------

if [[ "$RECREATE" == 1 && -d "$VENV" ]]; then
  say "removing $VENV"
  rm -rf "$VENV"
fi

if [[ ! -x "$VENV/bin/python3" ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
  say "creating $VENV"
  python3 -m venv "$VENV"
else
  say "using existing $VENV"
fi

say "installing pinned dependencies"
"$VENV/bin/python3" -m pip install --quiet --upgrade pip
"$VENV/bin/python3" -m pip install --quiet "${PINS[@]}"

# --- things this script will not install -------------------------------------

say "checking tools this script does not manage"
MISSING=0
if command -v helm >/dev/null 2>&1; then
  ok "helm $(helm version --short 2>/dev/null || echo '(version unknown)')"
else
  warn "helm not found — install with: brew install helm"
  MISSING=1
fi
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client -o json 2>/dev/null | "$VENV/bin/python3" -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo '(version unknown)')"
else
  warn "kubectl not found — install with: brew install kubectl"
  MISSING=1
fi

# --- helm-diff ---------------------------------------------------------------
#
# Without it kubernetes.core.helm cannot tell an upgrade that changes nothing
# from one that does — `helm upgrade` cuts a new revision either way — so the
# chart tasks report `changed` on every run and the changed=0 acceptance gate in
# README.md becomes unreachable. An acceptance gate nobody can satisfy is one
# nobody reads.
if command -v helm >/dev/null 2>&1; then
  if helm plugin list 2>/dev/null | grep -qE '^diff\s'; then
    ok "helm-diff present"
  else
    say "installing helm-diff"
    # --verify=false because helm 4 verifies plugin provenance by default and
    # this plugin publishes none. That skips a signature check on a binary that
    # runs here, which is a real decision — it is the plugin the Ansible warning
    # itself points at, and the alternative is an unreachable acceptance gate.
    helm plugin install https://github.com/databus23/helm-diff --verify=false
  fi
fi

# --- prove it ----------------------------------------------------------------
#
# The same three questions roles/preflight/tasks/controller.yml asks. If this
# block passes, the cluster layer will run.

say "verifying against the preflight contract"
"$VENV/bin/python3" -c 'import kubernetes' 2>/dev/null \
  && ok "kubernetes importable from $VENV/bin/python3" \
  || die "kubernetes not importable from $VENV/bin/python3"
"$VENV/bin/python3" -c 'import jmespath' 2>/dev/null \
  && ok "jmespath importable from $VENV/bin/python3" \
  || die "jmespath not importable from $VENV/bin/python3"
[[ -x "$VENV/bin/ansible-playbook" ]] \
  && ok "$("$VENV/bin/ansible-playbook" --version | head -1)" \
  || die "ansible-playbook missing from $VENV/bin"

echo
if [[ "$MISSING" == 1 ]]; then
  warn "workstation is NOT ready — install the tools noted above, then re-run"
  exit 1
fi

say "ready"
cat <<EOF

  ~/.venv/bin/ansible-playbook playbooks/<host>/main.yml --check --diff
  ~/.venv/bin/ansible-playbook playbooks/<host>/main.yml
  ~/.venv/bin/ansible-playbook playbooks/<host>/verify.yml
  ~/.venv/bin/ansible-playbook playbooks/<host>/main.yml   # expect changed=0

Still needed, and outside this script's reach: ~/.ssh/config aliases matching the
inventory hostnames, whose User is a sudoer with NOPASSWD, and DNS for the host
plus the registry.lan and metrics.lan role aliases.
EOF
