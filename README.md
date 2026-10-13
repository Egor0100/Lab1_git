# Лабораторная: Docker Compose, KVM и Ansible

Небольшое приложение из двух сервисов:

- **backend**: FastAPI (Python 3.12), отдаёт JSON на `/api/info` и `/api/health`;
- **frontend**: nginx, отдаёт `index.html` и проксирует `/api/*` в бэкенд.

Страница при загрузке делает `fetch("/api/info")` и показывает ответ бэкенда: сообщение, имя контейнера, время и счётчик запросов.

## Структура

```
.
├── backend/            # FastAPI: app.py, requirements.txt, Dockerfile
├── frontend/           # nginx: index.html, nginx.conf, Dockerfile
├── compose.yaml
├── vm/                 # start-vm.sh / stop-vm.sh: создание и запуск VM в KVM (QEMU)
├── ansible/            # inventory.ini, ansible.cfg, playbook.yml
└── .github/workflows/trivy.yml   # бонус: сканирование образов Trivy
```

## Запуск

Нужен Docker с Compose v2 (на macOS: Docker Desktop, OrbStack или Colima).

```bash
docker compose up -d --build
docker compose ps        # оба сервиса Up, backend — (healthy)
```

**Адрес приложения:** http://localhost:8080

Остановить:

```bash
docker compose down
```

## Схема

без VM:

```
ноутбук (браузер)
   │  http://localhost:8080
   ▼
[frontend: nginx :80]  ──/api/*──▶  [backend: FastAPI :8000]
   опубликован 8080:80               порт наружу НЕ публикуется
          └──────── сеть compose (default) ────────┘
```

VM в KVM:

```
ноутбук: MacBook M1, Fedora Asahi Remix (хост KVM)
   │  браузер → http://localhost:8080        ansible → 127.0.0.1:2222
   ▼                                              │
 QEMU user-net: проброс :8080 → VM:8080,  127.0.0.1:2222 → VM:22
   ▼
VM lab-vm: Ubuntu 24.04 arm64, KVM (-accel kvm -cpu host)
   │  Docker + Compose, проект в /opt/lab
   ▼
[frontend: nginx :80]  ──/api/*──▶  [backend: FastAPI :8000]
   опубликован 8080:80 на VM
```

Браузер обращается только к nginx. Запрос `/api/info` уходит на тот же origin, поэтому CORS не нужен. Nginx пересылает его на `http://backend:8000`: имя `backend` разрешает встроенный DNS Docker-сети compose.

## Проверка связи фронтенда с бэкендом

1. Откройте http://localhost:8080. Должен появиться зелёный статус «бэкенд отвечает» и имя контейнера. При нажатии «Запросить ещё раз» счётчик растёт.
2. Из терминала через фронтенд (тот же путь, что у браузера):
   ```bash
   curl http://localhost:8080/api/info
   ```
3. Убедитесь, что бэкенд не торчит наружу, а доступен только через nginx:
   ```bash
   curl http://localhost:8000/api/info   # должно быть "Connection refused"
   ```
4. Проверьте изнутри сети compose:
   ```bash
   docker compose exec frontend wget -qO- http://backend:8000/api/health
   ```
5. Посмотрите логи (видно, как nginx и uvicorn обрабатывают запросы):
   ```bash
   docker compose logs -f
   ```

## VM в KVM на Asahi Linux

Хост: MacBook на Apple M1, Fedora Asahi Remix (нативный Linux на Apple Silicon, ядро работает в EL2, KVM доступен). macOS на M1 не даёт KVM и не поддерживает вложенную виртуализацию, поэтому KVM запускается из Asahi.

### Проверка, что KVM работает на хосте

```bash
uname -m                          # aarch64
ls -l /dev/kvm                    # устройство есть, есть права rw
sudo dmesg | grep -i kvm          # инициализация KVM/hyp
```

### Подготовка хоста (один раз)

```bash
sudo dnf install -y qemu edk2-aarch64 genisoimage ansible git
sudo usermod -aG kvm "$USER"      # если на /dev/kvm нет прав; затем перелогиниться
ssh-keygen -t ed25519             # если ключа ещё нет
```

Группа `@virtualization` (libvirt/virt-manager) не используется: в документации Asahi она помечена как неподдерживаемая. VM запускается чистым QEMU с `-accel kvm`.

### Создание VM (вручную)

```bash
./vm/start-vm.sh                  # скачивает Ubuntu 24.04 arm64, создаёт диск и cloud-init, запускает VM
ssh -p 2222 ubuntu@127.0.0.1      # через ~1 мин
systemd-detect-virt               # внутри VM: должно вывести "kvm"
```

Ручной вариант без Ansible: скопировать проект в VM и запустить Compose:

```bash
scp -P 2222 -r backend frontend compose.yaml ubuntu@127.0.0.1:~/lab/
ssh -p 2222 ubuntu@127.0.0.1
sudo apt update && sudo apt install -y docker.io docker-compose-v2 docker-buildx
cd ~/lab && sudo docker compose up -d --build
```

Приложение: **http://localhost:8080** в браузере на ноутбуке (порт проброшен QEMU в VM).

Выключить VM: `./vm/stop-vm.sh`.

### Ansible

```bash
cd ansible
ansible lab -m ping               # проверка подключения к VM
ansible-playbook playbook.yml     # 1-й запуск: ставит Docker, копирует файлы, запускает Compose
ansible-playbook playbook.yml     # 2-й запуск: failed=0, changed=0 (или минимум), приложение работает
```

Playbook:

1. ждёт окончания cloud-init;
2. ставит `docker.io`, `docker-compose-v2`, `docker-buildx`;
3. копирует `compose.yaml`, `backend/`, `frontend/` в `/opt/lab`;
4. выполняет `docker compose up -d --build`;
5. проверяет `GET /api/info` через фронтенд.

Идемпотентность обеспечивается так:

- модули `apt`, `copy`, `file`, `service` и `user` сами сравнивают текущее состояние с нужным;
- `docker compose up -d` пересоздаёт только изменившиеся контейнеры;
- `changed_when` для шага Compose срабатывает, только если контейнер реально создан или перезапущен.

### Если что-то не работает

| Симптом | Причина / решение |
|---|---|
| `Нет /dev/kvm` | не Asahi или ядро без KVM; проверить `uname -a`, `dmesg \| grep -i kvm` |
| `Permission denied` на `/dev/kvm` | `sudo usermod -aG kvm $USER`, перелогиниться |
| SSH: `Connection refused` на 2222 | VM ещё грузится: `tail -f vm/serial.log` |
| Ansible: `UNREACHABLE` | проверить `ssh -p 2222 ubuntu@127.0.0.1`, путь к ключу в `inventory.ini` |
| Страница не открывается | в VM: `sudo docker compose -f /opt/lab/compose.yaml ps`, `curl localhost:8080/api/info` |

## Trivy в GitHub Actions

Workflow `.github/workflows/trivy.yml` запускается на каждый `push` и `pull_request`, а также вручную (Actions → Trivy scan → Run workflow). Он:

1. собирает образы командой `docker compose build`, то есть ровно те, что описаны в `compose.yaml` (`lab-backend:latest`, `lab-frontend:latest`);
2. сканирует каждый образ Trivy и выводит таблицу уязвимостей уровня HIGH/CRITICAL в лог шага.

Найденные уязвимости не валят сборку (`exit-code: "0"`). Результат виден в логе шага **Trivy scan …** во вкладке Actions.

Версии закреплены намеренно: `trivy-action@0.35.0` и Trivy `v0.69.3`. В марте 2026 года старые теги экшена и релиз Trivy v0.69.4 были скомпрометированы (GHSA-69fq-xp46-6x23).
