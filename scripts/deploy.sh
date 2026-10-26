#!/usr/bin/env bash
#
# Deploy the checked-out commit to a versioned release directory on a server.
#
#   scripts/deploy.sh <user@host> <version>
#
# Environment:
#   SSH_IDENTITY_FILE  optional path to the SSH private key to use
#   DEPLOY_RUN_ID      CI run id recorded in the release metadata
#   DEPLOY_REF         CI ref recorded in the release metadata
#
# The archive is taken from HEAD (committed state), not the working tree.
# scripts/deploy-remote.sh then backs up the database, runs migrations,
# snapshots the migrated database, switches the release symlink, restarts
# gunicorn and health-checks it; any failure restores the database and the
# previous release automatically.
set -euo pipefail

target=${1:?usage: scripts/deploy.sh <user@host> <version>}
version=${2:?usage: scripts/deploy.sh <user@host> <version>}
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
namespace='task87-48f9273e96924437833f'

if [[ "$version" != "$namespace-"* ]]; then
  echo "error: version '$version' does not belong to this round (expected ${namespace}-*)" >&2
  exit 2
fi
if [[ ! "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "error: version must be a plain directory name" >&2
  exit 2
fi

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
  ssh_opts+=(-i "$SSH_IDENTITY_FILE")
fi

sha=$(git -C "$repo_root" rev-parse HEAD)
archive=$(mktemp --suffix=.tar.gz)
remote_archive="/tmp/task87-code-${version}.tar.gz"
trap 'rm -f "$archive"' EXIT

echo "==> archiving ${sha} from ${repo_root}"
git -C "$repo_root" archive --format=tar.gz HEAD > "$archive"

echo "==> uploading code to ${target}:${remote_archive}"
scp -q "${ssh_opts[@]}" "$archive" "${target}:${remote_archive}"

echo "==> deploying release ${version} on ${target}"
remote_cmd=$(printf 'env DEPLOY_GIT_SHA=%q DEPLOY_RUN_ID=%q DEPLOY_REF=%q bash -s -- %q' \
  "$sha" "${DEPLOY_RUN_ID:-local}" "${DEPLOY_REF:-local}" "$version")
ssh "${ssh_opts[@]}" "$target" "$remote_cmd" < "$repo_root/scripts/deploy-remote.sh"
