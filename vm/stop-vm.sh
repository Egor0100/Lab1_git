#!/usr/bin/env bash
# Корректное выключение VM (через ACPI внутри гостя), с запасным kill.
set -uo pipefail
cd "$(dirname "$0")"

if ! [[ -f vm.pid ]] || ! kill -0 "$(cat vm.pid)" 2>/dev/null; then
  echo "VM не запущена"; rm -f vm.pid; exit 0
fi

ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    ubuntu@127.0.0.1 'sudo poweroff' 2>/dev/null

for _ in $(seq 30); do
  kill -0 "$(cat vm.pid)" 2>/dev/null || { echo "VM выключена"; rm -f vm.pid; exit 0; }
  sleep 1
done

echo "VM не выключилась за 30 с, завершаю процесс QEMU"
kill "$(cat vm.pid)"; rm -f vm.pid
