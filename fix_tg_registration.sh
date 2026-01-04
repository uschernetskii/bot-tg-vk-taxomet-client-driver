#!/usr/bin/env bash
set -euo pipefail
TS="$(date +%Y%m%d-%H%M%S)"

echo "== 0) Safety checks =="
git status --porcelain
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: working tree not clean. Commit/stash first."
  git status --porcelain
  exit 1
fi

backup() { [ -f "$1" ] && cp -a "$1" "$1.bak.$TS"; }

echo "== 1) Backup files =="
backup backend/app/main.py
backup backend/app/users.py
backup bot_tg/app/bot.py

echo "== 2) Rewrite backend/app/main.py (fix users schema creation) =="
cat > backend/app/main.py <<'PY'
import os, json, uuid
from typing import Any, Optional

import asyncpg
import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .users import router as users_router

ENV = os.getenv("ENV", "prod")

DB_HOST = os.getenv("POSTGRES_HOST","postgres")
DB_PORT = int(os.getenv("POSTGRES_PORT","5432"))
DB_NAME = os.getenv("POSTGRES_DB","taxi")
DB_USER = os.getenv("POSTGRES_USER","taxi")
DB_PASS = os.getenv("POSTGRES_PASSWORD","")

INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN","")
TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN","")

PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL","https://taxi.brakonder.ru")

GEO_BASE_URL = os.getenv("GEO_BASE_URL","https://geo41.brakonder.ru").rstrip("/")
GEO_TILES_STYLE_URL = os.getenv("GEO_TILES_STYLE_URL","")

# Nearby
DRIVER_ONLINE_TTL_SECONDS = int(os.getenv("DRIVER_ONLINE_TTL_SECONDS","60"))
NEARBY_RADIUS_METERS = int(os.getenv("NEARBY_RADIUS_METERS","5"))

# Groups
TG_ADMIN_GROUP_ID = int(os.getenv("TG_ADMIN_GROUP_ID","0"))
TG_NOTIFY_GROUP_ID = int(os.getenv("TG_NOTIFY_GROUP_ID","0"))

# Taxomet
TAXOMET_BASE_URL = os.getenv("TAXOMET_BASE_URL","").rstrip("/")
TAXOMET_OPERATOR_LOGIN = os.getenv("TAXOMET_OPERATOR_LOGIN","")
TAXOMET_OPERATOR_PASSWORD = os.getenv("TAXOMET_OPERATOR_PASSWORD","")
TAXOMET_UNIT_ID = os.getenv("TAXOMET_UNIT_ID","1")
TAXOMET_TARIF_ID = os.getenv("TAXOMET_TARIF_ID","-1")
TAXOMET_WEBHOOK_SECRET = os.getenv("TAXOMET_WEBHOOK_SECRET","")

# VK (задел)
VK_CONFIRMATION = os.getenv("VK_CONFIRMATION","")
VK_SECRET = os.getenv("VK_SECRET","")

app = FastAPI(title="Taxi Backend", version="1.0.0")
app.include_router(users_router)


def must_internal(request: Request):
  token = request.headers.get("x-internal-token","")
  # Если INTERNAL_TOKEN не задан — не пускаем (это прод-сервис)
  if not INTERNAL_TOKEN or token != INTERNAL_TOKEN:
    raise HTTPException(status_code=401, detail="internal token invalid")


async def _ensure_users_schema(pool):
  # ВАЖНО: без CHECK, и отдельными командами (так надёжнее)
  stmts = [
    """
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
    """,
    "CREATE INDEX IF NOT EXISTS idx_users_tg_id ON users(tg_id);",
    "CREATE INDEX IF NOT EXISTS idx_users_vk_id ON users(vk_id);",
  ]
  async with pool.acquire() as conn:
    for q in stmts:
      await conn.execute(q)


async def tg_send(chat_id: int, text: str):
  if not TG_BOT_TOKEN or not chat_id:
    return
  url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
  payload = {"chat_id": chat_id, "text": text, "disable_web_page_preview": True}
  try:
    async with httpx.AsyncClient(timeout=15) as client:
      await client.post(url, json=payload)
  except Exception:
    return


async def taxomet_get(path: str, params: dict[str, Any]) -> dict[str, Any]:
  if not TAXOMET_BASE_URL:
    raise HTTPException(status_code=500, detail="TAXOMET_BASE_URL not set")
  async with httpx.AsyncClient(timeout=30) as client:
    r = await client.get(f"{TAXOMET_BASE_URL}{path}", params=params)
    r.raise_for_status()
    try:
      return r.json()
    except Exception:
      return {"raw": r.text}


SCHEMA = """
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE IF NOT EXISTS tg_users(
  tg_id BIGINT PRIMARY KEY,
  phone TEXT,
  name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS drivers(
  driver_id BIGINT PRIMARY KEY,
  tg_id BIGINT UNIQUE,
  phone TEXT,
  name TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS driver_locations(
  driver_id BIGINT PRIMARY KEY REFERENCES drivers(driver_id) ON DELETE CASCADE,
  geom GEOGRAPHY(POINT,4326) NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_driver_locations_geom ON driver_locations USING GIST (geom);

CREATE TABLE IF NOT EXISTS orders(
  id BIGSERIAL PRIMARY KEY,
  extern_id TEXT UNIQUE,
  taxomet_order_id BIGINT,
  tg_user_id BIGINT,
  phone TEXT,
  client_name TEXT,
  from_address TEXT,
  to_addresses JSONB,
  status INT NOT NULL DEFAULT 0,
  driver_id BIGINT,
  driver_title TEXT,
  fix_price NUMERIC(12,2) DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_orders_taxomet ON orders(taxomet_order_id);
"""


@app.on_event("startup")
async def startup():
  app.state.pool = await asyncpg.create_pool(
    host=DB_HOST, port=DB_PORT, database=DB_NAME, user=DB_USER, password=DB_PASS,
    min_size=1, max_size=10
  )
  async with app.state.pool.acquire() as conn:
    await conn.execute(SCHEMA)
  await _ensure_users_schema(app.state.pool)


@app.get("/api/health")
async def health():
  return {"ok": True, "env": ENV}


########################
# GEO proxy
########################
@app.get("/api/geo/search")
async def geo_search(q: str, limit: int = 5):
  async with httpx.AsyncClient(timeout=20) as client:
    r = await client.get(f"{GEO_BASE_URL}/search", params={"q": q, "format": "json", "limit": limit, "addressdetails": 1})
    r.raise_for_status()
    return JSONResponse(content=r.json())


@app.get("/api/geo/reverse")
async def geo_reverse(lat: float, lon: float):
  async with httpx.AsyncClient(timeout=20) as client:
    r = await client.get(f"{GEO_BASE_URL}/reverse", params={"lat": lat, "lon": lon, "format": "json", "addressdetails": 1})
    r.raise_for_status()
    return JSONResponse(content=r.json())


########################
# Drivers
########################
class DriverLocationIn(BaseModel):
  driver_id: int
  tg_id: int
  lat: float
  lon: float
  phone: Optional[str] = None
  name: Optional[str] = None


@app.post("/api/drivers/location")
async def driver_location(payload: DriverLocationIn, request: Request):
  must_internal(request)
  pool = app.state.pool
  async with pool.acquire() as conn:
    await conn.execute(
      "INSERT INTO drivers(driver_id, tg_id, phone, name) VALUES($1,$2,$3,$4) "
      "ON CONFLICT(driver_id) DO UPDATE SET tg_id=EXCLUDED.tg_id, phone=COALESCE(EXCLUDED.phone, drivers.phone), name=COALESCE(EXCLUDED.name, drivers.name)",
      payload.driver_id, payload.tg_id, payload.phone, payload.name
    )
    await conn.execute(
      "INSERT INTO driver_locations(driver_id, geom, updated_at) VALUES($1, ST_SetSRID(ST_MakePoint($2,$3),4326)::geography, now()) "
      "ON CONFLICT(driver_id) DO UPDATE SET geom=EXCLUDED.geom, updated_at=now()",
      payload.driver_id, payload.lon, payload.lat
    )
  return {"ok": True}


@app.get("/api/drivers/nearby")
async def drivers_nearby(lat: float, lon: float, radius_m: int = NEARBY_RADIUS_METERS):
  pool = app.state.pool
  async with pool.acquire() as conn:
    rows = await conn.fetch(
      """
      SELECT d.driver_id, d.name, d.phone,
             ST_Y(l.geom::geometry) AS lat,
             ST_X(l.geom::geometry) AS lon,
             EXTRACT(EPOCH FROM (now() - l.updated_at))::int AS age_seconds
      FROM driver_locations l
      JOIN drivers d ON d.driver_id = l.driver_id
      WHERE l.updated_at > now() - ($3::text || ' seconds')::interval
        AND ST_DWithin(l.geom, ST_SetSRID(ST_MakePoint($1,$2),4326)::geography, $4)
      ORDER BY l.updated_at DESC
      LIMIT 200
      """,
      lon, lat, DRIVER_ONLINE_TTL_SECONDS, radius_m
    )
  return {"ok": True, "radius_m": radius_m, "drivers": [dict(r) for r in rows]}


########################
# Orders -> Taxomet
########################
class OrderCreateIn(BaseModel):
  phone: str
  client_name: Optional[str] = ""
  comment: Optional[str] = ""
  extern_id: str
  tg_user_id: int

  from_address: str
  from_lat: Optional[float] = None
  from_lon: Optional[float] = None

  to_addresses: list[str]
  to_lats: Optional[list[Optional[float]]] = None
  to_lons: Optional[list[Optional[float]]] = None


@app.post("/api/orders/create")
async def orders_create(payload: OrderCreateIn, request: Request):
  must_internal(request)
  if len(payload.to_addresses) < 1:
    raise HTTPException(status_code=400, detail="to_addresses must contain at least 1 (destination)")

  to_list = [payload.from_address] + payload.to_addresses

  params: dict[str, Any] = {
    "operator_login": TAXOMET_OPERATOR_LOGIN,
    "operator_password": TAXOMET_OPERATOR_PASSWORD,
    "unit_id": TAXOMET_UNIT_ID,
    "tarif_id": TAXOMET_TARIF_ID,
    "phone": payload.phone,
    "extern_id": payload.extern_id,
    "comment": payload.comment or "",
    "client_name": payload.client_name or "",
    "to[]": to_list,
  }

  lat_arr = []
  lon_arr = []
  if payload.from_lat is not None and payload.from_lon is not None:
    lat_arr.append(payload.from_lat); lon_arr.append(payload.from_lon)
  else:
    lat_arr.append(""); lon_arr.append("")
  for i in range(len(payload.to_addresses)):
    lat_arr.append(payload.to_lats[i] if payload.to_lats else "")
    lon_arr.append(payload.to_lons[i] if payload.to_lons else "")

  if any(x != "" for x in lat_arr) and any(x != "" for x in lon_arr):
    params["lat[]"] = lat_arr
    params["lon[]"] = lon_arr

  data = await taxomet_get("/add_order", params)
  if str(data.get("result")) != "1":
    raise HTTPException(status_code=400, detail={"taxomet": data})

  taxomet_order_id = int(data.get("order_id", 0))

  pool = app.state.pool
  async with pool.acquire() as conn:
    await conn.execute(
      """
      INSERT INTO orders(extern_id, taxomet_order_id, tg_user_id, phone, client_name, from_address, to_addresses, status)
      VALUES($1,$2,$3,$4,$5,$6,$7,0)
      ON CONFLICT(extern_id) DO UPDATE SET taxomet_order_id=EXCLUDED.taxomet_order_id, updated_at=now()
      """,
      payload.extern_id, taxomet_order_id, payload.tg_user_id, payload.phone,
      payload.client_name, payload.from_address, json.dumps(payload.to_addresses)
    )

  msg = (
    f"🚕 Новый заказ\n"
    f"ID: {taxomet_order_id}\n"
    f"Клиент: {payload.client_name or '-'}\n"
    f"Тел: {payload.phone}\n"
    f"Откуда: {payload.from_address}\n"
    f"Куда: {', '.join(payload.to_addresses)}\n"
    f"Комментарий: {payload.comment or '-'}"
  )
  await tg_send(TG_NOTIFY_GROUP_ID, msg)
  await tg_send(TG_ADMIN_GROUP_ID, msg)

  return {"ok": True, "taxomet_order_id": taxomet_order_id, "extern_id": payload.extern_id}


########################
# Taxomet webhook (statuses)
########################
class TaxometWebhookIn(BaseModel):
  extern_id: str
  order_id: int
  status: int
  driver_id: Optional[int] = None
  driver_title: Optional[str] = None
  fix_price: Optional[float] = 0


@app.post("/api/taxomet/webhook")
async def taxomet_webhook(payload: TaxometWebhookIn, request: Request):
  if TAXOMET_WEBHOOK_SECRET:
    got = request.headers.get("x-taxomet-secret","")
    if got != TAXOMET_WEBHOOK_SECRET:
      raise HTTPException(status_code=401, detail="bad webhook secret")

  pool = app.state.pool
  async with pool.acquire() as conn:
    await conn.execute(
      """
      UPDATE orders
         SET status=$1,
             driver_id=COALESCE($2, driver_id),
             driver_title=COALESCE($3, driver_title),
             fix_price=COALESCE($4, fix_price),
             updated_at=now()
       WHERE extern_id=$5
      """,
      payload.status, payload.driver_id, payload.driver_title, payload.fix_price, payload.extern_id
    )
    row = await conn.fetchrow("SELECT tg_user_id, taxomet_order_id FROM orders WHERE extern_id=$1", payload.extern_id)

  if row:
    user_id = int(row["tg_user_id"])
    order_id = int(row["taxomet_order_id"] or payload.order_id)
    msg = f"🚕 Заказ {order_id}: статус={payload.status}"
    if payload.driver_title:
      msg += f"\nВодитель: {payload.driver_title}"
    await tg_send(user_id, msg)
    await tg_send(TG_NOTIFY_GROUP_ID, msg)

  return {"ok": True}


########################
# VK callback (задел)
########################
@app.post("/vk/callback")
async def vk_callback(request: Request):
  body = await request.json()
  t = body.get("type","")
  if t == "confirmation":
    if not VK_CONFIRMATION:
      raise HTTPException(status_code=500, detail="VK_CONFIRMATION not set")
    return JSONResponse(content=VK_CONFIRMATION)

  if VK_SECRET:
    if body.get("secret","") != VK_SECRET:
      raise HTTPException(status_code=401, detail="bad vk secret")

  return JSONResponse(content="ok")
PY

echo "== 3) Rewrite backend/app/users.py (single coherent API) =="
cat > backend/app/users.py <<'PY'
import os
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel

router = APIRouter(prefix="/api/users", tags=["users"])

INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")


def require_internal(x_internal_token: str = Header(default="")):
    if not INTERNAL_TOKEN or x_internal_token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="unauthorized")


async def _get_pool(request: Request):
    pool = getattr(request.app.state, "pool", None)
    if not pool:
        raise HTTPException(status_code=500, detail="DB pool not initialized")
    return pool


def _digits(raw: str) -> str:
    return "".join(ch for ch in (raw or "") if ch.isdigit())


def normalize_ru_phone(raw: str) -> str:
    d = _digits(raw)
    if len(d) == 11 and d.startswith("8"):
        d = "7" + d[1:]
    if len(d) == 11 and d.startswith("7"):
        return d
    raise ValueError("Неверный телефон. Нужен РФ номер: 7XXXXXXXXXX (11 цифр).")


class SetPhoneIn(BaseModel):
    platform: str  # tg|vk
    external_id: int
    phone: str
    full_name: str | None = None


class SetRoleIn(BaseModel):
    platform: str  # tg|vk
    external_id: int
    role: str  # client|driver


@router.get("/by_tg/{tg_id}", dependencies=[Depends(require_internal)])
async def by_tg(tg_id: int, request: Request):
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT tg_id, vk_id, phone, full_name, current_role FROM users WHERE tg_id=$1",
            tg_id,
        )
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)


@router.get("/by_external/{platform}/{external_id}", dependencies=[Depends(require_internal)])
async def by_external(platform: str, external_id: int, request: Request):
    if platform not in ("tg", "vk"):
        raise HTTPException(status_code=400, detail="Bad platform")
    field = "tg_id" if platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            f"SELECT tg_id, vk_id, phone, full_name, current_role FROM users WHERE {field}=$1",
            external_id,
        )
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)


@router.post("/set_phone", dependencies=[Depends(require_internal)])
async def set_phone(payload: SetPhoneIn, request: Request):
    if payload.platform not in ("tg", "vk"):
        raise HTTPException(status_code=400, detail="platform must be tg|vk")
    try:
        phone11 = normalize_ru_phone(payload.phone)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(
            f"""
            INSERT INTO users ({field}, phone, full_name, updated_at)
            VALUES ($1, $2, $3, now())
            ON CONFLICT ({field})
            DO UPDATE SET
                phone=EXCLUDED.phone,
                full_name=COALESCE(EXCLUDED.full_name, users.full_name),
                updated_at=now()
            """,
            payload.external_id,
            phone11,
            payload.full_name,
        )
        row = await conn.fetchrow(
            f"SELECT tg_id, vk_id, phone, full_name, current_role FROM users WHERE {field}=$1",
            payload.external_id,
        )
        return dict(row)


@router.post("/set_role", dependencies=[Depends(require_internal)])
async def set_role(payload: SetRoleIn, request: Request):
    if payload.platform not in ("tg", "vk"):
        raise HTTPException(status_code=400, detail="platform must be tg|vk")
    role = (payload.role or "").strip().lower()
    if role not in ("client", "driver"):
        raise HTTPException(status_code=400, detail="role must be client|driver")

    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(
            f"""
            INSERT INTO users ({field}, updated_at)
            VALUES ($1, now())
            ON CONFLICT ({field})
            DO UPDATE SET updated_at=now()
            """,
            payload.external_id,
        )
        await conn.execute(
            f"UPDATE users SET current_role=$1, updated_at=now() WHERE {field}=$2",
            role,
            payload.external_id,
        )
        row = await conn.fetchrow(
            f"SELECT tg_id, vk_id, phone, full_name, current_role FROM users WHERE {field}=$1",
            payload.external_id,
        )
        return dict(row)
PY

echo "== 4) Rewrite bot_tg/app/bot.py (clean TG registration flow) =="
cat > bot_tg/app/bot.py <<'PY'
import os
import json
import uuid
import asyncio
import logging

import httpx
from aiogram import Bot, Dispatcher, F
from aiogram.filters import CommandStart
from aiogram.types import (
    Message, CallbackQuery,
    ReplyKeyboardMarkup, KeyboardButton,
    InlineKeyboardMarkup, InlineKeyboardButton,
    WebAppInfo
)
from aiogram.utils.keyboard import ReplyKeyboardBuilder

TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
PUBLIC_BASE_URL = os.getenv("PUBLIC_BASE_URL", "https://taxi.brakonder.ru")
BACKEND_INTERNAL_URL = os.getenv("BACKEND_INTERNAL_URL", "http://backend:8000")
INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")

DRIVER_REG_LINK = os.getenv("DRIVER_REG_LINK", "")
VPN_BOT_LINK = os.getenv("VPN_BOT_LINK", "https://t.me/brakoknder_pn_bot")
NEARBY_RADIUS_METERS = int(os.getenv("NEARBY_RADIUS_METERS", "5"))

if not TG_BOT_TOKEN:
    raise SystemExit("TG_BOT_TOKEN is required")

bot = Bot(TG_BOT_TOKEN)
dp = Dispatcher()


def kb_phone() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[[KeyboardButton(text="📱 Отправить телефон", request_contact=True)]],
        resize_keyboard=True,
        one_time_keyboard=True,
    )


def inline_choose_role() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🙋 Я клиент", callback_data="role:client")],
        [InlineKeyboardButton(text="🚖 Я водитель", callback_data="role:driver")],
    ])


def inline_open_map() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🗺️ Открыть карту", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))]
    ])


def kb_main_client():
    b = ReplyKeyboardBuilder()
    b.button(text="🚕 Заказать такси")
    b.button(text="🗺️ Карта (MiniApp)")
    b.button(text="🔁 Сменить роль")
    b.button(text="🛡️ Обход/ВПН")
    b.adjust(2, 2)
    return b.as_markup(resize_keyboard=True)


def kb_main_driver():
    b = ReplyKeyboardBuilder()
    b.button(text="📍 Я водитель — поделиться гео")
    b.button(text="🗺️ Карта (MiniApp)")
    b.button(text="🧑‍✈️ Стать водителем")
    b.button(text="🔁 Сменить роль")
    b.button(text="🛡️ Обход/ВПН")
    b.adjust(2, 2, 1)
    return b.as_markup(resize_keyboard=True)


def kb_driver_geo() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(
        keyboard=[
            [KeyboardButton(text="📍 Отправить геопозицию", request_location=True)],
            [KeyboardButton(text="⬅️ Назад")]
        ],
        resize_keyboard=True
    )


async def backend_get(path: str):
    headers = {"x-internal-token": INTERNAL_TOKEN}
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.get(f"{BACKEND_INTERNAL_URL}{path}", headers=headers)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()


async def backend_post(path: str, payload: dict):
    headers = {"x-internal-token": INTERNAL_TOKEN}
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(f"{BACKEND_INTERNAL_URL}{path}", json=payload, headers=headers)
        r.raise_for_status()
        return r.json()


def role_label(role: str) -> str:
    return "Водитель" if role == "driver" else "Клиент"


async def get_user_tg(tg_id: int):
    return await backend_get(f"/api/users/by_tg/{tg_id}")


async def ensure_user(m: Message):
    user = await get_user_tg(m.from_user.id)
    if not user or not user.get("phone"):
        await m.answer(
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return None
    if not user.get("current_role"):
        await m.answer("Выберите, кто вы:", reply_markup=inline_choose_role())
        return None
    return user


async def show_menu(m: Message, user: dict):
    role = user.get("current_role") or "client"
    if role == "driver":
        await m.answer(f"Готово ✅ Текущая роль: {role_label(role)}", reply_markup=kb_main_driver())
    else:
        await m.answer(f"Готово ✅ Текущая роль: {role_label(role)}", reply_markup=kb_main_client())


@dp.message(CommandStart())
async def cmd_start(m: Message):
    tg_id = m.from_user.id
    user = await get_user_tg(tg_id)

    if not user or not user.get("phone"):
        await m.answer(
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return

    if not user.get("current_role"):
        await m.answer("Выберите, кто вы:", reply_markup=inline_choose_role())
        return

    await show_menu(m, user)


@dp.message(F.contact)
async def on_contact(m: Message):
    c = m.contact
    if not c:
        return
    if c.user_id and c.user_id != m.from_user.id:
        await m.answer("Пожалуйста, отправьте *свой* телефон кнопкой ниже.", reply_markup=kb_phone(), parse_mode="Markdown")
        return

    await backend_post("/api/users/set_phone", {
        "platform": "tg",
        "external_id": int(m.from_user.id),
        "phone": c.phone_number,
        "full_name": m.from_user.full_name,
    })

    user = await get_user_tg(m.from_user.id)
    if not user or not user.get("current_role"):
        await m.answer("Номер принят ✅ Теперь выберите роль:", reply_markup=inline_choose_role())
        return
    await show_menu(m, user)


@dp.callback_query(F.data.startswith("role:"))
async def on_role(cb: CallbackQuery):
    role = cb.data.split(":", 1)[1]
    await backend_post("/api/users/set_role", {
        "platform": "tg",
        "external_id": int(cb.from_user.id),
        "role": role,
    })
    user = await get_user_tg(cb.from_user.id)
    if user:
        await show_menu(cb.message, user)
    await cb.answer()


@dp.message(F.text == "🔁 Сменить роль")
@dp.message(F.text.startswith("/role"))
async def switch_role(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    await m.answer("Выберите новую роль:", reply_markup=inline_choose_role())


@dp.message(F.text == "⬅️ Назад")
async def back(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    await show_menu(m, user)


@dp.message(F.text == "🗺️ Карта (MiniApp)")
async def map_open(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    await m.answer("Открывай карту:", reply_markup=inline_open_map())


@dp.message(F.text == "🚕 Заказать такси")
async def order(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    if user.get("current_role") != "client":
        await m.answer("Эта кнопка для клиентов. Если вы водитель — нажмите «🔁 Сменить роль».")
        return
    await m.answer("Заказ делается через карту:", reply_markup=inline_open_map())


@dp.message(F.text == "📍 Я водитель — поделиться гео")
async def driver_geo_menu(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    if user.get("current_role") != "driver":
        await m.answer("Эта кнопка для водителей. Если вы клиент — нажмите «🔁 Сменить роль».")
        return
    await m.answer("Нажмите кнопку и отправьте геопозицию:", reply_markup=kb_driver_geo())


@dp.message(F.text == "🧑‍✈️ Стать водителем")
async def reg_driver(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    if DRIVER_REG_LINK:
        await m.answer("Регистрация водителя:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🧑‍✈️ Стать водителем", url=DRIVER_REG_LINK)]
        ]))
    else:
        await m.answer("DRIVER_REG_LINK не задан")


@dp.message(F.text == "🛡️ Обход/ВПН")
async def vpn(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    await m.answer("Бот обхода:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🛡️ Открыть", url=VPN_BOT_LINK)]
    ]))


@dp.message(F.location)
async def location(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    if user.get("current_role") != "driver":
        await m.answer("Геопозицию принимаю только от водителей.")
        return

    tg_id = m.from_user.id
    lat = m.location.latitude
    lon = m.location.longitude
    driver_id = tg_id  # позже привяжем к Taxomet driver_id

    await backend_post("/api/drivers/location", {
        "driver_id": int(driver_id),
        "tg_id": int(tg_id),
        "lat": float(lat),
        "lon": float(lon),
        "phone": user.get("phone"),
        "name": user.get("full_name") or m.from_user.full_name,
    })
    await m.answer("✅ Геопозиция водителя обновлена.")


@dp.message(F.web_app_data)
async def webapp(m: Message):
    user = await ensure_user(m)
    if not user:
        return
    if user.get("current_role") != "client":
        await m.answer("Заказы создаёт только клиент.")
        return

    try:
        data = json.loads(m.web_app_data.data)
    except Exception:
        await m.answer("Не смог прочитать данные с карты. Попробуйте ещё раз.")
        return

    phone = (user.get("phone") or "").strip()
    if not phone:
        await m.answer("Сначала зарегистрируйте телефон через /start")
        return

    from_obj = data.get("from") or {}
    to_list = data.get("to") or []
    if not from_obj or not to_list:
        await m.answer("Нужно указать Откуда и Куда.")
        return

    extern_id = f"tg-{m.from_user.id}-{uuid.uuid4().hex[:10]}"
    payload = {
        "phone": phone,
        "client_name": (user.get("full_name") or m.from_user.full_name or "").strip(),
        "comment": (data.get("comment") or "").strip(),
        "from_address": from_obj.get("address") or "",
        "from_lat": from_obj.get("lat"),
        "from_lon": from_obj.get("lon"),
        "to_addresses": [x.get("address") or "" for x in to_list],
        "to_lats": [x.get("lat") for x in to_list],
        "to_lons": [x.get("lon") for x in to_list],
        "tg_user_id": int(m.from_user.id),
        "extern_id": extern_id,
    }

    try:
        res = await backend_post("/api/orders/create", payload)
    except httpx.HTTPStatusError as e:
        await m.answer(f"Ошибка создания заказа: {e.response.text[:1200]}")
        return

    await m.answer(f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидайте назначения водителя.")


async def main():
    logging.basicConfig(level=logging.INFO)
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
PY

echo "== 5) Compile check =="
python3 -m py_compile backend/app/main.py backend/app/users.py bot_tg/app/bot.py

echo "== 6) Commit & push =="
git add backend/app/main.py backend/app/users.py bot_tg/app/bot.py
git commit -m "Fix TG registration (phone + role switch) and normalize users API"
git push origin main

echo "== 7) Rebuild & restart =="
docker compose up -d --build backend bot_tg

echo "== 8) Logs =="
docker compose logs -f --tail=120 backend bot_tg
