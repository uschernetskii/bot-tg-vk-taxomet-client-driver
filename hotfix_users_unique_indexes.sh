#!/usr/bin/env bash
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"

F="backend/app/main.py"
cp -a "$F" "$F.bak.$TS"

python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/main.py")
s = p.read_text(encoding="utf-8", errors="ignore")

# Найдём блок _ensure_users_schema и заменим только часть с индексами
m = re.search(r"async def _ensure_users_schema\(pool\):[\s\S]*?(?=\n\n|\nasync def |\n@app\.|\Z)", s)
if not m:
    raise SystemExit("Cannot find _ensure_users_schema()")

block = m.group(0)

# Вставим создание НЕчастичных unique index (под ON CONFLICT)
# и оставим обычные индексы тоже
block_new = re.sub(
    r'await conn\.execute\("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_tg_id ON users\(tg_id\) WHERE tg_id IS NOT NULL;"\)\s*\n'
    r'\s*await conn\.execute\("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_vk_id ON users\(vk_id\) WHERE vk_id IS NOT NULL;"\)\s*\n',
    '        # unique индексы без WHERE (нужны для ON CONFLICT (tg_id)/(vk_id))\n'
    '        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_tg_id ON users(tg_id);")\n'
    '        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_vk_id ON users(vk_id);")\n',
    block
)

# Если вдруг тех строк уже нет (или отличаются), просто добавим нужные unique индексы перед обычными индексами
if block_new == block:
    block_new = block.replace(
        '        # обычные индексы (не обязательно, но полезно)\n',
        '        # unique индексы без WHERE (нужны для ON CONFLICT (tg_id)/(vk_id))\n'
        '        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_tg_id ON users(tg_id);")\n'
        '        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_vk_id ON users(vk_id);")\n\n'
        '        # обычные индексы (не обязательно, но полезно)\n'
    )

s = s[:m.start()] + block_new + s[m.end():]
p.write_text(s, encoding="utf-8")
print("OK: patched users unique indexes")
PY

python3 -m py_compile backend/app/main.py

git add backend/app/main.py
git commit -m "Fix: add non-partial UNIQUE indexes for users (ON CONFLICT)" || true
git push origin main

docker compose up -d --build backend
docker compose logs -f --tail=120 backend
