import os
from fastapi import APIRouter, Request, Header, HTTPException
from fastapi import HTTPException, Header, Depends, Request
from pydantic import BaseModel

router = APIRouter(prefix="/api/users", tags=["users"])

INTERNAL_TOKEN = os.getenv("INTERNAL_TOKEN", "")

def require_internal(x_internal_token: str = Header(default="")):
    if not INTERNAL_TOKEN or x_internal_token != INTERNAL_TOKEN:
        raise HTTPException(status_code=401, detail="unauthorized")

class UpsertUser(BaseModel):
    tg_id: int
    phone: str
    full_name: str | None = None

class SetRole(BaseModel):
    tg_id: int
    role: str  # "client" | "driver"

@router.get("/by_tg/{tg_id}", dependencies=[Depends(require_internal)])
async def by_tg(tg_id: int, request: Request):
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT tg_id, vk_id, phone, current_role FROM users WHERE tg_id=$1", tg_id)
        if not row:
            raise HTTPException(status_code=404, detail="User not found")
        return dict(row)

@router.post("/upsert")
async def upsert(payload: UpsertUser, request: Request, x_internal_token: str = Header(default="")):
    require_internal(x_internal_token)
    pool = request.app.state.pool
    async with pool.acquire() as con:
        row = await con.fetchrow(
            """
            INSERT INTO users (tg_id, phone, full_name)
            VALUES ($1,$2,$3)
            ON CONFLICT (tg_id)
            DO UPDATE SET phone=EXCLUDED.phone, full_name=EXCLUDED.full_name, updated_at=now()
            RETURNING tg_id, phone, full_name, role
            """,
            payload.tg_id, payload.phone, payload.full_name
        )
    return {"ok": True, "user": dict(row)}

@router.post("/set_role")
async def set_role(payload: SetRole, request: Request, x_internal_token: str = Header(default="")):
    require_internal(x_internal_token)
    role = payload.role.strip().lower()
    if role not in ("client", "driver"):
        raise HTTPException(status_code=400, detail="role must be client|driver")

    pool = request.app.state.pool
    async with pool.acquire() as con:
        row = await con.fetchrow(
            """
            UPDATE users
            SET role=$2, updated_at=now()
            WHERE tg_id=$1
            RETURNING tg_id, phone, full_name, role
            """,
            payload.tg_id, role
        )
    if not row:
        raise HTTPException(status_code=404, detail="user not found (send phone first)")
    return {"ok": True, "user": dict(row)}


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
        await conn.execute(f"""
            INSERT INTO users ({field}, phone, updated_at)
            VALUES ($1, $2, now())
            ON CONFLICT ({field})
            DO UPDATE SET phone=EXCLUDED.phone, updated_at=now()
        """, payload.external_id, phone11)

        row = await conn.fetchrow(f"SELECT tg_id, vk_id, phone, current_role FROM users WHERE {field}=$1", payload.external_id)
        return dict(row)

@router.post("/set_role", dependencies=[Depends(require_internal)])
async def set_role(payload: SetRoleIn, request: Request):
    field = "tg_id" if payload.platform == "tg" else "vk_id"
    pool = await _get_pool(request)
    async with pool.acquire() as conn:
        await conn.execute(f"""
            INSERT INTO users ({field}, updated_at)
            VALUES ($1, now())
            ON CONFLICT ({field})
            DO UPDATE SET updated_at=now()
        """, payload.external_id)

        await conn.execute(f"UPDATE users SET current_role=$1, updated_at=now() WHERE {field}=$2", payload.role, payload.external_id)

        row = await conn.fetchrow(f"SELECT tg_id, vk_id, phone, current_role FROM users WHERE {field}=$1", payload.external_id)
        return dict(row)
