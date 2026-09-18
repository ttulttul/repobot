#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture=$(mktemp -d /tmp/rbssh.XXXXXX)
container="repobot-test-${fixture##*.}"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$fixture"; }
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$fixture/key"
docker build -f Tests/Fixtures/Dockerfile.ssh -t repobot-ssh-fixture:local Tests/Fixtures >/dev/null
docker run -d --rm --name "$container" -p 127.0.0.1::22 -v "$fixture/key.pub:/root/.ssh/authorized_keys:ro" repobot-ssh-fixture:local >/dev/null
port=$(docker port "$container" 22/tcp | awk -F: '{print $NF}')
export REPOBOT_TEST_SSH_DIRECTORY="$fixture" REPOBOT_TEST_SSH_PORT="$port"
./scripts/swift.sh test --disable-xctest --filter testRealSSHProbeAndWatcher
