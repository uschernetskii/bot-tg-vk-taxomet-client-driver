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
