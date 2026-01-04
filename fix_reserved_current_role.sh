#!/usr/bin/env bash
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"

backup() { [ -f "$1" ] && cp -a "$1" "$1.bak.$TS"; }

backup backend/app/main.py
backup backend/app/users.py
backup bot_tg/app/bot.py

python3 - <<'PY'
from pathlib import Path
import re

# 1) backend/app/main.py: schema -> role (NOT current_role)
p = Path("backend/app/main.py")
s = p.read_text(encoding="utf-8", errors="ignore")

# replace column add
s = s.replace('ADD COLUMN IF NOT EXISTS current_role VARCHAR(16);',
              'ADD COLUMN IF NOT EXISTS role VARCHAR(16);')

# если где-то еще упоминается current_role в DDL — тоже убираем
s = s.replace("current_role", "role")

p.write_text(s, encoding="utf-8")

# 2) backend/app/users.py: everywhere current_role -> role
p = Path("backend/app/users.py")
s = p.read_text(encoding="utf-8", errors="ignore")
s = s.replace("current_role", "role")
p.write_text(s, encoding="utf-8")

# 3) bot_tg/app/bot.py: everywhere current_role -> role
p = Path("bot_tg/app/bot.py")
s = p.read_text(encoding="utf-8", errors="ignore")
s = s.replace("current_role", "role")
p.write_text(s, encoding="utf-8")

print("OK: replaced current_role -> role in backend + tg")
PY

python3 -m py_compile backend/app/main.py backend/app/users.py bot_tg/app/bot.py

git add backend/app/main.py backend/app/users.py bot_tg/app/bot.py
git commit -m "Fix: replace reserved current_role column with role" || true
git push origin main

# пересобираем backend без кеша, чтобы точно применилось
docker compose down
docker compose build --no-cache backend bot_tg
docker compose up -d

docker compose logs -f --tail=160 backend
