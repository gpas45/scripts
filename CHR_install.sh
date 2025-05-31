#!/bin/bash

#vars
version="nil"
vmID="nil"

echo "############## Start of Script ##############

## Checking if temp dir is available..."
if [ -d /root/temp ] 
then
   echo "-- Directory exists!"
else
   echo "-- Creating temp dir!"
   mkdir /root/temp
fi
# Ask user for version
echo "## Preparing for image download and VM creation!"
read -p "Please input CHR version to deploy (6.38.2, 6.40.1, etc):" version
# Check if image is available and download if needed
if [ -f /root/temp/chr-$version.img ] 
then
   echo "-- CHR image is available."
else
   echo "-- Downloading CHR $version image file."
   cd /root/temp
   echo "---------------------------------------------------------------------------"
   wget --no-check-certificate https://download.mikrotik.com/routeros/$version/chr-$version.img.zip
   unzip chr-$version.img.zip
   echo "---------------------------------------------------------------------------"
fi
if [ ! -f /root/temp/chr-$version.img ] 
then
   echo "-- Error downloading CHR $version image file!"
   exit 0
fi
# List already existing VM's and ask for vmID
echo "== Printing list of VM's on this hypervisor!"
qm list
echo "== Printing list of CT's on this hypervisor!"
pct list
echo ""
read -p "Please Enter free vm ID to use:" vmID
echo ""
# Create storage dir for VM if needed.
if [ -f /etc/pve/nodes/pve/qemu-server/$vmID.conf ] 
then
   echo "-- VM exists! Try another vm ID!"
   exit 0
fi
if [ -f /etc/pve/nodes/pve/lxc/$vmID.conf ] 
then
   echo "-- CT exists! Try another vm ID!"
   exit 0
fi
echo "-- Creating VM image dir!"
mkdir /var/lib/vz/images/$vmID
# Creating qcow2 image for CHR.
read -p "Please input image size, GB:" imgsize
echo "-- Converting image to qcow2 format "
qemu-img convert \
 -f raw \
 -O qcow2 \
 /root/temp/chr-$version.img \
 /var/lib/vz/images/$vmID/vm-$vmID-disk-1.qcow2
if [ $imgsize -ne 0 ]
then
   echo "-- Resize image to $imgsize GB"
   qemu-img resize \
   /var/lib/vz/images/$vmID/vm-$vmID-disk-1.qcow2 +${imgsize}G
fi
# Creating VM
echo "-- Creating new CHR VM"
qm create $vmID \
 --name chr-$version \
 --net0 virtio,bridge=vmbr0 \
 --bootdisk virtio0 \
 --ostype l26 \
 --memory 256 \
 --onboot no \
 --sockets 1 \
 --cores 1 \
 --virtio0 local:$vmID/vm-$vmID-disk-1.qcow2
echo "############## End of Script ##############"
