#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"

# backups
cp -a backend/app/main.py "backend/app/main.py.bak.$TS" 2>/dev/null || true
cp -a backend/app/users.py "backend/app/users.py.bak.$TS" 2>/dev/null || true
cp -a bot_tg/app/bot.py "bot_tg/app/bot.py.bak.$TS" 2>/dev/null || true

python3 - <<'PY'
from pathlib import Path
import re

# ---------- patch backend/app/main.py (schema) ----------
p = Path("backend/app/main.py")
s = p.read_text(encoding="utf-8", errors="ignore")

if "ui_message_id" not in s:
    marker = '        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT now();")'
    if marker not in s:
        raise SystemExit("main.py: cannot find marker line for updated_at in _ensure_users_schema()")
    insert = '\n        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS ui_chat_id BIGINT;")' \
             '\n        await conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS ui_message_id BIGINT;")\n'
    s = s.replace(marker, marker + insert)
    p.write_text(s, encoding="utf-8")
    print("OK: main.py schema extended (ui_chat_id/ui_message_id)")
else:
    print("SKIP: main.py already has ui_message_id")

# ---------- patch backend/app/users.py (endpoint + selects) ----------
p = Path("backend/app/users.py")
s = p.read_text(encoding="utf-8", errors="ignore")

# расширяем SELECT списки
s = s.replace(
    "SELECT tg_id, vk_id, phone, full_name, role FROM users",
    "SELECT tg_id, vk_id, phone, full_name, role, ui_chat_id, ui_message_id FROM users"
)

# добавляем модель SetUiMessageIn
if "class SetUiMessageIn" not in s:
    m = re.search(r"class SetRoleIn\(BaseModel\):[\s\S]*?\n\n", s)
    if not m:
        raise SystemExit("users.py: cannot find SetRoleIn block")
    insert = """class SetUiMessageIn(BaseModel):
    platform: str  # tg|vk
    external_id: int
    chat_id: int
    message_id: int

"""
    s = s[:m.end()] + insert + s[m.end():]
    print("OK: users.py added SetUiMessageIn")
else:
    print("SKIP: users.py already has SetUiMessageIn")

# добавляем endpoint /set_ui_message
if '@router.post("/set_ui_message"' not in s:
    m = re.search(r'@router\.post\("/set_phone"', s)
    if not m:
        raise SystemExit("users.py: cannot find @router.post('/set_phone') to insert before it")
    endpoint = """@router.post("/set_ui_message", dependencies=[Depends(require_internal)])
async def set_ui_message(payload: SetUiMessageIn, request: Request):
    if payload.platform not in ("tg", "vk"):
        raise HTTPException(status_code=400, detail="platform must be tg|vk")
    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(
            f\"\"\"
            INSERT INTO users ({field}, ui_chat_id, ui_message_id, updated_at)
            VALUES ($1, $2, $3, now())
            ON CONFLICT ({field})
            DO UPDATE SET
                ui_chat_id=EXCLUDED.ui_chat_id,
                ui_message_id=EXCLUDED.ui_message_id,
                updated_at=now()
            \"\"\",
            payload.external_id,
            int(payload.chat_id),
            int(payload.message_id),
        )
        row = await conn.fetchrow(
            f"SELECT tg_id, vk_id, phone, full_name, role, ui_chat_id, ui_message_id FROM users WHERE {field}=$1",
            payload.external_id,
        )
        return dict(row)

"""
    s = s[:m.start()] + endpoint + s[m.start():]
    print("OK: users.py added /set_ui_message endpoint")
else:
    print("SKIP: users.py already has /set_ui_message endpoint")

p.write_text(s, encoding="utf-8")

# ---------- patch bot_tg/app/bot.py (single UI message + delete user messages) ----------
p = Path("bot_tg/app/bot.py")
s = p.read_text(encoding="utf-8", errors="ignore")

if "async def ui_send" not in s:
    # вставим safe_delete + ui_send сразу после get_user_tg
    m = re.search(
        r"async def get_user_tg\(tg_id: int\):\n\s+return await backend_get\(f\"/api/users/by_tg/\{tg_id\}\"\)\n\n",
        s
    )
    if not m:
        raise SystemExit("bot.py: cannot find get_user_tg() block")

    helpers = """async def safe_delete(m: Message):
    \"\"\"Best-effort delete user's message to keep chat clean.\"\"\"
    try:
        await m.delete()
    except Exception:
        return


async def ui_send(m: Message, text: str, reply_markup=None, parse_mode=None):
    \"\"\"Keep a single 'UI' bot message by deleting the previous one, then sending a new one.\"\"\"
    tg_id = int(m.from_user.id)
    chat_id = int(m.chat.id)

    # try to delete previous UI message (stored in backend)
    prev = await get_user_tg(tg_id)
    if prev:
        prev_chat = prev.get("ui_chat_id") or chat_id
        prev_mid = prev.get("ui_message_id")
        if prev_mid:
            try:
                await bot.delete_message(int(prev_chat), int(prev_mid))
            except Exception:
                pass

    sent = await bot.send_message(
        chat_id,
        text,
        reply_markup=reply_markup,
        parse_mode=parse_mode,
        disable_web_page_preview=True,
    )

    # persist new UI message id even if phone/role not set yet
    await backend_post("/api/users/set_ui_message", {
        "platform": "tg",
        "external_id": tg_id,
        "chat_id": chat_id,
        "message_id": int(sent.message_id),
    })
    return sent

"""
    s = s[:m.end()] + helpers + s[m.end():]
    print("OK: bot.py added ui_send/safe_delete helpers")
else:
    print("SKIP: bot.py already has ui_send")

# заменяем m.answer -> ui_send (глобально)
s = s.replace("await m.answer(", "await ui_send(m, ")

# добавляем safe_delete в начало ключевых message-handlers (чтобы удалять нажатия кнопок)
def add_safe_delete(fn_name: str):
    nonlocal_s = s
    pattern = rf"(async def {re.escape(fn_name)}\(m: Message\):\n)"
    return re.sub(pattern, rf"\\1    await safe_delete(m)\n", nonlocal_s, count=1)

for fn in ["cmd_start", "switch_role", "back", "map_open", "order", "driver_geo_menu", "reg_driver", "vpn", "location", "webapp"]:
    s = re.sub(rf"(async def {re.escape(fn)}\(m: Message\):\n)", rf"\\1    await safe_delete(m)\n", s, count=1)

# on_contact делаем через try/finally, чтобы контакт всегда удалялся
m = re.search(r"@dp\.message\(F\.contact\)\nasync def on_contact\(m: Message\):[\s\S]*?\n\n@dp\.callback_query", s)
if m:
    block = m.group(0)
    func = block.split("\n\n@dp.callback_query")[0]
    lines = func.splitlines()
    deco = lines[0]
    defline = lines[1]
    body = lines[2:]

    # убираем любые прямые safe_delete (если были) и комментарии
    body = [ln for ln in body if ln.strip() != "await safe_delete(m)" and "delete contact message" not in ln]

    # вычищаем пустые в начале
    while body and body[0].strip() == "":
        body = body[1:]

    # оборачиваем в try/finally
    indented = []
    for ln in body:
        if ln.startswith("    "):
            indented.append("        " + ln[4:])
        else:
            indented.append("        " + ln)

    new_func = "\n".join([deco, defline, "    try:"] + indented + ["    finally:", "        await safe_delete(m)"])
    s = s[:m.start()] + new_func + "\n\n@dp.callback_query" + s[m.end():]
    print("OK: bot.py on_contact wrapped with try/finally delete")
else:
    print("WARN: bot.py cannot find on_contact block to wrap (skipped)")

Path("bot_tg/app/bot.py").write_text(s, encoding="utf-8")

# sanity compile
import py_compile
py_compile.compile("backend/app/main.py", doraise=True)
py_compile.compile("backend/app/users.py", doraise=True)
py_compile.compile("bot_tg/app/bot.py", doraise=True)
print("OK: python compile passed")
PY

# build & restart
docker compose build --no-cache backend bot_tg
docker compose up -d backend bot_tg

# quick log tail
echo "== backend logs =="
docker compose logs --tail=80 backend || true
echo "== bot_tg logs =="
docker compose logs --tail=80 bot_tg || true

# commit & push
git add -A
git commit -m "TG: single UI message + auto-delete user inputs" || true
git push origin main
echo "DONE"
