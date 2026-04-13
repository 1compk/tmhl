#!/usr/bin/env bash
set -euo pipefail

echo "==== Image Flashing & Disk Setup Utility ===="

die() { echo "ERROR: $*" >&2; exit 1; }

# List disks (full path)
list_disks() {
  echo
  echo "Available block devices:"
  lsblk -a -p -o NAME,TYPE,TRAN,SIZE,MODEL | grep -Ev "loop|ram" || true
  echo
}

# Normalize device: accept /dev/sdx or sdx or sdxY
normalize_device() {
  local raw=$1
  local dev
  if [[ "$raw" == /dev/* ]]; then
    dev="$raw"
  else
    dev="/dev/$raw"
  fi
  if [[ ! -b "$dev" ]]; then
    die "Block device '$dev' not found."
  fi
  echo "$dev"
}

# Returns partition device name for a disk + partition number, handling nvme and mmcblk
get_part_name() {
  local disk="$1"
  local num="$2"
  if [[ "$disk" =~ (nvme|mmcblk) ]]; then
    printf "%sp%s" "$disk" "$num"
  else
    printf "%s%s" "$disk" "$num"
  fi
}

# Return separator for default mountpoint ("" or "p")
get_part_sep() {
  local disk="$1"
  if [[ "$disk" =~ (nvme|mmcblk) ]]; then
    printf "p"
  else
    printf ""
  fi
}

# Wait for a block device node to appear, up to timeout seconds (default 10s)
wait_for_part() {
  local part="$1"
  local timeout="${2:-10}"
  local waited=0
  while [[ ! -b "$part" && $waited -lt $timeout ]]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  if [[ ! -b "$part" ]]; then
    echo "Warning: partition device $part did not appear after ${timeout}s"
    return 1
  fi
  return 0
}

# Confirm destructive action
confirm_action() {
  local target=$1
  echo
  echo "Selected: $target"
  echo "THIS WILL ERASE DATA. Type y to proceed:"
  read -rn1 -p "> " c; echo
  [[ "$c" == "y" ]] || die "Aborted by user."
}

# GUI partitioner runner
run_partitioner() {
  local cmd="$*"
  echo "Launching: $cmd"
  sudo --preserve-env=DISPLAY,XAUTHORITY sh -c "$cmd &"
  read -rp "Press ENTER when finished with the partitioner..."
}

# Ensure kernel sees partition changes and udev settled
rescan_and_settle() {
  local disk="$1"
  sudo sync || true
  sudo partprobe "$disk" || true
  sudo udevadm settle || true
  sleep 1
}

# Flashing helper
flash_image() {
  local image=$1
  local target=$2
  if [[ ! -f "$image" || ! -r "$image" ]]; then die "Image '$image' not found/readable."; fi
  if [[ ! -b "$target" ]]; then die "Target '$target' is not a block device/partition."; fi
  if mount | grep -q "^$target"; then die "Target $target appears mounted. Unmount and retry."; fi

  if [[ "$image" == *.xz ]]; then
    if command -v xzcat >/dev/null 2>&1; then
      sudo xzcat "$image" | sudo dd of="$target" bs=3M status=progress conv=fsync
    elif command -v 7z >/dev/null 2>&1; then
      sudo 7z x -so "$image" | sudo dd of="$target" bs=3M status=progress conv=fsync
    else
      die "No xzcat or 7z available."
    fi
  elif [[ "$image" == *.img || "$image" == *.iso || "$image" == *.raw ]]; then
    sudo dd if="$image" of="$target" bs=3M status=progress conv=fsync
  else
    die "Unsupported image type."
  fi

  # Ensure writes flushed
  sudo sync
  echo "Flashing complete."
}

# Partitioning, formatting, grub functions

create_gpt_partitions() {
  local disk=$1

  echo "Opening GParted to let you clear/unmount partitions for $disk"
  run_partitioner "gparted $disk"

  echo "Creating GPT label on $disk"
  sudo wipefs -a "$disk"
  sudo parted -s "$disk" mklabel gpt

  echo "Creating BIOS partition (4MiB-8MiB) for bios_grub"
  sudo parted -s "$disk" mkpart bios 4MiB 8MiB
  sudo parted -s "$disk" set 1 bios_grub on

  echo "Creating EFI partition (8MiB-4108MiB) FAT32"
  sudo parted -s "$disk" mkpart efi fat32 8MiB 4108MiB
  #sudo parted -s "$disk" set 2 boot on
  #sudo parted -s "$disk" set 2 esp on

  echo "Creating Linux partition (4108MiB to 100%) ext4"
  sudo parted -s "$disk" mkpart ext4 ext4 4108MiB 100%

  # Rescan and wait
  sudo sync
  sudo partprobe "$disk" || true
  sudo udevadm settle || true
  rescan_and_settle "$disk"

  local p1 p2 p3
  p1=$(get_part_name "$disk" 1)
  p2=$(get_part_name "$disk" 2)
  p3=$(get_part_name "$disk" 3)

  # Wait for partition nodes (helpful on slow mmc/sd)
  wait_for_part "$p1" 10 || true
  wait_for_part "$p2" 10 || true
  wait_for_part "$p3" 10 || true

  echo "Formatting partitions: $p2 as FAT32 and $p3 as ext4"
  sudo umount "$p2" 2>/dev/null || true
  sudo mkfs.vfat -F 32 -a -s 8 -I "$p2"
  sudo sync
  sudo partprobe "$disk" || true
  sudo udevadm settle || true

  sudo umount "$p3" 2>/dev/null || true
  sudo mkfs.ext4 -F -O "^has_journal,sparse_super" -m 0 "$p3" || die "mkfs.ext4 failed on $p3"
  sudo sync
  sudo partprobe "$disk" || true
  sudo udevadm settle || true

  echo "Partitions created and formatted."
  echo "Partitions on $disk:"
  sudo parted -s "$disk" print
}

# Partitioning, formatting, grub functions for MBR/msdos
create_mbr_partitions() {
  local disk=$1

  echo "Opening GParted to let you clear/unmount partitions for $disk"
  run_partitioner "gparted $disk"

  # 1. Create MBR (msdos) label instead of GPT
  echo "Creating MBR (msdos) label on $disk"
  sudo wipefs -a "$disk"
  sudo parted -s "$disk" mklabel msdos

  # 2. Create 1st partition: FAT32 (4MiB to 4104MiB = 4100MiB size)
  echo "Creating Boot partition (4MiB-4104MiB) FAT32"
  sudo parted -s "$disk" mkpart primary fat32 4MiB 4104MiB
  
  # 3. Set the boot flag on the first partition
  echo "Setting boot flag on partition 1"
  sudo parted -s "$disk" set 1 boot on

  # 4. Create 2nd partition: EXT4 (4101MiB to 100%)
  echo "Creating Linux partition (4104MiB to 100%) ext4"
  sudo parted -s "$disk" mkpart primary ext4 4104MiB 100%

  # Rescan and wait for the kernel to see the new table
  sudo sync
  sudo partprobe "$disk" || true
  sudo udevadm settle || true
  rescan_and_settle "$disk"

  local p1 p2
  p1=$(get_part_name "$disk" 1)
  p2=$(get_part_name "$disk" 2)

  # Wait for partition nodes (essential for slow SD cards)
  wait_for_part "$p1" 10 || true
  wait_for_part "$p2" 10 || true

  # 5. Format Partition 1 as FAT32
  echo "Formatting $p1 as FAT32"
  sudo umount "$p1" 2>/dev/null || true
  sudo mkfs.vfat -F 32 -a -s 8 -I "$p1"
  
  # 6. Format Partition 2 as EXT4
  echo "Formatting $p2 as ext4"
  sudo umount "$p2" 2>/dev/null || true
  sudo mkfs.ext4 -F -O "^has_journal,sparse_super" -m 0 "$p2" || die "mkfs.ext4 failed on $p2"
  
  sudo sync
  sudo partprobe "$disk" || true
  sudo udevadm settle || true

  echo "Partitions created and formatted successfully."
  echo "Final Partition Layout on $disk:"
  sudo parted -s "$disk" print
}

mount_efi() {
  local disk=$1
  local efnum=$2
  local mount_point=$3

  local part
  part=$(get_part_name "$disk" "$efnum")

  if [[ ! -b "$part" ]]; then die "EFI partition $part does not exist."; fi

  sudo mkdir -p "$mount_point"
  sudo umount "$part" 2>/dev/null || true
  sudo mount "$part" "$mount_point"
  sudo sync
  echo "Mounted $part -> $mount_point"
}

install_grub() {
  local disk=$1
  local efi_mount=$2

  # Ensure filesystem changes settled before grub install
  rescan_and_settle "$disk"

  # Ensure efi mount present
  if [[ ! -d "$efi_mount" ]]; then die "EFI mountpoint $efi_mount not found"; fi

  echo "Installing GRUB (UEFI x86_64) to $efi_mount"
  sudo grub-install --target=x86_64-efi --efi-directory="$efi_mount" --boot-directory="$efi_mount/efi" --removable || echo "UEFI grub-install returned non-zero"

  echo "Installing GRUB (BIOS i386-pc) to $disk"
  sudo grub-install --target=i386-pc "$disk" --boot-directory="$efi_mount/efi" --removable --recheck --force || echo "BIOS grub-install returned non-zero"

  sudo sync
  echo "GRUB installation attempted. Verify success messages above."
}

create_gpt_disk() {
  list_disks
  read -rp "Enter target disk (e.g., sdb or /dev/sdb): " disk_in
  disk=$(normalize_device "$disk_in")
  confirm_action "$disk"
  create_gpt_partitions "$disk"

  confirm_action "$disk"
  read -rp "Enter EFI partition number (default 2): " efnum
  efnum=${efnum:-2}

  sep=$(get_part_sep "$disk")
  read -rp "Enter mount point for EFI (default /mnt/${disk##*/}${sep}${efnum}): " mountp
  if [[ -z "$mountp" ]]; then
    mountp="/mnt/${disk##*/}${sep}${efnum}"
    echo "Using default: $mountp"
  fi

  # Wait for EFI partition node before mount
  part=$(get_part_name "$disk" "$efnum")
  wait_for_part "$part" 15 || echo "Proceeding even though $part may not exist yet"

  mount_efi "$disk" "$efnum" "$mountp"
  install_grub "$disk" "$mountp"
  echo "Done creating GPT disk and installing GRUB."
}

create_mbr_disk() {
  list_disks
  read -rp "Enter target disk (e.g., sdb or /dev/sdb): " disk_in
  disk=$(normalize_device "$disk_in")
  confirm_action "$disk"
  
  # Calls the MBR-specific version you edited earlier
  create_mbr_partitions "$disk"

  confirm_action "$disk"
  # On MBR, we use Partition 1 (FAT32) for both BIOS and EFI files
  local efnum=1
  
  sep=$(get_part_sep "$disk")
  # Default mount point for the 4100MiB FAT32 partition
  read -rp "Enter mount point for Boot/EFI (default /mnt/${disk##*/}${sep}${efnum}): " mountp
  if [[ -z "$mountp" ]]; then
    mountp="/mnt/${disk##*/}${sep}${efnum}"
    echo "Using default: $mountp"
  fi

  # Identify the partition node (e.g., /dev/sdb1)
  part=$(get_part_name "$disk" "$efnum")
  
  # Wait for the node to appear (crucial for slow micro-SD cards)
  wait_for_part "$part" 15 || echo "Proceeding even though $part may not exist yet"

  # Standard mount procedure
  sudo mkdir -p "$mountp"
  sudo mount "$part" "$mountp" || die "Failed to mount $part to $mountp"

  # Install GRUB for both modes using the same directory
  # Note: your install_grub function should use --removable for the EFI target
  install_grub "$disk" "$mountp"

  echo "Done creating MBR disk and installing Hybrid GRUB (BIOS + UEFI)."
}

install_grub_only() {
  list_disks
  read -rp "Enter disk (e.g., sdb or /dev/sdb) where EFI partition resides: " disk_in
  disk=$(normalize_device "$disk_in")

  echo "Current partitions on $disk:"
  sudo parted -s "$disk" print

  read -rp "Enter EFI partition number to mount (e.g., 2): " efnum

  sep=$(get_part_sep "$disk")
  read -rp "Enter mount point for EFI (default /mnt/${disk##*/}${sep}${efnum}): " mountp
  if [[ -z "$mountp" ]]; then
    mountp="/mnt/${disk##*/}${sep}${efnum}"
    echo "Using default: $mountp"
  fi

  part=$(get_part_name "$disk" "$efnum")
  wait_for_part "$part" 15 || echo "Proceeding even though $part may not exist yet"

  mount_efi "$disk" "$efnum" "$mountp"
  install_grub "$disk" "$mountp"
  echo "GRUB-only installation attempted."
}

show_disk_details() {
  list_disks
  read -rp "Enter disk to inspect (e.g., sdb or /dev/sdb) or ENTER to skip: " disk_in || true
  if [[ -n "${disk_in:-}" ]]; then
    disk=$(normalize_device "$disk_in")
    echo
    echo "parted print for $disk:"
    sudo parted -s "$disk" print

    echo
    echo "blkid output:"
    sudo blkid "${disk}"* || true

    echo
    echo "Detailed lsblk:"
    lsblk -a -p -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,LABEL,UUID "$disk" || true
  fi
}

main() {
  while true; do
    echo
    echo "App Need: grub-pc grub-efi-amd64-bin parted"
    echo "Main Menu:"
    echo "1) Flash Linux image (to entire device)"
    echo "2) Flash Windows image (to partition)"
    echo "3) Create GPT disk (partitions, format, install GRUB)"
    echo "4) Create MBR disk (partitions, format, install GRUB)"
    echo "5) Show disk details"
    echo "6) Install GRUB only to existing EFI partition"
    echo "q) Quit"
    read -rp "Choose an option: " choice

    case "$choice" in
      1)
        list_disks
        read -rp "Enter target device (e.g., sdb or /dev/sdb): " t
        target=$(normalize_device "$t")
        confirm_action "$target"
        run_partitioner "gparted $target"
        ls
        read -rp "Enter Linux image path (.img or .xz): " img
        flash_image "$img" "$target"
        # ensure kernel sees final state before optional gparted
        rescan_and_settle "$target"
        run_partitioner "gparted $target"
        ;;
      2)
        list_disks
        read -rp "Enter target device for partitioning (e.g., sdb or /dev/sdb): " t
        target=$(normalize_device "$t")
        confirm_action "$target"
        run_partitioner "gparted $target"
        list_disks
        read -rp "Enter partition to flash (e.g., sdb1 or /dev/sdb1): " p
        part=$(normalize_device "$p")
        confirm_action "$part"
        ls
        read -rp "Enter Windows image path (.img or .xz): " img
        flash_image "$img" "$part"
        rescan_and_settle "${part%[0-9]*}" || true
        run_partitioner "gparted $target"
        run_partitioner "gnome-disks"
        run_partitioner "gparted $target"
        sudo sync
        ;;
      3)
        create_gpt_disk
        ;;
      4)
        create_mbr_disk
        ;;
      5)
        show_disk_details
        ;;
      6)
        install_grub_only
        ;;
      q|Q)
        echo "Exiting."
        exit 0
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

main
