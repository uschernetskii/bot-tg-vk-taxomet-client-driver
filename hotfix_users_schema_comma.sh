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
    # отдельными запросами, чтобы не словить "склейку" строк/запятых
    create_sql = """
    CREATE TABLE IF NOT EXISTS users (
      id BIGSERIAL PRIMARY KEY,
      tg_id BIGINT UNIQUE,
      vk_id BIGINT UNIQUE,
      phone VARCHAR(32),
      full_name TEXT,
      current_role VARCHAR(16),
      created_at TIMESTAMPTZ DEFAULT now(),
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    """
    idx1 = "CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);"
    idx2 = "CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);"
    async with pool.acquire() as conn:
        await conn.execute(create_sql)
        await conn.execute(idx1)
        await conn.execute(idx2)
'''.strip("\n")

# заменить существующую функцию целиком
m = re.search(r"async def _ensure_users_schema\(pool\):[\s\S]*?(?=\n\n|\n@app\.|\Z)", s)
if not m:
    raise SystemExit("Cannot find _ensure_users_schema() in backend/app/main.py")

s = s[:m.start()] + new_fn + "\n\n" + s[m.end():]
p.write_text(s, encoding="utf-8")

print("OK: _ensure_users_schema rewritten")
PY

python3 -m py_compile backend/app/main.py

git add backend/app/main.py
git commit -m "Hotfix: fix users schema SQL (comma before current_role)" || true
git push origin main

docker compose up -d --build backend
docker compose logs -f --tail=120 backend
