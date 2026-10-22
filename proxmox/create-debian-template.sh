#!/usr/bin/env bash
#
# Create a Proxmox VE VM template from an official Debian cloud image.
#
# Run as root on the Proxmox node that should hold the template. The template
# disk lives on node-local storage (local-zfs by default), which can only be
# cloned on the same node, so run this once per node with a different VMID:
#
#   ./create-debian-template.sh --vmid 9000 --ssh-keys ~/keys.pub   # node 1
#   ./create-debian-template.sh --vmid 9001 --ssh-keys ~/keys.pub   # node 2
#
# Then deploy with:
#
#   qm clone 9000 120 --name my-vm --full
#   qm set 120 --ipconfig0 ip=dhcp,ip6=auto   # or ip=x.x.x.x/24,gw=x.x.x.x
#   qm start 120
#
# What it does:
#   1. Downloads the Debian genericcloud qcow2 and verifies its SHA512 checksum
#   2. Bakes in qemu-guest-agent with virt-customize (skip with --no-customize),
#      plus Docker Engine from Docker's apt repo with --docker
#   3. Creates a VM with a virtio-scsi disk, a cloud-init drive and a serial console
#   4. Converts it to a template
#
set -euo pipefail

# ---- Defaults (override with flags) -----------------------------------------
VMID=9000
RELEASE=trixie            # trixie (13) or bookworm (12)
NAME=""                   # default: debian-<version>-cloud (or -docker)
STORAGE=local-zfs
BRIDGE=vmbr0
VLAN=""                   # e.g. 4 to tag the NIC
CORES=2
MEMORY=2048               # MiB
DISK_SIZE=32G             # template disk size; clones can grow it later
CPU_TYPE=x86-64-v2-AES    # live-migrates between AMD and Intel nodes
CI_USER=debian
SSH_KEYS=""               # path to a file of public keys
CUSTOMIZE=1
DOCKER=0
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --vmid ID          VMID for the template (default: $VMID)
  --release NAME     Debian release: trixie | bookworm (default: $RELEASE)
  --name NAME        Template name (default: debian-<version>-cloud, or
                     debian-<version>-docker with --docker)
  --storage ID       Storage for the disk + cloud-init drive (default: $STORAGE)
  --bridge NAME      Network bridge (default: $BRIDGE)
  --vlan TAG         VLAN tag for net0 (default: untagged)
  --cores N          vCPU cores (default: $CORES)
  --memory MIB       RAM in MiB (default: $MEMORY)
  --disk-size SIZE   Root disk size, e.g. 10G (default: $DISK_SIZE)
  --user NAME        cloud-init default user (default: $CI_USER)
  --ssh-keys FILE    File of SSH public keys to inject via cloud-init
  --no-customize     Don't install qemu-guest-agent into the image
  --docker           Also install Docker Engine + Compose and add the
                     cloud-init user to the docker group on first boot
  --force           Destroy an existing VM/template with the same VMID first
  -h, --help         Show this help
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)         VMID="$2"; shift 2 ;;
    --release)      RELEASE="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --storage)      STORAGE="$2"; shift 2 ;;
    --bridge)       BRIDGE="$2"; shift 2 ;;
    --vlan)         VLAN="$2"; shift 2 ;;
    --cores)        CORES="$2"; shift 2 ;;
    --memory)       MEMORY="$2"; shift 2 ;;
    --disk-size)    DISK_SIZE="$2"; shift 2 ;;
    --user)         CI_USER="$2"; shift 2 ;;
    --ssh-keys)     SSH_KEYS="$2"; shift 2 ;;
    --no-customize) CUSTOMIZE=0; shift ;;
    --docker)       DOCKER=1; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "Unknown option: $1" ;;
  esac
done

# ---- Validation -------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root on a Proxmox node."
command -v qm >/dev/null || die "'qm' not found - is this a Proxmox VE node?"
[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid must be a number."
[[ -z "$VLAN" || "$VLAN" =~ ^[0-9]+$ ]] || die "--vlan must be a number."
[[ $DOCKER -eq 0 || $CUSTOMIZE -eq 1 ]] || die "--docker can't be combined with --no-customize."

case "$RELEASE" in
  trixie)   VERSION=13 ;;
  bookworm) VERSION=12 ;;
  *)        die "Unsupported release '$RELEASE' (use trixie or bookworm)." ;;
esac
if [[ $DOCKER -eq 1 ]]; then
  NAME="${NAME:-debian-${VERSION}-docker}"
else
  NAME="${NAME:-debian-${VERSION}-cloud}"
fi

pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
  || die "Storage '$STORAGE' not found or not active on this node."
[[ -d "/sys/class/net/$BRIDGE" ]] || die "Bridge '$BRIDGE' not found."

if [[ -n "$SSH_KEYS" ]]; then
  [[ -s "$SSH_KEYS" ]] || die "SSH key file '$SSH_KEYS' is missing or empty."
else
  echo "WARNING: no --ssh-keys given; set keys on each clone before first boot." >&2
fi

if qm status "$VMID" >/dev/null 2>&1; then
  if [[ $FORCE -eq 1 ]]; then
    info "Destroying existing VM $VMID"
    qm destroy "$VMID" --purge
  else
    die "VMID $VMID already exists (use --force to replace it)."
  fi
fi

# ---- Download and verify ----------------------------------------------------
BASE_URL="https://cloud.debian.org/images/cloud/${RELEASE}/latest"
IMAGE="debian-${VERSION}-genericcloud-amd64.qcow2"

WORKDIR="$(mktemp -d /var/tmp/debian-template.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

info "Downloading $IMAGE"
curl -fL --progress-bar -o "$WORKDIR/$IMAGE" "$BASE_URL/$IMAGE"
curl -fsSL -o "$WORKDIR/SHA512SUMS" "$BASE_URL/SHA512SUMS"

info "Verifying checksum"
( cd "$WORKDIR" && grep " ${IMAGE}\$" SHA512SUMS | sha512sum -c --status ) \
  || die "Checksum verification failed for $IMAGE."

# ---- Customize image --------------------------------------------------------
if [[ $CUSTOMIZE -eq 1 ]]; then
  if ! command -v virt-customize >/dev/null; then
    info "Installing libguestfs-tools (provides virt-customize)"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libguestfs-tools
  fi
  CUSTOMIZE_ARGS=(--install qemu-guest-agent)

  if [[ $DOCKER -eq 1 ]]; then
    curl -fsSL -o "$WORKDIR/docker.asc" https://download.docker.com/linux/debian/gpg
    # The cloud-init user is created on first boot, so it can't join the
    # docker group in the image; a per-instance script adds it afterwards.
    CUSTOMIZE_ARGS+=(
      --mkdir /etc/apt/keyrings
      --upload "$WORKDIR/docker.asc:/etc/apt/keyrings/docker.asc"
      --chmod 0644:/etc/apt/keyrings/docker.asc
      --write "/etc/apt/sources.list.d/docker.sources:Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${RELEASE}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
"
      --install docker-ce,docker-ce-cli,containerd.io,docker-buildx-plugin,docker-compose-plugin
      --mkdir /var/lib/cloud/scripts/per-instance
      --write "/var/lib/cloud/scripts/per-instance/docker-group.sh:#!/bin/sh
# Give the cloud-init user (a member of sudo) access to Docker.
for u in \$(getent group sudo | cut -d: -f4 | tr ',' ' '); do
  usermod -aG docker \"\$u\"
done
"
      --chmod 0755:/var/lib/cloud/scripts/per-instance/docker-group.sh
    )
  fi

  if [[ $DOCKER -eq 1 ]]; then
    info "Installing qemu-guest-agent and Docker into the image"
  else
    info "Installing qemu-guest-agent into the image"
  fi
  virt-customize -a "$WORKDIR/$IMAGE" \
    "${CUSTOMIZE_ARGS[@]}" \
    --truncate /etc/machine-id
fi

# ---- Create VM --------------------------------------------------------------
NET0="virtio,bridge=${BRIDGE}${VLAN:+,tag=${VLAN}}"
TAGS="debian,debian-${VERSION},template"
DESCRIPTION="Debian ${VERSION} (${RELEASE}) cloud image template"
if [[ $DOCKER -eq 1 ]]; then
  TAGS+=",docker"
  DESCRIPTION+=" with Docker"
fi

info "Creating VM $VMID ($NAME)"
qm create "$VMID" \
  --name "$NAME" \
  --description "${DESCRIPTION}, built $(date -u +%Y-%m-%d)" \
  --tags "$TAGS" \
  --ostype l26 \
  --machine q35 \
  --cpu "$CPU_TYPE" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "$NET0" \
  --scsihw virtio-scsi-single \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --serial0 socket \
  --vga serial0

info "Importing disk to $STORAGE"
qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${WORKDIR}/${IMAGE},discard=on,ssd=1,iothread=1"
qm disk resize "$VMID" scsi0 "$DISK_SIZE"

info "Adding cloud-init drive"
qm set "$VMID" \
  --ide2 "${STORAGE}:cloudinit" \
  --boot order=scsi0 \
  --ciuser "$CI_USER" \
  --ipconfig0 ip=dhcp,ip6=auto

if [[ -n "$SSH_KEYS" ]]; then
  qm set "$VMID" --sshkeys "$SSH_KEYS"
fi

info "Converting to template"
qm template "$VMID"

info "Done: template $VMID ($NAME) on node $(hostname) using storage $STORAGE"
