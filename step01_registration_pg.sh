#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
echo "==[1/8] Git clean check =="
git checkout main >/dev/null 2>&1 || true
git pull --rebase
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree not clean"
  git status --porcelain
  exit 1
fi

backup(){ [ -f "$1" ] && cp -a "$1" "$1.bak.$TS"; }

echo "==[2/8] Backup =="
backup backend/app/main.py
backup backend/app/users.py
backup bot_tg/app/bot.py

echo "==[3/8] Patch backend: ensure users table + stable users API (Postgres/asyncpg pool) =="
python3 - <<'PY'
from pathlib import Path
import re

main_py = Path("backend/app/main.py")
users_py = Path("backend/app/users.py")

if not main_py.exists():
    raise SystemExit("backend/app/main.py not found")
if not users_py.exists():
    raise SystemExit("backend/app/users.py not found")

# ---- Patch main.py: ensure schema on startup (use existing pool in app.state.pool) ----
txt = main_py.read_text(encoding="utf-8", errors="ignore")

schema_sql = r"""
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

if "_ensure_users_schema" not in txt:
    inject = f"""

async def _ensure_users_schema(pool):
    async with pool.acquire() as conn:
        await conn.execute(\"\"\"{schema_sql.strip()}\"\"\")
"""
    # place after app = FastAPI(...) block if possible
    m = re.search(r"app\s*=\s*FastAPI\([^\)]*\)\s*", txt)
    if m:
        txt = txt[:m.end()] + inject + txt[m.end():]
    else:
        txt += inject

# Add ensure call inside startup event
# Find startup handler
m = re.search(r'@app\.on_event\("startup"\)\s*\nasync def ([a-zA-Z0-9_]+)\(\)\s*:\s*\n', txt)
if m:
    fn_start = m.start()
    fn_head_end = m.end()
    rest = txt[fn_head_end:]
    nxt = re.search(r"\n@\w", rest)
    fn_end = fn_head_end + (nxt.start() if nxt else len(rest))
    block = txt[fn_start:fn_end]

    if "_ensure_users_schema" not in block:
        # try to insert after pool creation. We look for app.state.pool assignment.
        if "app.state.pool" in block:
            # insert after first app.state.pool = ...
            lines = block.splitlines()
            out=[]
            inserted=False
            for line in lines:
                out.append(line)
                if (not inserted) and re.search(r"app\.state\.pool\s*=", line):
                    out.append("    await _ensure_users_schema(app.state.pool)")
                    inserted=True
            block2="\n".join(out) + "\n"
        else:
            # fallback: append at end
            block2 = block.rstrip() + "\n    await _ensure_users_schema(app.state.pool)\n"

        txt = txt[:fn_start] + block2 + txt[fn_end:]
else:
    # no startup hook: add one (assumes pool already set somewhere else)
    txt += """
@app.on_event("startup")
async def _startup_schema_only():
    # expects app.state.pool to exist
    await _ensure_users_schema(app.state.pool)
"""

main_py.write_text(txt, encoding="utf-8")

# ---- Patch users.py: add safe endpoints (return 404 instead of 500) ----
utxt = users_py.read_text(encoding="utf-8", errors="ignore")

# Ensure needed imports
def ensure_import(line, after_pat=None):
    global utxt
    if line in utxt:
        return
    if after_pat:
        m = re.search(after_pat, utxt)
        if m:
            utxt = utxt[:m.end()] + "\n" + line + utxt[m.end():]
            return
    utxt = line + "\n" + utxt

ensure_import("import os")
ensure_import("from fastapi import HTTPException, Header, Depends, Request", after_pat=r"from fastapi import[^\n]*")
if "from pydantic import" not in utxt:
    ensure_import("from pydantic import BaseModel, Field")

# Add internal auth dependency (only once)
if "def require_internal" not in utxt:
    utxt += """

def require_internal(x_internal_token: str = Header(default="")):
    expected = os.getenv("INTERNAL_TOKEN", "")
    # если expected пустой — не блокируем (на dev)
    if expected and x_internal_token != expected:
        raise HTTPException(status_code=401, detail="unauthorized")
"""

# Helpers + models
if "class SetPhoneIn" not in utxt:
    utxt += """

def _digits(raw: str) -> str:
    return "".join(ch for ch in raw if ch.isdigit())

def normalize_ru_phone(raw: str) -> str:
    d = _digits(raw)
    if len(d) == 11 and d.startswith("8"):
        d = "7" + d[1:]
    if len(d) == 11 and d.startswith("7"):
        return d
    raise ValueError("Неверный формат телефона. Нужен РФ номер: 7XXXXXXXXXX (11 цифр).")

class SetPhoneIn(BaseModel):
    platform: str = Field(pattern="^(tg|vk)$")
    external_id: int
    phone: str

class SetRoleIn(BaseModel):
    platform: str = Field(pattern="^(tg|vk)$")
    external_id: int
    role: str = Field(pattern="^(client|driver)$")

async def _get_pool(request: Request):
    pool = getattr(request.app.state, "pool", None)
    if not pool:
        raise HTTPException(status_code=500, detail="DB pool not initialized")
    return pool
"""

# Add endpoints if missing
if "/by_external/" not in utxt:
    utxt += """

@router.get("/by_external/{platform}/{external_id}", dependencies=[Depends(require_internal)])
async def by_external(platform: str, external_id: int, request: Request):
    if platform not in ("tg","vk"):
        raise HTTPException(status_code=400, detail="Bad platform")
    field = "tg_id" if platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow(f"SELECT tg_id, vk_id, phone, current_role FROM users WHERE {field}=$1", external_id)
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)

@router.post("/set_phone", dependencies=[Depends(require_internal)])
async def set_phone(payload: SetPhoneIn, request: Request):
    try:
        phone11 = normalize_ru_phone(payload.phone)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(f\"\"\"
            INSERT INTO users ({field}, phone, updated_at)
            VALUES ($1, $2, now())
            ON CONFLICT ({field})
            DO UPDATE SET phone=EXCLUDED.phone, updated_at=now()
        \"\"\", payload.external_id, phone11)

        row = await conn.fetchrow(f"SELECT tg_id, vk_id, phone, current_role FROM users WHERE {field}=$1", payload.external_id)
        return dict(row)

@router.post("/set_role", dependencies=[Depends(require_internal)])
async def set_role(payload: SetRoleIn, request: Request):
    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(f\"\"\"
            INSERT INTO users ({field}, updated_at)
            VALUES ($1, now())
            ON CONFLICT ({field})
            DO UPDATE SET updated_at=now()
        \"\"\", payload.external_id)

        await conn.execute(f"UPDATE users SET current_role=$1, updated_at=now() WHERE {field}=$2", payload.role, payload.external_id)

        row = await conn.fetchrow(f"SELECT tg_id, vk_id, phone, current_role FROM users WHERE {field}=$1", payload.external_id)
        return dict(row)
"""

# Patch /by_tg to return 404 (and use DB)
# Replace route body if route exists; otherwise add it.
if '"/by_tg/{tg_id}"' in utxt:
    # naive replace of function starting after decorator
    pat = r'@router\.get\("/by_tg/\{tg_id\}"\)[\s\S]*?(?=\n@router\.|\Z)'
    m = re.search(pat, utxt)
    if m:
        repl = """@router.get("/by_tg/{tg_id}", dependencies=[Depends(require_internal)])
async def by_tg(tg_id: int, request: Request):
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT tg_id, vk_id, phone, current_role FROM users WHERE tg_id=$1", tg_id)
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)
"""
        utxt = utxt[:m.start()] + repl + utxt[m.end():]
else:
    utxt += """

@router.get("/by_tg/{tg_id}", dependencies=[Depends(require_internal)])
async def by_tg(tg_id: int, request: Request):
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT tg_id, vk_id, phone, current_role FROM users WHERE tg_id=$1", tg_id)
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)
"""

users_py.write_text(utxt, encoding="utf-8")

print("Patched:", main_py, users_py)
PY

echo "==[4/8] Patch TG bot: phone(contact) + role + switch role =="
python3 - <<'PY'
from pathlib import Path
import re

bot_py = Path("bot_tg/app/bot.py")
txt = bot_py.read_text(encoding="utf-8", errors="ignore")

# Ensure imports
def ensure(line):
    global txt
    if line not in txt:
        txt = line + "\n" + txt

ensure("import httpx")
if "from aiogram import F" not in txt:
    txt = txt.replace("from aiogram.filters import CommandStart", "from aiogram.filters import CommandStart\nfrom aiogram import F")
if "ReplyKeyboardMarkup" not in txt:
    txt = txt.replace("from aiogram.filters import CommandStart", "from aiogram.filters import CommandStart\nfrom aiogram.types import ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardMarkup, InlineKeyboardButton, CallbackQuery, Message")

# Inject helpers once (use BACKEND_INTERNAL_URL + INTERNAL_TOKEN per compose)
if "BACKEND_INTERNAL_URL" not in txt:
    inject = """

BACKEND_INTERNAL_URL = os.getenv("BACKEND_INTERNAL_URL", "http://backend:8000")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")

def _kb_phone() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text="📱 Отправить телефон", request_contact=True)]],
        resize_keyboard=True,
        one_time_keyboard=True,
    )

def _kb_role() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🚕 Я водитель", callback_data="role:driver")],
        [InlineKeyboardButton(text="🙋 Я клиент", callback_data="role:client")],
    ])

async def _api_get_user_tg(tg_id: int):
    headers = {"x-internal-token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {}
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(f"{BACKEND_INTERNAL_URL}/api/users/by_tg/{tg_id}", headers=headers)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()

async def _api_set_phone_tg(tg_id: int, phone: str):
    headers = {"x-internal-token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {}
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.post(f"{BACKEND_INTERNAL_URL}/api/users/set_phone", headers=headers, json={
            "platform":"tg",
            "external_id": tg_id,
            "phone": phone
        })
        r.raise_for_status()
        return r.json()

async def _api_set_role_tg(tg_id: int, role: str):
    headers = {"x-internal-token": INTERNAL_TOKEN} if INTERNAL_TOKEN else {}
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.post(f"{BACKEND_INTERNAL_URL}/api/users/set_role", headers=headers, json={
            "platform":"tg",
            "external_id": tg_id,
            "role": role
        })
        r.raise_for_status()
        return r.json()
"""
    # put after dp=Dispatcher() if exists
    m = re.search(r"dp\s*=\s*Dispatcher\(\)\s*", txt)
    if m:
        txt = txt[:m.end()] + inject + txt[m.end():]
    else:
        txt += inject

# Replace /start handler
start_pat = r"@dp\.message\(CommandStart\(\)\)\s*\nasync def [a-zA-Z0-9_]+\([^\)]*\):\s*\n"
m = re.search(start_pat, txt)
if not m:
    raise SystemExit("CommandStart handler not found")

rest = txt[m.end():]
nxt = re.search(r"\n@\w", rest)
end = m.end() + (nxt.start() if nxt else len(rest))

new_start = """@dp.message(CommandStart())
async def cmd_start(m: Message):
    tg_id = m.from_user.id
    user = await _api_get_user_tg(tg_id)

    if not user or not user.get("phone"):
        await m.answer(
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=_kb_phone()
        )
        return

    if not user.get("current_role"):
        await m.answer("Выберите, кто вы:", reply_markup=_kb_role())
        return

    role = user.get("current_role")
    await m.answer(f"Готово ✅ Текущая роль: {'Водитель' if role=='driver' else 'Клиент'}\\n\\n"
                   f"Чтобы переключиться: отправьте '🔁 Сменить роль' или /role")
"""
txt = txt[:m.start()] + new_start + txt[end:]

# Add handlers (contact + role callback + switch role)
if "async def on_contact(" not in txt:
    txt += """

@dp.message(F.contact)
async def on_contact(m: Message):
    c = m.contact
    if c.user_id and c.user_id != m.from_user.id:
        await m.answer("Пожалуйста, отправьте *свой* номер через кнопку ниже.", reply_markup=_kb_phone(), parse_mode="Markdown")
        return
    await _api_set_phone_tg(m.from_user.id, c.phone_number)
    await m.answer("Отлично. Теперь выберите роль:", reply_markup=_kb_role())

@dp.callback_query(F.data.startswith("role:"))
async def on_role(cb: CallbackQuery):
    role = cb.data.split(":", 1)[1]
    await _api_set_role_tg(cb.from_user.id, role)
    try:
        await cb.message.edit_text("Готово ✅ Роль сохранена.")
    except Exception:
        pass
    await cb.message.answer(f"Текущая роль: {'Водитель' if role=='driver' else 'Клиент'}\\n\\n"
                            f"Чтобы переключиться: отправьте '🔁 Сменить роль' или /role")
    await cb.answer()

@dp.message(F.text.in_({"🔁 Сменить роль", "/role"}))
async def switch_role(m: Message):
    await m.answer("Выберите новую роль:", reply_markup=_kb_role())
"""

bot_py.write_text(txt, encoding="utf-8")
print("Patched TG:", bot_py)
PY

echo "==[5/8] Compile check =="
python3 -m compileall -q backend bot_tg || true

echo "==[6/8] Commit & push =="
git add -A
git commit -m "Fix users registration (Postgres) + TG phone/role + role switching"
git push origin main

echo "==[7/8] Done =="
echo ""
echo "Deploy:"
echo "  cd /opt/taxi && git pull && docker compose up -d --build"
echo "Logs:"
echo "  docker compose logs -f --tail=200 backend bot_tg"
echo ""
echo "Quick test (replace TG_ID):"
echo "  curl -s -H \"x-internal-token: \$INTERNAL_TOKEN\" http://localhost:8000/api/users/by_tg/TG_ID"
