#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/taxi"
cd "$ROOT"

ts="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$ROOT/_backup_$ts"
echo "[i] backup -> $ROOT/_backup_$ts"

# backup
for f in backend/app/users.py bot_tg/app/bot.py; do
  if [ -f "$ROOT/$f" ]; then
    mkdir -p "$ROOT/_backup_$ts/$(dirname "$f")"
    cp -a "$ROOT/$f" "$ROOT/_backup_$ts/$f"
  fi
done

echo "[i] write backend/app/users.py"
cat > "$ROOT/backend/app/users.py" <<'PY'
import os, re
import asyncpg
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

router = APIRouter()

INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN","")
DB_DSN = os.getenv("DB_DSN","")
POSTGRES_HOST = os.getenv("POSTGRES_HOST","postgres")
POSTGRES_PORT = int(os.getenv("POSTGRES_PORT","5432"))
POSTGRES_DB = os.getenv("POSTGRES_DB","taxi")
POSTGRES_USER = os.getenv("POSTGRES_USER","taxi")
POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD","")

def _dsn():
    if DB_DSN:
        return DB_DSN
    return f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@{POSTGRES_HOST}:{POSTGRES_PORT}/{POSTGRES_DB}"

_pool: asyncpg.Pool | None = None

async def pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=_dsn(), min_size=1, max_size=10)
    return _pool

def _require_internal(token: str | None):
    if not INTERNAL_TOKEN:
        raise HTTPException(status_code=500, detail="INTERNAL_TOKEN is not set on backend")
    if token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="Bad internal token")

def normalize_phone(phone: str) -> str:
    # Store as digits only (Taxomet friendly): 7XXXXXXXXXX
    digits = re.sub(r"\D+", "", phone or "")
    if len(digits) == 11 and digits.startswith("8"):
        digits = "7" + digits[1:]
    if len(digits) == 10 and digits.startswith("9"):
        digits = "7" + digits
    if len(digits) != 11 or not digits.startswith("7"):
        raise ValueError("phone must be 11 digits starting with 7")
    return digits

class UserOut(BaseModel):
    id: int
    tg_id: int | None = None
    vk_id: int | None = None
    phone: str | None = None
    role: str = "client"  # client|driver
    full_name: str | None = None
    username: str | None = None

class PhoneIn(BaseModel):
    tg_id: int | None = None
    vk_id: int | None = None
    phone: str
    full_name: str | None = None
    username: str | None = None

class RoleIn(BaseModel):
    tg_id: int | None = None
    vk_id: int | None = None
    role: str

class UiLastIn(BaseModel):
    tg_id: int | None = None
    vk_id: int | None = None
    ui_chat_id: int
    ui_message_id: int

async def _get_or_create_user_by(pool: asyncpg.Pool, tg_id: int | None, vk_id: int | None, full_name: str | None, username: str | None):
    if not tg_id and not vk_id:
        raise HTTPException(status_code=400, detail="tg_id or vk_id required")

    if tg_id:
        row = await pool.fetchrow("SELECT * FROM users WHERE tg_id=$1", tg_id)
        if row:
            return row
        row = await pool.fetchrow(
            "INSERT INTO users(tg_id, role, full_name, username) VALUES ($1,'client',$2,$3) RETURNING *",
            tg_id, full_name, username
        )
        return row

    row = await pool.fetchrow("SELECT * FROM users WHERE vk_id=$1", vk_id)
    if row:
        return row
    row = await pool.fetchrow(
        "INSERT INTO users(vk_id, role, full_name, username) VALUES ($1,'client',$2,$3) RETURNING *",
        vk_id, full_name, username
    )
    return row

def _row_to_out(row) -> UserOut:
    return UserOut(
        id=row["id"],
        tg_id=row.get("tg_id"),
        vk_id=row.get("vk_id"),
        phone=row.get("phone"),
        role=row.get("role") or "client",
        full_name=row.get("full_name"),
        username=row.get("username"),
    )

@router.get("/api/users/by_tg/{tg_id}", response_model=UserOut)
async def by_tg(tg_id: int):
    p = await pool()
    row = await _get_or_create_user_by(p, tg_id=tg_id, vk_id=None, full_name=None, username=None)
    return _row_to_out(row)

@router.get("/api/users/by_vk/{vk_id}", response_model=UserOut)
async def by_vk(vk_id: int):
    p = await pool()
    row = await _get_or_create_user_by(p, tg_id=None, vk_id=vk_id, full_name=None, username=None)
    return _row_to_out(row)

@router.post("/api/users/upsert_phone", response_model=UserOut)
async def upsert_phone(payload: PhoneIn, x_internal_token: str | None = None):
    _require_internal(x_internal_token)
    p = await pool()
    try:
        phone = normalize_phone(payload.phone)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    row = await _get_or_create_user_by(p, payload.tg_id, payload.vk_id, payload.full_name, payload.username)

    row = await p.fetchrow(
        "UPDATE users SET phone=$1, full_name=COALESCE($2, full_name), username=COALESCE($3, username) WHERE id=$4 RETURNING *",
        phone, payload.full_name, payload.username, row["id"]
    )
    return _row_to_out(row)

@router.post("/api/users/set_role", response_model=UserOut)
async def set_role(payload: RoleIn, x_internal_token: str | None = None):
    _require_internal(x_internal_token)
    role = (payload.role or "").strip().lower()
    if role not in ("client","driver"):
        raise HTTPException(status_code=400, detail="role must be client|driver")
    p = await pool()
    row = await _get_or_create_user_by(p, payload.tg_id, payload.vk_id, None, None)
    row = await p.fetchrow("UPDATE users SET role=$1 WHERE id=$2 RETURNING *", role, row["id"])
    return _row_to_out(row)

@router.post("/api/users/ui_last")
async def ui_last(payload: UiLastIn, x_internal_token: str | None = None):
    _require_internal(x_internal_token)
    p = await pool()
    row = await _get_or_create_user_by(p, payload.tg_id, payload.vk_id, None, None)
    await p.execute(
        "UPDATE users SET ui_chat_id=$1, ui_message_id=$2 WHERE id=$3",
        int(payload.ui_chat_id), int(payload.ui_message_id), row["id"]
    )
    return {"ok": True}
PY

echo "[i] write bot_tg/app/bot.py"
cat > "$ROOT/bot_tg/app/bot.py" <<'PY'
import os, json, re, uuid
import httpx
from aiogram import Bot, Dispatcher, F, types
from aiogram.filters import CommandStart
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.types import ReplyKeyboardMarkup, KeyboardButton, InlineKeyboardMarkup, InlineKeyboardButton, WebAppInfo
from aiogram.utils.keyboard import ReplyKeyboardBuilder

TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN","")
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL","https://taxi.brakonder.ru")
BACKEND_INTERNAL_URL = os.getenv("BACKEND_INTERNAL_URL","http://backend:8000")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN","")

TG_ADMIN_GROUP_ID = int(os.getenv("TG_ADMIN_GROUP_ID","0"))
TG_NOTIFY_GROUP_ID = int(os.getenv("TG_NOTIFY_GROUP_ID","0"))

DRIVER_REG_LINK = os.getenv("DRIVER_REG_LINK","")
VPN_BOT_LINK = os.getenv("VPN_BOT_LINK","https://t.me/brakoknder_pn_bot")

NEARBY_RADIUS_METERS = int(os.getenv("NEARBY_RADIUS_METERS","10"))

if not TG_BOT_TOKEN:
    raise SystemExit("TG_BOT_TOKEN is required")

bot = Bot(TG_BOT_TOKEN)
dp = Dispatcher()

class Reg(StatesGroup):
    wait_phone = State()
    wait_role = State()
    wait_order_text = State()

def kb_main(role: str):
    role = (role or "client").lower()
    b = ReplyKeyboardBuilder()
    if role == "driver":
        b.button(text="📍 Отправить геопозицию")
        b.button(text="⏱️ Подъеду через…")
        b.button(text="✅ Я на месте")
        b.button(text="🔁 Сменить роль")
        b.button(text="🛡️ Обход/ВПН")
        b.adjust(2,2,1)
    else:
        b.button(text="🚕 Заказать")
        b.button(text="🗺️ Карта (MiniApp)")
        b.button(text="🔁 Сменить роль")
        b.button(text="🧑‍✈️ Стать водителем")
        b.button(text="🛡️ Обход/ВПН")
        b.adjust(2,2,1)
    # ВАЖНО: one_time_keyboard=False, иначе “пропадает”
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)

def kb_phone():
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text="📱 Отправить номер телефона", request_contact=True)]],
        resize_keyboard=True,
        one_time_keyboard=False
    )

def kb_role_pick():
    b = ReplyKeyboardBuilder()
    b.button(text="🚕 Я клиент")
    b.button(text="🧑‍✈️ Я водитель")
    b.adjust(2)
    return b.as_markup(resize_keyboard=True, one_time_keyboard=False)

def inline_order_mode():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🗺️ Оформить через карту", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))],
        [InlineKeyboardButton(text="📝 Оформить текстом", callback_data="order_text")]
    ])

def normalize_phone_digits(phone: str) -> str | None:
    digits = re.sub(r"\D+","", phone or "")
    if len(digits) == 11 and digits.startswith("8"):
        digits = "7"+digits[1:]
    if len(digits) == 10 and digits.startswith("9"):
        digits = "7"+digits
    if len(digits) != 11 or not digits.startswith("7"):
        return None
    return digits

async def backend_get(path: str):
    headers={"x-internal-token": INTERNAL_TOKEN}
    async with httpx.AsyncClient(timeout=20) as client:
        r = await client.get(f"{BACKEND_INTERNAL_URL}{path}", headers=headers)
        r.raise_for_status()
        return r.json()

async def backend_post(path: str, payload: dict):
    headers={"x-internal-token": INTERNAL_TOKEN}
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(f"{BACKEND_INTERNAL_URL}{path}", json=payload, headers=headers)
        r.raise_for_status()
        return r.json()

async def get_user(tg_id: int):
    return await backend_get(f"/api/users/by_tg/{tg_id}")

async def ensure_phone(m: types.Message, state: FSMContext) -> dict | None:
    user = await get_user(m.from_user.id)
    if user.get("phone"):
        return user
    await m.answer(
        "Чтобы пользоваться ботом, нужен номер телефона.\n\n"
        "Нажми кнопку ниже — Telegram отправит контакт.",
        reply_markup=kb_phone()
    )
    await state.set_state(Reg.wait_phone)
    return None

async def show_menu(m: types.Message, user: dict):
    role = user.get("role") or "client"
    phone = user.get("phone") or "—"
    await m.answer(
        f"Готово ✅\nТекущая роль: {('Водитель' if role=='driver' else 'Клиент')}\nТелефон: {phone}\n\nВыбирай действие:",
        reply_markup=kb_main(role)
    )

@dp.message(CommandStart())
async def cmd_start(m: types.Message, state: FSMContext):
    user = await ensure_phone(m, state)
    if not user:
        return
    role = (user.get("role") or "").strip().lower()
    if role not in ("client","driver"):
        await m.answer("Выбери роль:", reply_markup=kb_role_pick())
        await state.set_state(Reg.wait_role)
        return
    await show_menu(m, user)

@dp.message(Reg.wait_phone, F.contact)
async def got_phone(m: types.Message, state: FSMContext):
    digits = normalize_phone_digits(m.contact.phone_number)
    if not digits:
        await m.answer("Нужен номер в формате +7XXXXXXXXXX или 8XXXXXXXXXX. Попробуй ещё раз.", reply_markup=kb_phone())
        return

    await backend_post("/api/users/upsert_phone", {
        "tg_id": int(m.from_user.id),
        "phone": digits,
        "full_name": m.from_user.full_name,
        "username": m.from_user.username
    })

    await m.answer("Отлично. Теперь выбери роль:", reply_markup=kb_role_pick())
    await state.set_state(Reg.wait_role)

@dp.message(Reg.wait_phone)
async def need_contact(m: types.Message):
    await m.answer("Нажми кнопку «📱 Отправить номер телефона».", reply_markup=kb_phone())

@dp.message(Reg.wait_role, F.text.in_(["🚕 Я клиент","🧑‍✈️ Я водитель"]))
async def set_role(m: types.Message, state: FSMContext):
    role = "client" if m.text.startswith("🚕") else "driver"
    user = await backend_post("/api/users/set_role", {"tg_id": int(m.from_user.id), "role": role})
    await state.clear()
    await show_menu(m, user)

@dp.message(Reg.wait_role)
async def need_role(m: types.Message):
    await m.answer("Выбери роль кнопками ниже.", reply_markup=kb_role_pick())

@dp.message(F.text == "🔁 Сменить роль")
async def change_role(m: types.Message, state: FSMContext):
    await m.answer("Выбери новую роль:", reply_markup=kb_role_pick())
    await state.set_state(Reg.wait_role)

@dp.message(F.text == "🛡️ Обход/ВПН")
async def vpn(m: types.Message):
    await m.answer("Бот обхода/ВПН:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🛡️ Открыть", url=VPN_BOT_LINK)]
    ]))

@dp.message(F.text == "🧑‍✈️ Стать водителем")
async def reg_driver(m: types.Message):
    if not DRIVER_REG_LINK:
        await m.answer("Ссылка регистрации водителей ещё не настроена.")
        return
    await m.answer("Регистрация водителя в Taxomet:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🧑‍✈️ Открыть регистрацию", url=DRIVER_REG_LINK)]
    ]))

@dp.message(F.text == "🗺️ Карта (MiniApp)")
async def map_open(m: types.Message, state: FSMContext):
    user = await ensure_phone(m, state)
    if not user:
        return
    await m.answer("Открывай карту, ставь Откуда/Куда и жми «Отправить в бота».", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🗺️ Открыть карту", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))]
    ]))

@dp.message(F.text == "🚕 Заказать")
async def order(m: types.Message, state: FSMContext):
    user = await ensure_phone(m, state)
    if not user:
        return
    await m.answer("Как оформляем заказ?", reply_markup=inline_order_mode())

@dp.callback_query(F.data == "order_text")
async def order_text(cb: types.CallbackQuery, state: FSMContext):
    await cb.answer()
    await cb.message.answer(
        "Напиши заказ текстом в формате:\n"
        "`Откуда -> Куда | Комментарий`\n\n"
        "Пример:\n"
        "`Вилючинск, Профсоюзная 10 -> Петропавловск-Камчатский, Аэропорт | Детское кресло`",
        parse_mode="Markdown"
    )
    await state.set_state(Reg.wait_order_text)

@dp.message(Reg.wait_order_text, F.text)
async def handle_order_text(m: types.Message, state: FSMContext):
    user = await get_user(m.from_user.id)
    phone = user.get("phone")
    if not phone:
        await m.answer("Сначала нужно сохранить номер телефона.", reply_markup=kb_phone())
        await state.set_state(Reg.wait_phone)
        return

    text = m.text.strip()
    comment = ""
    if "|" in text:
        text, comment = [x.strip() for x in text.split("|", 1)]
    if "->" not in text:
        await m.answer("Формат неверный. Нужно `Откуда -> Куда | Комментарий`", parse_mode="Markdown")
        return
    a, b = [x.strip() for x in text.split("->", 1)]
    if not a or not b:
        await m.answer("Нужно указать и Откуда, и Куда.")
        return

    # geo resolve through backend
    try:
        g_from = await backend_get(f"/api/geo/search?q={httpx.QueryParams({'q':a}).get('q')}&limit=1")
    except Exception:
        g_from = []
    try:
        g_to = await backend_get(f"/api/geo/search?q={httpx.QueryParams({'q':b}).get('q')}&limit=1")
    except Exception:
        g_to = []

    if not g_from or not g_to:
        await m.answer("Не смог найти адрес(а). Попробуй написать иначе (город, улица, дом).")
        return

    from_obj = g_from[0]
    to_obj = g_to[0]

    extern_id = f"tg-{m.from_user.id}-{uuid.uuid4().hex[:10]}"
    payload = {
        "phone": phone,  # digits only
        "client_name": user.get("full_name") or m.from_user.full_name,
        "comment": comment,
        "from_address": from_obj.get("display_name") or a,
        "from_lat": float(from_obj.get("lat")),
        "from_lon": float(from_obj.get("lon")),
        "to_addresses": [to_obj.get("display_name") or b],
        "to_lats": [float(to_obj.get("lat"))],
        "to_lons": [float(to_obj.get("lon"))],
        "tg_user_id": int(m.from_user.id),
        "extern_id": extern_id
    }

    try:
        res = await backend_post("/api/orders/create", payload)
    except httpx.HTTPStatusError as e:
        await m.answer(f"Ошибка создания заказа: {e.response.text[:1200]}")
        return

    await state.clear()
    await m.answer(f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидай назначения водителя.", reply_markup=kb_main(user.get("role","client")))

@dp.message(F.location)
async def location(m: types.Message, state: FSMContext):
    user = await ensure_phone(m, state)
    if not user:
        return
    tg_id = m.from_user.id
    lat = m.location.latitude
    lon = m.location.longitude
    driver_id = tg_id  # пока = tg_id

    await backend_post("/api/drivers/location", {
        "driver_id": int(driver_id),
        "tg_id": int(tg_id),
        "lat": float(lat),
        "lon": float(lon),
        "phone": user.get("phone"),
        "name": user.get("full_name") or m.from_user.full_name
    })
    await m.answer("✅ Геопозиция обновлена.", reply_markup=kb_main(user.get("role","driver")))

@dp.message(F.web_app_data)
async def webapp(m: types.Message, state: FSMContext):
    user = await ensure_phone(m, state)
    if not user:
        return

    try:
        data = json.loads(m.web_app_data.data)
    except Exception:
        await m.answer("Не смог прочитать данные с карты. Попробуй ещё раз.")
        return

    phone = normalize_phone_digits((data.get("phone") or user.get("phone") or ""))
    if not phone:
        await m.answer("Телефон нужен (11 цифр). Открой /start и отправь номер кнопкой.")
        return

    from_obj = data.get("from") or {}
    to_list = data.get("to") or []
    if not from_obj or not to_list:
        await m.answer("Нужно указать Откуда и Куда.")
        return

    extern_id = f"tg-{m.from_user.id}-{uuid.uuid4().hex[:10]}"

    payload = {
        "phone": phone,
        "client_name": (data.get("client_name") or user.get("full_name") or m.from_user.full_name or "").strip(),
        "comment": (data.get("comment") or "").strip(),
        "from_address": from_obj.get("address") or "",
        "from_lat": from_obj.get("lat"),
        "from_lon": from_obj.get("lon"),
        "to_addresses": [x.get("address") or "" for x in to_list],
        "to_lats": [x.get("lat") for x in to_list],
        "to_lons": [x.get("lon") for x in to_list],
        "tg_user_id": int(m.from_user.id),
        "extern_id": extern_id
    }

    try:
        res = await backend_post("/api/orders/create", payload)
    except httpx.HTTPStatusError as e:
        await m.answer(f"Ошибка создания заказа: {e.response.text[:1200]}")
        return

    await m.answer(f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидай назначения водителя.", reply_markup=kb_main(user.get("role","client")))

async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
PY

echo "[i] rebuild + restart backend + bot_tg"
docker compose build backend bot_tg
docker compose up -d backend bot_tg

echo
echo "[OK] done. Check logs:"
echo "docker compose logs -f --tail=200 backend"
echo "docker compose logs -f --tail=200 bot_tg"
