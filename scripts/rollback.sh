#!/usr/bin/env bash
#
# Manual rollback entry point. Rolls a server back to a release that was
# successfully deployed by this round's pipeline.
#
#   scripts/rollback.sh <test-server|prod-server|user@host> <version>
#   scripts/rollback.sh <test-server|prod-server|user@host> --list
#
# --list shows every release directory on the server, marking which ones are
# valid rollback targets (successfully deployed by this round).
#
# Only versions named task87-48f9273e96924437833f-* that carry a
# .deploy-meta written by scripts/deploy-remote.sh are accepted, so a
# rollback can never leave this round's version set.
set -euo pipefail

target=${1:?usage: scripts/rollback.sh <test-server|prod-server|user@host> <version|--list>}
request=${2:?usage: scripts/rollback.sh <test-server|prod-server|user@host> <version|--list>}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
namespace='task87-48f9273e96924437833f'

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
  ssh_opts+=(-i "$SSH_IDENTITY_FILE")
fi

if [[ "$request" == '--list' ]]; then
  echo "Releases on ${target}:"
  ssh "${ssh_opts[@]}" "$target" 'bash -s' <<REMOTE
set -euo pipefail
ns='${namespace}'
found=0
for d in /srv/microblog/releases/"\$ns"-*; do
  [ -d "\$d" ] || continue
  found=1
  v=\$(basename "\$d")
  if [ -f "\$d/.deploy-meta" ]; then
    ts=\$(sed -n 's/^deployed_at=//p' "\$d/.deploy-meta")
    prev=\$(sed -n 's/^previous=//p' "\$d/.deploy-meta")
    echo "  OK    \$v  deployed_at=\$ts  previous=\$prev"
  else
    echo "  --    \$v  (not a successful release; not a valid target)"
  fi
done
[ "\$found" -eq 1 ] || echo "  (no releases from this round yet)"
REMOTE
  exit 0
fi

version=$request
if [[ "$version" != "$namespace-"* ]]; then
  echo "error: version '$version' is not from this round (expected ${namespace}-*)" >&2
  exit 2
fi
if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: version must be a plain directory name" >&2
  exit 2
fi

echo "==> rolling back ${target} to ${version}"
ssh "${ssh_opts[@]}" "$target" "bash -s -- $(printf %q "$version")" \
  < "$repo_root/scripts/rollback-remote.sh"
