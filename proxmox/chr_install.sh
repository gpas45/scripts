#!/bin/bash
#
# chr_install.sh — deploy a MikroTik CHR (Cloud Hosted Router) as a Proxmox VE VM.
#
# Downloads the requested RouterOS CHR image, converts it to qcow2, optionally
# resizes the disk and creates the VM. Can look up and suggest the current
# Long-term and Stable RouterOS releases from MikroTik.

set -euo pipefail

#### vars
TEMP_DIR="/root/temp"
NODE="$(hostname)"
MIKROTIK_DL="https://download.mikrotik.com/routeros"
MIKROTIK_UPG="https://upgrade.mikrotik.com/routeros"

# Defaults for the created VM (override here if needed)
VM_MEMORY=256
VM_SOCKETS=1
VM_CORES=1
VM_BRIDGE="vmbr0"
VM_STORAGE="local"

#### helpers

# die MESSAGE — print an error and exit with a failure code.
die() {
   echo "-- ERROR: $*" >&2
   exit 1
}

# cleanup — remove a half-created image dir if we fail after creating it.
IMG_DIR=""
cleanup() {
   local rc=$?
   if [ "$rc" -ne 0 ] && [ -n "$IMG_DIR" ] && [ -d "$IMG_DIR" ]; then
      echo "-- Cleaning up incomplete image dir $IMG_DIR" >&2
      rm -rf "$IMG_DIR"
   fi
}
trap cleanup EXIT

# valid_version VERSION — accept e.g. 6.40.1, 7.16, 7.16.2
valid_version() {
   [[ "$1" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

# fetch_channel CHANNEL — print the newest version for a RouterOS channel.
# CHANNEL is one of: stable, long-term, testing. Prints empty on failure or
# when the channel returns a placeholder (e.g. "0.00" for an empty branch).
fetch_channel() {
   local channel="$1" line ver
   # The NEWEST7.<channel> file contains: "<version> <unix-timestamp>"
   line="$(wget -qO- "${MIKROTIK_UPG}/NEWEST7.${channel}" 2>/dev/null || true)"
   ver="${line%% *}"
   # Only accept a real release (major version >= 1); reject empty / "0.00".
   [[ "$ver" =~ ^[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$ ]] && echo "$ver"
}

echo "############## Start of Script ##############"

#### 1. temp dir
echo "## Checking if temp dir is available..."
if [ -d "$TEMP_DIR" ]; then
   echo "-- Directory exists!"
else
   echo "-- Creating temp dir!"
   mkdir -p "$TEMP_DIR" || die "Could not create $TEMP_DIR"
fi

#### 2. determine version to deploy
echo "## Preparing for image download and VM creation!"
echo "-- Looking up current RouterOS releases from MikroTik..."
stable_ver="$(fetch_channel stable)"
lt_ver="$(fetch_channel long-term)"

[ -n "$lt_ver" ]     && echo "   Long-term (recommended): $lt_ver"
[ -n "$stable_ver" ] && echo "   Stable:                  $stable_ver"
[ -z "$lt_ver$stable_ver" ] && \
   echo "   (could not reach MikroTik — enter a version manually)"

# Default to long-term, fall back to stable.
default_ver="${lt_ver:-$stable_ver}"
prompt="Please input CHR version to deploy (6.38.2, 6.40.1, etc)"
[ -n "$default_ver" ] && prompt="$prompt [$default_ver]"
read -r -p "$prompt: " version
version="${version:-$default_ver}"

valid_version "$version" || die "Invalid version format: '$version'"

#### 3. download image if needed
img="$TEMP_DIR/chr-$version.img"
if [ -f "$img" ]; then
   echo "-- CHR image is available."
else
   echo "-- Downloading CHR $version image file."
   echo "---------------------------------------------------------------------------"
   wget -O "$TEMP_DIR/chr-$version.img.zip" \
      "${MIKROTIK_DL}/$version/chr-$version.img.zip" \
      || die "Download failed for version $version"
   unzip -o "$TEMP_DIR/chr-$version.img.zip" -d "$TEMP_DIR" \
      || die "Failed to unzip chr-$version.img.zip"
   echo "---------------------------------------------------------------------------"
fi
[ -f "$img" ] || die "CHR $version image file is missing after download!"

#### 4. choose a free VM ID
echo "== Printing list of VM's on this hypervisor!"
qm list
echo "== Printing list of CT's on this hypervisor!"
pct list
echo ""
read -r -p "Please enter free VM ID to use: " vmID
echo ""

[[ "$vmID" =~ ^[0-9]+$ ]] || die "VM ID must be a number: '$vmID'"
[ -f "/etc/pve/nodes/$NODE/qemu-server/$vmID.conf" ] && die "VM $vmID exists! Try another ID."
[ -f "/etc/pve/nodes/$NODE/lxc/$vmID.conf" ]         && die "CT $vmID exists! Try another ID."

#### 5. create image dir + qcow2
IMG_DIR="/var/lib/vz/images/$vmID"
echo "-- Creating VM image dir!"
mkdir -p "$IMG_DIR" || die "Could not create $IMG_DIR"

read -r -p "Please input extra image size in GB (0 for none): " imgsize
[[ "$imgsize" =~ ^[0-9]+$ ]] || die "Image size must be a non-negative number: '$imgsize'"

disk="$IMG_DIR/vm-$vmID-disk-0.qcow2"
echo "-- Converting image to qcow2 format"
qemu-img convert -f raw -O qcow2 "$img" "$disk" || die "qemu-img convert failed"

if [ "$imgsize" -ne 0 ]; then
   echo "-- Resizing image by +${imgsize}G"
   qemu-img resize "$disk" "+${imgsize}G" || die "qemu-img resize failed"
fi

#### 6. create the VM
echo "-- Creating new CHR VM"
qm create "$vmID" \
   --name "chr-$version" \
   --net0 "virtio,bridge=$VM_BRIDGE" \
   --bootdisk virtio0 \
   --ostype l26 \
   --memory "$VM_MEMORY" \
   --onboot no \
   --sockets "$VM_SOCKETS" \
   --cores "$VM_CORES" \
   --virtio0 "$VM_STORAGE:$vmID/vm-$vmID-disk-0.qcow2" \
   || die "qm create failed"

echo "############## End of Script ##############"
