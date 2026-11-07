#!/usr/bin/env bash
# Rebuild the workstation prerequisites (a venv under $HOME and a helm plugin),
# without sudo, until roles/preflight/tasks/controller.yml would pass.
# helm and kubectl are only checked, never installed. Safe to re-run;
# --recreate rebuilds a corrupt venv from scratch.
set -euo pipefail

VENV="${VENV:-$HOME/.venv}"
RECREATE=0
[[ "${1:-}" == "--recreate" ]] && RECREATE=1

# `ansible`, not `ansible-core`, because only the former bundles the collections
# in requirements.yml. kubernetes and jmespath must share ansible's interpreter,
# hence one venv.
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
# The workstation is macOS or Ubuntu; only the install hint differs.
install_hint() {
  if [[ "$(uname -s)" == Darwin ]]; then
    echo "brew install $1"
  else
    echo "sudo snap install $1 --classic"
  fi
}
MISSING=0
if command -v helm >/dev/null 2>&1; then
  ok "helm $(helm version --short 2>/dev/null || echo '(version unknown)')"
else
  warn "helm not found — install with: $(install_hint helm)"
  MISSING=1
fi
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl $(kubectl version --client -o json 2>/dev/null | "$VENV/bin/python3" -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo '(version unknown)')"
else
  warn "kubectl not found — install with: $(install_hint kubectl)"
  MISSING=1
fi

# --- helm-diff ---------------------------------------------------------------
#
# Without it kubernetes.core.helm reports every chart as changed, so a second
# run can never reach changed=0.
if command -v helm >/dev/null 2>&1; then
  if helm plugin list 2>/dev/null | grep -qE '^diff\s'; then
    ok "helm-diff present"
  else
    say "installing helm-diff"
    # helm 4 verifies plugin provenance and this plugin publishes none; skipping
    # the signature check is a deliberate trade for a reachable changed=0 gate.
    helm plugin install https://github.com/databus23/helm-diff --verify=false
  fi
fi

# --- prove it ----------------------------------------------------------------
#
# The same checks roles/preflight/tasks/controller.yml makes.

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
