#!/usr/bin/env bash
# Ubuntu 24.04 amd64. Script: /opt/ubuntu/install-b300-docker-nvidia.sh
# Archive: /opt/ubuntu/workspace/drivers/b300-docker-nvidia-offline.tar.gz
# Default: install.
set -Eeuo pipefail
export LC_ALL=C
trap 'rc=$?; echo "[ERROR] line $LINENO, exit $rc. Inspect the log; package changes are not automatically rolled back." >&2; exit "$rc"' ERR
die() { echo "[ERROR] $*" >&2; exit 1; }
usage() {
    echo 'Usage: sudo bash install-b300-docker-nvidia.sh [--check] [--allow-restart] [--image-tar FILE --test-image IMAGE:TAG]'
}
INSTALL=1 ALLOW_RESTART=0 IMAGE_TAR= TEST_IMAGE=
while (($#)); do
    case $1 in
        --install) INSTALL=1; shift ;;
        --check) INSTALL=0; shift ;;
        --allow-restart) ALLOW_RESTART=1; shift ;;
        --image-tar|--test-image)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "Missing value for $1"
            if [[ $1 == --image-tar ]]; then IMAGE_TAR=$2; else TEST_IMAGE=$2; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown argument: $1" ;;
    esac
done
[[ $EUID -eq 0 ]] || die 'Run with sudo/root.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(dpkg --print-architecture) == amd64 ]] || die 'Requires Ubuntu 24.04 amd64; do not use on ARM64/GB300.'
[[ -d /run/systemd/system ]] || die 'Requires a host booted with systemd.'
ARCHIVE="/opt/ubuntu/workspace/drivers/b300-docker-nvidia-offline.tar.gz"
[[ -f $ARCHIVE ]] || die "Offline archive not found: $ARCHIVE"
EXPECTED_SHA256=fe9f82ac3568df2571db58a28166d404a6838efca5f484d5d90387d77f7ca6a3
ACTUAL_SHA256=$(sha256sum -- "$ARCHIVE")
[[ ${ACTUAL_SHA256%% *} == "$EXPECTED_SHA256" ]] || die 'Archive checksum mismatch; copy the matching complete archive again.'
EXTRACT=$(mktemp -d /var/tmp/b300-docker-bundle.XXXXXX)
tar --no-same-owner -xzf "$ARCHIVE" -C "$EXTRACT"
ROOT="$EXTRACT/b300-docker-nvidia-offline"
echo "[INFO] Verified bundle extracted to $ROOT"
[[ $ROOT =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'Extract the bundle under an ASCII path without spaces, e.g. /opt/offline/.'
[[ -f $ROOT/SHA256SUMS && -f $ROOT/install-specs.txt && -f $ROOT/Packages ]] || die 'Incomplete bundle; copy the matching archive again.'
if [[ -n $IMAGE_TAR || -n $TEST_IMAGE ]]; then
    [[ -f $IMAGE_TAR && -n $TEST_IMAGE && $TEST_IMAGE != -* ]] || die 'Supply both a readable --image-tar FILE and --test-image IMAGE:TAG.'
    IMAGE_TAR=$(realpath -- "$IMAGE_TAR")
fi
LOG=$(mktemp /var/tmp/b300-docker-install.XXXXXX.log)
exec > >(tee -a "$LOG") 2>&1
echo "[INFO] Log: $LOG"
(cd "$ROOT" && sha256sum --strict -c SHA256SUMS)
command -v nvidia-smi >/dev/null || die 'Install a B300-supported host NVIDIA driver first.'
nvidia-smi
nvidia-smi -L
audit=$(dpkg --audit)
[[ -z $audit ]] || die "Existing incomplete dpkg state; repair before installation: $audit"
for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc nvidia-docker2; do
    status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    [[ $status != 'install ok installed' ]] || die "Conflicting/legacy package: $pkg. Plan its migration/removal explicitly, then retry."
done
if systemctl is-active --quiet docker.service || systemctl is-active --quiet docker.socket; then
    if (( INSTALL && ! ALLOW_RESTART )); then
        die 'Docker is active. Stop workloads, then pass --allow-restart to permit package/service restarts.'
    fi
    echo '[WARN] Docker is active; installation/reconfiguration may restart it and interrupt containers.'
fi
mapfile -t SPECS < "$ROOT/install-specs.txt"
[[ ${#SPECS[@]} -eq 9 ]] || die 'Unexpected package specification list.'
for spec in "${SPECS[@]}"; do
    [[ $spec =~ ^[a-z0-9][a-z0-9+.-]*=[^[:space:]]+$ ]] || die "Invalid package specification: $spec"
done
STATE=$(mktemp -d /var/tmp/b300-docker-offline-apt.XXXXXX)
mkdir -p "$STATE/lists/partial" "$STATE/archives/partial"
printf 'deb [trusted=yes] file:%s ./\n' "$ROOT" > "$STATE/local.list"
OPTS=(-o "Dir::Etc::sourcelist=$STATE/local.list" -o Dir::Etc::sourceparts=-
      -o Dir::Etc::preferences=/dev/null -o Dir::Etc::preferencesparts=-
      -o "Dir::State::lists=$STATE/lists" -o "Dir::Cache::archives=$STATE/archives/"
      -o "Dir::Cache::pkgcache=$STATE/pkgcache.bin" -o "Dir::Cache::srcpkgcache=$STATE/srcpkgcache.bin"
      -o APT::Sandbox::User=root)
export DEBIAN_FRONTEND=noninteractive
apt-get "${OPTS[@]}" -o APT::Update::Error-Mode=any update
apt-get "${OPTS[@]}" --simulate --no-install-recommends --no-remove install "${SPECS[@]}"
if (( ! INSTALL )); then
    echo '[OK] Preflight/simulation complete. No packages installed or Docker configuration changed.'
    echo '[INFO] Review the package plan, then rerun without --check (add --allow-restart if required).'
    exit 0
fi
# No allow-downgrades, allow-change-held-packages, or automatic removal. APT will
# fail safely for these cases; it can upgrade dependencies shown in the plan.
apt-get "${OPTS[@]}" -y --no-install-recommends --no-remove install "${SPECS[@]}"
mkdir -p /etc/docker
[[ ! -L /etc/docker/daemon.json ]] || die 'daemon.json is a symlink; manage this configuration explicitly.'
if [[ -e /etc/docker/daemon.json ]]; then
    dockerd --validate --config-file=/etc/docker/daemon.json
    BACKUP=$(mktemp /etc/docker/daemon.json.backup.XXXXXX)
    cp -p -- /etc/docker/daemon.json "$BACKUP"
    echo "[INFO] Original Docker configuration: $BACKUP"
fi
CONFIG=$(mktemp /etc/docker/daemon.json.new.XXXXXX)
if [[ -f /etc/docker/daemon.json ]]; then
    cp -p -- /etc/docker/daemon.json "$CONFIG"
else
    printf '{}\n' > "$CONFIG"
    chmod 644 "$CONFIG"
fi
# Merge runtime registration into existing options, then validate before replacing.
nvidia-ctk runtime configure --runtime=docker --config="$CONFIG"
dockerd --validate --config-file="$CONFIG"
mv -- "$CONFIG" /etc/docker/daemon.json
systemctl daemon-reload
systemctl enable containerd.service docker.service
systemctl start containerd.service
systemctl restart docker.service
systemctl is-active --quiet docker.service || die 'Docker failed to start; inspect journalctl -u docker -n 100.'
DOCKER=(docker --host unix:///var/run/docker.sock)
"${DOCKER[@]}" version
"${DOCKER[@]}" info --format '{{json .Runtimes}}'
"${DOCKER[@]}" info --format '{{json .Runtimes}}' | grep -q '"nvidia"' || die 'NVIDIA runtime registration is missing.'
nvidia-ctk --version
dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' "${SPECS[@]%%=*}"
if [[ -n $IMAGE_TAR ]]; then
    "${DOCKER[@]}" load -i "$IMAGE_TAR"
    "${DOCKER[@]}" image inspect "$TEST_IMAGE" >/dev/null
    "${DOCKER[@]}" run --rm --pull=never --network=none --gpus all --entrypoint nvidia-smi "$TEST_IMAGE"
    echo '[OK] Offline GPU container nvidia-smi test passed.'
else
    echo '[INFO] GPU container test pending: no image supplied. Use --image-tar FILE --test-image IMAGE:TAG to import and test an offline image.'
fi
echo "[OK] Docker and NVIDIA Container Toolkit installed/configured. Log: $LOG"



# sudo bash 04_install-b300-docker-nvidia.sh
