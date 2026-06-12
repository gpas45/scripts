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
VM_DISK_EXTRA="256M"   # extra space added to the CHR disk when none is entered

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

# list_guests — print every guest (VMs and containers) in one aligned table
# sorted by ID. qm/pct have different column layouts, so we normalise both to:
#   ID  TYPE  STATUS  NAME
list_guests() {
   {
      printf 'ID\tTYPE\tSTATUS\tNAME\n'
      {
         # qm list: ID NAME STATUS MEM BOOTDISK PID — NAME may contain spaces,
         # but the trailing three columns are always MEM/BOOTDISK/PID, so STATUS
         # is the field before them and NAME is everything in between.
         qm list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {
            name=""; for (i=2; i<=NF-4; i++) name = name (name=="" ? "" : " ") $i
            printf "%s\tqemu\t%s\t%s\n", $1, $(NF-3), name
         }'
         # pct list: ID Status [Lock] Name — Name is always the last column.
         pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {
            printf "%s\tlxc\t%s\t%s\n", $1, $2, $NF
         }'
      } | sort -n
   } | awk -F'\t' '
      { for (i=1;i<=NF;i++) { cell[NR,i]=$i; if (length($i)>w[i]) w[i]=length($i) }
        if (NF>cols) cols=NF }
      END { for (r=1;r<=NR;r++) { line=""
               for (c=1;c<=cols;c++) line=line sprintf("%-*s  ", w[c], cell[r,c])
               sub(/ +$/,"",line); print line } }'
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
echo "== Existing guests on this hypervisor (VMs and containers):"
list_guests
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

read -r -p "Extra disk size to add (e.g. 256M, 1G; Enter = $VM_DISK_EXTRA, 0 = none): " imgsize
imgsize="${imgsize:-$VM_DISK_EXTRA}"
imgsize="${imgsize^^}"                                  # normalise suffix case (256m -> 256M)
[[ "$imgsize" =~ ^[0-9]+$ ]] && imgsize="${imgsize}G"   # a bare number means GB
[[ "$imgsize" =~ ^[0-9]+[KMGT]$ ]] || die "Invalid disk size: '$imgsize' (use e.g. 256M, 1G or 0)"

disk="$IMG_DIR/vm-$vmID-disk-0.qcow2"
echo "-- Converting image to qcow2 format"
qemu-img convert -f raw -O qcow2 "$img" "$disk" || die "qemu-img convert failed"

if [ "${imgsize%[KMGT]}" -ne 0 ]; then
   echo "-- Resizing image by +$imgsize"
   qemu-img resize "$disk" "+$imgsize" || die "qemu-img resize failed"
else
   echo "-- No disk resize requested."
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
