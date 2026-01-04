import os
from fastapi import FastAPI
app = FastAPI()

# Это "задел". Сейчас VK обработка идёт в backend (/vk/callback).
# Здесь потом добавим LongPoll / Messages API / единый роутинг.

@app.get("/health")
async def health():
  return {"ok": True, "vk_stub": True, "note": "enable profile vk later"}
