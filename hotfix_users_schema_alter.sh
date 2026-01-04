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

new_fn = r'''
async def _ensure_users_schema(pool):
    # максимально устойчиво: без сложного CREATE TABLE, только CREATE минимальной таблицы + ALTER
    async with pool.acquire() as conn:
        await conn.execute("CREATE TABLE IF NOT EXISTS users (id BIGSERIAL PRIMARY KEY);")

        # columns
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS tg_id BIGINT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS vk_id BIGINT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(32);")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS full_name TEXT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS current_role VARCHAR(16);")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();")

        # unique constraints через индексы (ALTER TABLE ... ADD CONSTRAINT IF NOT EXISTS нет)
        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_tg_id ON users(tg_id) WHERE tg_id IS NOT NULL;")
        await conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_users_vk_id ON users(vk_id) WHERE vk_id IS NOT NULL;")

        # обычные индексы (не обязательно, но полезно)
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);")
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);")
'''.strip("\n")

m = re.search(r"async def _ensure_users_schema\(pool\):[\s\S]*?(?=\n\n|\n@app\.|\Z)", s)
if not m:
    raise SystemExit("Cannot find _ensure_users_schema() in backend/app/main.py")

s = s[:m.start()] + new_fn + "\n\n" + s[m.end():]
p.write_text(s, encoding="utf-8")
print("OK: _ensure_users_schema replaced with ALTER-based migration")
PY

python3 -m py_compile backend/app/main.py

git add backend/app/main.py
git commit -m "Fix: users schema via ALTER (robust migration)" || true
git push origin main

# ВАЖНО: пересобираем без кеша, чтобы точно взялось новое
docker compose build --no-cache backend
docker compose up -d backend
docker compose logs -f --tail=120 backend
