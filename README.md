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
└── .github/workflows/trivy.yml   # бонус: сканирование образов Trivy
```

## Запуск (уровень 5)

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

Уровень 5 (без VM):

```
ноутбук (браузер)
   │  http://localhost:8080
   ▼
[frontend: nginx :80]  ──/api/*──▶  [backend: FastAPI :8000]
   опубликован 8080:80               порт наружу НЕ публикуется
          └──────── сеть compose (default) ────────┘
```

Для уровней 7+ схема станет такой: `ноутбук → VM (KVM) :8080 → контейнер frontend → контейнер backend`.

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

## Бонус: Trivy в GitHub Actions

Workflow `.github/workflows/trivy.yml` запускается на каждый `push` и `pull_request`, а также вручную (Actions → Trivy scan → Run workflow). Он:

1. собирает образы командой `docker compose build`, то есть ровно те, что описаны в `compose.yaml` (`lab-backend:latest`, `lab-frontend:latest`);
2. сканирует каждый образ Trivy и выводит таблицу уязвимостей уровня HIGH/CRITICAL в лог шага.

Найденные уязвимости не валят сборку (`exit-code: "0"`). Результат виден в логе шага **Trivy scan …** во вкладке Actions.

Версии закреплены намеренно: `trivy-action@0.35.0` и Trivy `v0.69.3`. В марте 2026 года старые теги экшена и релиз Trivy v0.69.4 были скомпрометированы (GHSA-69fq-xp46-6x23).
