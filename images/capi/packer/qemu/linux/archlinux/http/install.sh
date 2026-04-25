#!/usr/bin/env bash

set -euxo pipefail

DISK="$(
  lsblk -dpno NAME,TYPE | awk '
    $2 == "disk" && $1 !~ /^\/dev\/(fd|sr|loop)/ {
      if ($1 ~ /^\/dev\/(vd|sd|nvme|xvd)/) {
        print $1
        exit
      }
    }
  '
)"
if [[ -z "${DISK}" ]]; then
  echo "No target disk found" >&2
  exit 1
fi

if [[ "${DISK}" == *"nvme"* || "${DISK}" == *"mmcblk"* ]]; then
  PART="${DISK}p1"
else
  PART="${DISK}1"
fi

timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring

parted -s "${DISK}" mklabel msdos
parted -s "${DISK}" mkpart primary ext4 1MiB 100%
udevadm settle
mkfs.ext4 -F "${PART}"
mount "${PART}" /mnt

pacstrap -K /mnt \
  audit \
  base \
  chrony \
  conntrack-tools \
  curl \
  cloud-init \
  grub \
  iptables \
  jq \
  linux \
  linux-firmware \
  nftables \
  openssh \
  pacman-contrib \
  python \
  python-netifaces \
  python-pip \
  qemu-guest-agent \
  socat \
  sudo

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt env \
  ENCRYPTED_SSH_PASSWORD='$6$HAyZllGXEhjmTubm$miT.hPmXIhfE/QCcRbgykx4.kgZWxcKeOOFaJJo/EAhJQEnxQ.brJ3A683NlvvsYH97103Bb9I2AYvmH81nOJ.' \
  DISK="${DISK}" \
  PART="${PART}" \
  /bin/bash <<'EOF'
set -euxo pipefail

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
cat >/etc/locale.conf <<'LOCALE'
LANG=en_US.UTF-8
LOCALE

cat >/etc/hostname <<'HOSTNAME'
archlinux
HOSTNAME

cat >/etc/hosts <<'HOSTS'
127.0.0.1 localhost
::1 localhost
127.0.1.1 archlinux.localdomain archlinux
HOSTS

mkdir -p /etc/systemd/network
cat >/etc/systemd/network/20-wired.network <<'NETWORK'
[Match]
Name=en*

[Network]
DHCP=yes
NETWORK

useradd -m -G wheel -s /bin/bash builder
usermod --password "${ENCRYPTED_SSH_PASSWORD}" builder
install -d -m 0750 /etc/sudoers.d
cat >/etc/sudoers.d/10-builder <<'SUDOERS'
builder ALL=(ALL) NOPASSWD:ALL
SUDOERS
chmod 0440 /etc/sudoers.d/10-builder

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

systemctl enable sshd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
systemctl enable qemu-guest-agent

grub-install --target=i386-pc --no-floppy "${DISK}"
ROOT_UUID="$(blkid -s UUID -o value "${PART}")"
cat >/boot/grub/grub.cfg <<GRUB
set default=0
set timeout=0

menuentry 'Arch Linux' {
    linux /boot/vmlinuz-linux root=UUID=${ROOT_UUID} rw
    initrd /boot/initramfs-linux.img
}
GRUB
EOF

sync
umount -R /mnt
reboot
