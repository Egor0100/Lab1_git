import os
import socket
from datetime import datetime, timezone

from fastapi import FastAPI

app = FastAPI(title="Lab backend")

# Простой счётчик в памяти — видно, что каждый запрос реально доходит до бэкенда
request_count = 0


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/info")
def info():
    global request_count
    request_count += 1
    return {
        "message": "Привет от бэкенда!",
        "hostname": socket.gethostname(),  # ID контейнера бэкенда
        "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "requests": request_count,
        "env": os.getenv("APP_ENV", "dev"),
    }
