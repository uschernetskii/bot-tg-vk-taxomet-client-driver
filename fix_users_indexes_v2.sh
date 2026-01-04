#!/usr/bin/env bash
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"

F="backend/app/main.py"
cp -a "$F" "$F.bak.$TS"

python3 - <<'PY'
from pathlib import Path

p = Path("backend/app/main.py")
s = p.read_text(encoding="utf-8", errors="ignore")

start = s.find("async def _ensure_users_schema")
if start == -1:
    raise SystemExit("Cannot find 'async def _ensure_users_schema' in backend/app/main.py")

end = s.find("async def tg_send", start)
if end == -1:
    raise SystemExit("Cannot find 'async def tg_send' after _ensure_users_schema in backend/app/main.py")

new_fn = r'''
async def _ensure_users_schema(pool):
    # устойчиво: минимальный CREATE + ALTER + индексы
    async with pool.acquire() as conn:
        await conn.execute("CREATE TABLE IF NOT EXISTS users (id BIGSERIAL PRIMARY KEY);")

        # columns (NULL допустимы)
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS tg_id BIGINT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS vk_id BIGINT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(32);")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS full_name TEXT;")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS role VARCHAR(16);")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now();")
        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();")

        # ВАЖНО:
        # раньше могли быть partial unique indexes с WHERE ... — они НЕ подходят для ON CONFLICT (tg_id)/(vk_id).
        # Поэтому: DROP + CREATE нормальных UNIQUE по tg_id/vk_id (NULL'ов может быть много — это норм).
        await conn.execute("DROP INDEX IF EXISTS uq_users_tg_id;")
        await conn.execute("DROP INDEX IF EXISTS uq_users_vk_id;")

        await conn.execute("CREATE UNIQUE INDEX uq_users_tg_id ON users(tg_id);")
        await conn.execute("CREATE UNIQUE INDEX uq_users_vk_id ON users(vk_id);")

        # обычные индексы (опционально)
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);")
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);")
'''.strip("\n")

s2 = s[:start] + new_fn + "\n\n" + s[end:]
p.write_text(s2, encoding="utf-8")

print("OK: _ensure_users_schema replaced cleanly")
PY

python3 -m py_compile backend/app/main.py

git add backend/app/main.py
git commit -m "Fix: recreate users UNIQUE indexes (support ON CONFLICT)" || true
git push origin main

docker compose up -d --build backend
docker compose logs -f --tail=120 backend
