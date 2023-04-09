#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

cleanup_loopdev() {
    sync --file-system
    sync

    if [ -b "${loop}" ]; then
        umount "${loop}"* 2> /dev/null || true
        losetup -d "${loop}" 2> /dev/null || true
    fi
}
trap cleanup_loopdev EXIT

wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done

    ((++seconds))

    ls -l "${loop}" &> /dev/null
}

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 filename.rootfs.tar.xz"
    exit 1
fi

rootfs="$(readlink -f "$1")"
if [[ "$(basename "${rootfs}")" != *".rootfs.tar.xz" || ! -e "${rootfs}" ]]; then
    echo "Error: $(basename "${rootfs}") must be a rootfs tarfile"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

# Create an empty disk image
img="../images/$(basename "${rootfs}" .rootfs.tar.xz).img"
size="$(xz -l "${rootfs}" | tail -n +2 | sed 's/,//g' | awk '{print int($5 + 1)}')"
truncate -s "$(( size + 2048 + 512 ))M" "${img}"

# Create loop device for disk image
loop="$(losetup -f)"
losetup "${loop}" "${img}"
disk="${loop}"

# Ensure disk is not mounted
mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

# Setup partition table
dd if=/dev/zero of="${disk}" count=4096 bs=512
parted --script "${disk}" \
mklabel gpt \
mkpart primary fat16 16MiB 272MiB \
mkpart primary ext4 272MiB 100%

set +e

# Create partitions
fdisk "${disk}" << EOF
t
1
BC13C2FF-59E6-4262-A352-B275FD6F7172
t
2
0FC63DAF-8483-4772-8E79-3D69D8477DE4
w
EOF

set -eE

partprobe "${disk}"

partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"

sleep 1

wait_loopdev "${disk}${partition_char}2" 60 || {
    echo "Failure to create ${disk}${partition_char}1 in time"
    exit 1
}

sleep 1

wait_loopdev "${disk}${partition_char}1" 60 || {
    echo "Failure to create ${disk}${partition_char}1 in time"
    exit 1
}

sleep 1

# Generate random uuid for bootfs
boot_uuid=$(uuidgen | head -c8)

# Generate random uuid for rootfs
root_uuid=$(uuidgen)

# Create filesystems on partitions
mkfs.vfat -i "${boot_uuid}" -F16 -n system-boot "${disk}${partition_char}1"
dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
mkfs.ext4 -U "${root_uuid}" -L writable "${disk}${partition_char}2"

# Mount partitions
mkdir -p ${mount_point}/{system-boot,writable} 
mount "${disk}${partition_char}1" ${mount_point}/system-boot
mount "${disk}${partition_char}2" ${mount_point}/writable

# Copy the rootfs to root partition
echo -e "Decompressing $(basename "${rootfs}")\n"
tar -xpJf "${rootfs}" -C ${mount_point}/writable

# Set boot args for the splash screen
[ -z "${img##*desktop*}" ] && bootargs="quiet splash plymouth.ignore-serial-consoles" || bootargs=""
[ -z "${img##*orangepi5b*}" ] && device_tree="orangepi-5b" || device_tree="orangepi-5"

# Create fstab entries
mkdir -p ${mount_point}/writable/boot/firmware
cat > ${mount_point}/writable/etc/fstab << EOF
# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>
LABEL=system-boot   /boot/firmware vfat    defaults    0       2
LABEL=writable      /              ext4    defaults    0       1
/swapfile           none           swap    sw          0       0
EOF

# Uboot script
cat > ${mount_point}/system-boot/boot.cmd << EOF
# This is a boot script for U-Boot
#
# Recompile with:
# mkimage -A arm64 -O linux -T script -C none -n "Boot Script" -d boot.cmd boot.scr

env set bootargs "console=ttyS2,1500000 console=tty1 root=LABEL=writable rootfstype=ext4 rootwait rw cma=64M cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0 ${bootargs}"

load \${devtype} \${devnum}:\${distro_bootpart} \${fdt_addr_r} /rk3588s-${device_tree}.dtb
fdt addr \${fdt_addr_r} && fdt resize 0x10000

if test -e \${devtype} \${devnum}:\${distro_bootpart} \${fdtoverlay_addr_r} /overlays.txt; then
    load \${devtype} \${devnum}:\${distro_bootpart} \${fdtoverlay_addr_r} /overlays.txt
    env import -t \${fdtoverlay_addr_r} \${filesize}
fi
for overlay_file in \${overlays}; do
    if load \${devtype} \${devnum}:\${distro_bootpart} \${fdtoverlay_addr_r} /overlays/rk3588-\${overlay_file}.dtbo; then
        echo "Applying device tree overlay: /overlays/rk3588-\${overlay_file}.dtbo"
        fdt apply \${fdtoverlay_addr_r} || setenv overlay_error "true"
    fi
done
if test -n \${overlay_error}; then
    echo "Error applying device tree overlays, restoring original device tree"
    load \${devtype} \${devnum}:\${distro_bootpart} \${fdt_addr_r} /rk3588s-${device_tree}.dtb
fi

setexpr distro_rootpart \${distro_bootpart} + 1
load \${devtype} \${devnum}:\${distro_rootpart} \${kernel_addr_r} /boot/vmlinuz
load \${devtype} \${devnum}:\${distro_rootpart} \${ramdisk_addr_r} /boot/initrd.img

booti \${kernel_addr_r} \${ramdisk_addr_r}:\${filesize} \${fdt_addr_r}
EOF
mkimage -A arm64 -O linux -T script -C none -n "Boot Script" -d ${mount_point}/system-boot/boot.cmd ${mount_point}/system-boot/boot.scr

# Device tree overlays to load
echo "overlays=" > ${mount_point}/system-boot/overlays.txt
mv ${mount_point}/writable/boot/firmware/* ${mount_point}/system-boot

# Write bootloader to disk image
dd if=idbloader.img of="${loop}" seek=64 conv=notrunc
dd if=u-boot.itb of="${loop}" seek=16384 conv=notrunc

# Copy spi bootloader to disk image
mkdir -p ${mount_point}/writable/usr/share/orangepi
cp rkspi_loader.img ${mount_point}/writable/usr/share/orangepi/rkspi_loader.img
cp rkspi_loader_sata.img ${mount_point}/writable/usr/share/orangepi/rkspi_loader_sata.img

# Cloud init config for server image
[ -z "${img##*server*}" ] && cp ../overlay/boot/firmware/{meta-data,user-data,network-config} ${mount_point}/system-boot

sync --file-system
sync

# Umount partitions
umount "${disk}${partition_char}1"
umount "${disk}${partition_char}2"

# Remove loop device
losetup -d "${loop}"

echo -e "\nCompressing $(basename "${img}.xz")\n"
xz -9 --extreme --force --keep --quiet --threads=0 "${img}"
rm -f "${img}"
cd ../images && sha256sum "$(basename "${img}.xz")" > "$(basename "${img}.xz.sha256")"
