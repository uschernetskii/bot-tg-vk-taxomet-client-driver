import os
from fastapi import APIRouter, Request, Header, HTTPException
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

@router.get("/by_tg/{tg_id}")
async def by_tg(tg_id: int, request: Request, x_internal_token: str = Header(default="")):
    require_internal(x_internal_token)
    pool = request.app.state.pool
    async with pool.acquire() as con:
        row = await con.fetchrow(
            "SELECT tg_id, phone, full_name, role FROM users WHERE tg_id=$1",
            tg_id
        )
    if not row:
        return {"exists": False}
    return {"exists": True, "user": dict(row)}

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
