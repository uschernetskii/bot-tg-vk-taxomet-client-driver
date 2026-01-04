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
