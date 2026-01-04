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

# Найдём функцию _ensure_users_schema и заменим в ней блок индексов на drop+recreate
m = re.search(r"async def _ensure_users_schema\(pool\):[\s\S]*?(?=\n\n|\nasync def |\n@app\.|\Z)", s)
if not m:
    raise SystemExit("Cannot find _ensure_users_schema()")

block = m.group(0)

# выкинем любые строки, где создаются uq_users_* и idx_users_*
lines = block.splitlines()
out = []
for line in lines:
    if "uq_users_tg_id" in line or "uq_users_vk_id" in line:
        continue
    if "idx_users_tg_id" in line or "idx_users_vk_id" in line:
        continue
    out.append(line)

block = "\n".join(out)

# вставим наш правильный блок индексов перед концом функции (перед последней пустотой)
insert = """
        # ВАЖНО: ранее могли быть partial unique indexes с WHERE ... (они не подходят для ON CONFLICT)
        # Поэтому всегда: DROP + CREATE нормальных UNIQUE
        await conn.execute("DROP INDEX IF EXISTS uq_users_tg_id;")
        await conn.execute("DROP INDEX IF EXISTS uq_users_vk_id;")

        await conn.execute("CREATE UNIQUE INDEX uq_users_tg_id ON users(tg_id);")
        await conn.execute("CREATE UNIQUE INDEX uq_users_vk_id ON users(vk_id);")

        # дополнительные индексы (опционально)
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);")
        await conn.execute("CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);")
""".rstrip()

# вставим перед последней строкой функции (обычно это конец блока)
# найдём место после последнего ALTER TABLE ... / before function ends
if "await conn.execute" in block:
    # вставим после последнего "ALTER TABLE users ADD COLUMN"
    parts = block.splitlines()
    last_i = 0
    for i, ln in enumerate(parts):
        if "ALTER TABLE users ADD COLUMN" in ln:
            last_i = i
    # вставляем после блока добавления колонок (ещё +1 чтобы после пустых)
    j = last_i + 1
    parts.insert(j, insert)
    block = "\n".join(parts)
else:
    raise SystemExit("Unexpected _ensure_users_schema block")

s = s[:m.start()] + block + "\n\n" + s[m.end():]
p.write_text(s, encoding="utf-8")
print("OK: patched schema indexes (drop+recreate unique)")
PY

python3 -m py_compile backend/app/main.py

git add backend/app/main.py
git commit -m "Fix: drop partial unique indexes and recreate proper UNIQUE for ON CONFLICT" || true
git push origin main

# пересобираем backend (можно без no-cache, но надежнее так)
docker compose build --no-cache backend
docker compose up -d backend

docker compose logs -f --tail=160 backend
