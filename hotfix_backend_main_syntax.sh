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
lines = s.splitlines()

# 1) remove any stray await lines (wherever they are)
lines = [ln for ln in lines if "await _ensure_users_schema(app.state.pool)" not in ln]

s = "\n".join(lines) + "\n"

# 2) ensure _ensure_users_schema exists (insert after imports block)
ensure_block = r'''
async def _ensure_users_schema(pool):
    sql = """
    CREATE TABLE IF NOT EXISTS users (
      id BIGSERIAL PRIMARY KEY,
      tg_id BIGINT UNIQUE,
      vk_id BIGINT UNIQUE,
      phone VARCHAR(32),
      current_role VARCHAR(16) CHECK (current_role IN ('client','driver')),
      created_at TIMESTAMPTZ DEFAULT now(),
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);
    CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);
    """
    async with pool.acquire() as conn:
        await conn.execute(sql)
'''.strip("\n")

if "_ensure_users_schema" not in s:
    # find end of import section
    ls = s.splitlines()
    insert_at = 0
    for i, ln in enumerate(ls):
        if ln.startswith("import ") or ln.startswith("from "):
            insert_at = i + 1
            continue
        # allow comments/blank lines after imports
        if insert_at and (ln.strip() == "" or ln.strip().startswith("#")):
            insert_at = i + 1
            continue
        break
    ls.insert(insert_at, "")
    ls.insert(insert_at + 1, ensure_block)
    ls.insert(insert_at + 2, "")
    s = "\n".join(ls) + "\n"

# 3) put call inside startup handler (or create one)
def add_call_into_startup(text: str) -> str:
    # find startup decorator
    m = re.search(r'@app\.on_event\(["\']startup["\']\)\s*\nasync def [a-zA-Z0-9_]+\([^\)]*\):\s*\n', text)
    if not m:
        # create new startup hook at end
        return text + '\n@app.on_event("startup")\nasync def _startup_users_schema():\n    await _ensure_users_schema(app.state.pool)\n'

    head_end = m.end()
    rest = text[head_end:]
    nxt = re.search(r"\n@\w", rest)  # next decorator
    block_end = head_end + (nxt.start() if nxt else len(rest))
    block = text[m.start():block_end]

    if "await _ensure_users_schema(app.state.pool)" in block:
        return text  # already ok

    # Insert near end of startup block (before trailing blank lines)
    blines = block.splitlines()
    # determine indentation (assume 4 spaces inside function)
    indent = "    "
    # insert before end of block
    # find last non-empty line belonging to function body (starts with indent or is blank)
    insert_idx = len(blines)
    # don’t insert after next decorator (already excluded)
    # put before trailing blanks
    while insert_idx > 0 and blines[insert_idx-1].strip() == "":
        insert_idx -= 1
    blines.insert(insert_idx, indent + "await _ensure_users_schema(app.state.pool)")
    new_block = "\n".join(blines) + "\n"

    return text[:m.start()] + new_block + text[block_end:]

s2 = add_call_into_startup(s)

p.write_text(s2, encoding="utf-8")
print("OK: patched backend/app/main.py")
PY

echo "== Check syntax =="
python3 -m py_compile backend/app/main.py

echo "== Commit & push =="
git add backend/app/main.py
git commit -m "Hotfix: fix startup schema insertion syntax" || true
git push origin main

echo "== Rebuild & restart backend =="
docker compose up -d --build backend
echo "== Tail backend logs =="
docker compose logs -f --tail=120 backend
