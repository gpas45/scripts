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

# version_exists VERSION — return 0 if a CHR image for VERSION is published on
# MikroTik's download server. Uses a HEAD request so nothing is downloaded.
version_exists() {
   wget -q --spider "${MIKROTIK_DL}/$1/chr-$1.img.zip"
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
# MikroTik no longer publishes a reliable "latest version" file (the legacy
# NEWEST*/LATEST.* feeds are frozen at 7.12.1), so instead of guessing the
# newest release we let the user pick one and verify it actually exists.
echo "## Preparing for image download and VM creation!"
echo "-- Current Long-term / Stable releases are listed at https://mikrotik.com/download"

while true; do
   read -r -p "Please input CHR version to deploy (e.g. 7.18.2): " version
   if ! valid_version "$version"; then
      echo "-- Invalid version format, please try again (e.g. 7.18.2)."
      continue
   fi
   # An already-downloaded image is good enough; otherwise confirm it exists.
   if [ -f "$TEMP_DIR/chr-$version.img" ]; then
      break
   fi
   echo "-- Verifying that CHR $version exists on MikroTik..."
   if version_exists "$version"; then
      break
   fi
   echo "-- CHR $version was not found on the download server, try another version."
done

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
