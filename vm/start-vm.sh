#!/usr/bin/env bash
# Создание и запуск Linux VM (Ubuntu 24.04 arm64) в KVM на Asahi Linux (Apple Silicon).
#
# Используется чистый QEMU + KVM, без libvirt: в документации Asahi группа
# @virtualization (libvirt/virt-manager) помечена как неподдерживаемая.
#
# Сеть — user-mode (slirp) с пробросом портов:
#   ноутбук 127.0.0.1:2222 -> VM :22    (SSH для Ansible)
#   ноутбук 0.0.0.0:8080   -> VM :8080  (фронтенд приложения)
#
# Первый запуск: скачивает образ, создаёт диск и cloud-init (пользователь ubuntu + ваш SSH-ключ).
# Повторные запуски: просто стартуют ту же VM с тем же диском.
set -euo pipefail

cd "$(dirname "$0")"

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img"
BASE_IMG="noble-base.img"
DISK="lab-vm.qcow2"
SEED="seed.iso"
FIRMWARE="/usr/share/edk2/aarch64/QEMU_EFI.fd"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
RAM_MB="${RAM_MB:-2048}"
CPUS="${CPUS:-2}"

# --- проверки окружения ---------------------------------------------------
[[ -e /dev/kvm ]] || { echo "Нет /dev/kvm — KVM недоступен на этом хосте"; exit 1; }
[[ -r /dev/kvm && -w /dev/kvm ]] || { echo "Нет прав на /dev/kvm: sudo usermod -aG kvm \$USER и перелогиньтесь"; exit 1; }
[[ -f "$FIRMWARE" ]] || { echo "Нет UEFI-прошивки $FIRMWARE: sudo dnf install edk2-aarch64"; exit 1; }
[[ -f "$SSH_PUBKEY" ]] || { echo "Нет SSH-ключа $SSH_PUBKEY: ssh-keygen -t ed25519"; exit 1; }

if [[ -f vm.pid ]] && kill -0 "$(cat vm.pid)" 2>/dev/null; then
  echo "VM уже запущена (PID $(cat vm.pid))"; exit 0
fi

# --- образ и диск (только при первом запуске) -----------------------------
if [[ ! -f "$BASE_IMG" ]]; then
  echo ">> Скачиваю Ubuntu 24.04 cloud image (arm64)…"
  curl -fL -o "$BASE_IMG.part" "$IMG_URL" && mv "$BASE_IMG.part" "$BASE_IMG"
fi

if [[ ! -f "$DISK" ]]; then
  echo ">> Создаю диск VM 20G поверх базового образа…"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" 20G
fi

# --- cloud-init: пользователь ubuntu с вашим SSH-ключом -------------------
if [[ ! -f "$SEED" ]]; then
  echo ">> Готовлю cloud-init…"
  cat > user-data <<EOF
#cloud-config
hostname: lab-vm
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_PUBKEY")
ssh_pwauth: false
EOF
  printf 'instance-id: lab-vm-001\nlocal-hostname: lab-vm\n' > meta-data
  genisoimage -quiet -output "$SEED" -volid cidata -joliet -rock user-data meta-data
fi

# --- привязка к производительным ядрам -------------------------------------
# У Apple Silicon два типа ядер; vCPU, кочующий между ними, может падать.
# CPU part: M1 0x023, M1 Pro 0x025, M1 Max 0x029, M2 0x033/0x035/0x039 (P-ядра).
PCORES=$(awk '/^processor/{p=$3} /^CPU part/{ if ($4 ~ /^0x0(23|25|29|33|35|39)$/) printf "%s%s", (n++ ? "," : ""), p }' /proc/cpuinfo)
TASKSET=()
if [[ -n "$PCORES" ]]; then
  TASKSET=(taskset -c "$PCORES")
  echo ">> Привязка к P-ядрам: $PCORES"
fi

# --- запуск ----------------------------------------------------------------
echo ">> Запускаю VM (KVM, ${CPUS} vCPU, ${RAM_MB} MB)…"
"${TASKSET[@]}" qemu-system-aarch64 \
  -name lab-vm \
  -M virt -accel kvm -cpu host \
  -smp "$CPUS" -m "$RAM_MB" \
  -bios "$FIRMWARE" \
  -drive if=virtio,file="$DISK",format=qcow2 \
  -drive if=virtio,file="$SEED",format=raw,readonly=on \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp::8080-:8080 \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci \
  -display none \
  -serial file:serial.log \
  -pidfile vm.pid \
  -daemonize

echo ">> VM запущена (PID $(cat vm.pid)). Лог консоли: vm/serial.log"
echo ">> Через ~1 минуту: ssh -p 2222 ubuntu@127.0.0.1"
