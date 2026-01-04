from __future__ import annotations
import os
import json
import uuid
import asyncio
import logging
import re

import httpx
from aiogram import Bot, Dispatcher, F, types
from aiogram.filters import CommandStart
from aiogram.types import (
    Message, CallbackQuery,
    ReplyKeyboardMarkup, KeyboardButton,
    InlineKeyboardMarkup, InlineKeyboardButton,
    ReplyKeyboardRemove,
    WebAppInfo
)

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

# In-memory flag for text-order flow (OK for now). If you need persistence across restarts,
# move it to DB.
_awaiting_order_text: set[int] = set()



# Sentinel: default behaviour is to KEEP existing inline keyboard on edit
KEEP_MARKUP = object()
def kb_phone() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(is_persistent=True, keyboard=[[KeyboardButton(text="📱 Отправить телефон", request_contact=True)]],
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


def inline_main_client() -> InlineKeyboardMarkup:
    """Client main menu (inline-only)."""
    rows = [
        [InlineKeyboardButton(text="🚕 Заказать", callback_data="c:order")],
        [InlineKeyboardButton(text="🗺️ Карта (MiniApp)", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))],
        [InlineKeyboardButton(text="🔁 Сменить роль", callback_data="c:switch_role")],
        [InlineKeyboardButton(text="🛡️ Обход/ВПН", url=VPN_BOT_LINK)],
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def inline_main_driver() -> InlineKeyboardMarkup:
    """Driver main menu (inline). Location request still needs reply keyboard."""
    rows = [
        [InlineKeyboardButton(text="📍 Поделиться гео", callback_data="d:geo")],
        [InlineKeyboardButton(text="🗺️ Карта (MiniApp)", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))],
        [InlineKeyboardButton(text="🧑‍✈️ Стать водителем", callback_data="d:reg")],
        [InlineKeyboardButton(text="🔁 Сменить роль", callback_data="c:switch_role")],
        [InlineKeyboardButton(text="🛡️ Обход/ВПН", url=VPN_BOT_LINK)],
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def inline_order_menu() -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(text="🗺️ Оформить через карту", web_app=WebAppInfo(url=f"{PUBLIC_BASE_URL}/miniapp/"))],
        [InlineKeyboardButton(text="📝 Оформить текстом", callback_data="order:text")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="menu:main")],
    ]
    return InlineKeyboardMarkup(inline_keyboard=rows)


def inline_cancel_to_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="⬅️ В меню", callback_data="menu:main")]])


def kb_driver_geo() -> ReplyKeyboardMarkup:
    return ReplyKeyboardMarkup(is_persistent=True, keyboard=[
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


async def safe_delete(m: Message):
    """Best-effort delete user's message to keep chat clean."""
    try:
        await m.delete()
    except Exception:
        return


async def ui_upsert(m: types.Message, text: str, reply_markup=KEEP_MARKUP, tg_id: int | None = None, **_):
    """
    Держим один 'UI-message' и редактируем его, чтобы:
    - кнопки/клавиатура не 'пропадали'
    - чат не засорялся кучей сообщений меню
    """
    tg_id = m.chat.id
    prev = await get_user_tg(tg_id)
    last_id = (prev or {}).get("ui_last_message_id")

    try:
        if last_id:
            kwargs = {}
            if reply_markup is not KEEP_MARKUP:
                kwargs["reply_markup"] = reply_markup

            # если пользователь нажал на кнопки в этом же сообщении - можно редактировать через m.edit_text
            if getattr(m, "message_id", None) == last_id:
                await m.edit_text(text, parse_mode="HTML", **kwargs)
            else:
                await bot.edit_message_text(
                    text=text,
                    chat_id=tg_id,
                    message_id=last_id,
                    parse_mode="HTML",
                    **kwargs
                )
            return last_id
    except Exception:
        # если не смогли отредактировать (удалили/старое/нет прав) — отправим заново
        pass

    kwargs = {}
    if reply_markup is not KEEP_MARKUP:
        kwargs["reply_markup"] = reply_markup

    sent = await bot.send_message(chat_id=tg_id, text=text, parse_mode="HTML", **kwargs)

    # сохраним id последнего UI-сообщения
    try:
        await backend_post("/api/users/ui_last", {"tg_id": int(tg_id), "message_id": int(sent.message_id)})
    except Exception:
        pass

    return sent.message_id



async def ensure_user(m: Message):
    user = await get_user_tg(m.from_user.id)
    if not user or not user.get("phone"):
        await ui_upsert(
            m,
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return None
    if not user.get("role"):
        await ui_upsert(m, "Выберите, кто вы:", reply_markup=inline_choose_role())
        return None
    return user


async def show_menu(m: Message, user: dict, tg_id: int | None = None):
    role = user.get("role") or "client"
    if role == "driver":
        await ui_upsert(
            m,
            f"Готово ✅ Текущая роль: {role_label(role)}",
            reply_markup=inline_main_driver(),
            tg_id=tg_id or int(user.get("tg_id") or 0) or None
        )
    else:
        await ui_upsert(
            m,
            f"Готово ✅ Текущая роль: {role_label(role)}",
            reply_markup=inline_main_client(),
            tg_id=tg_id or int(user.get("tg_id") or 0) or None
        )


@dp.message(CommandStart())
async def cmd_start(m: Message):
    await safe_delete(m)
    tg_id = m.from_user.id
    user = await get_user_tg(tg_id)

    if not user or not user.get("phone"):
        await ui_upsert(
            m,
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return

    if not user.get("role"):
        await ui_upsert(m, "Выберите, кто вы:", reply_markup=inline_choose_role())
        return

    await show_menu(m, user)


@dp.message(F.contact)
async def on_contact(m: Message):
    try:
        c = m.contact
        if not c:
            return
        if c.user_id and c.user_id != m.from_user.id:
            await ui_upsert(m, "Пожалуйста, отправьте *свой* телефон кнопкой ниже.", reply_markup=kb_phone(), parse_mode="Markdown")
            return

        await backend_post("/api/users/set_phone", {
            "platform": "tg",
            "external_id": int(m.from_user.id),
            "phone": c.phone_number,
            "full_name": m.from_user.full_name,
        })

        user = await get_user_tg(m.from_user.id)
        if not user or not user.get("role"):
            await ui_upsert(m, "Номер принят ✅ Теперь выберите роль:", reply_markup=inline_choose_role())
            return
        await show_menu(m, user)

    finally:
        await safe_delete(m)


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
        await show_menu(cb.message, user, tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.callback_query(F.data == "menu:main")
async def cb_menu_main(cb: CallbackQuery):
    _awaiting_order_text.discard(int(cb.from_user.id))
    user = await get_user_tg(cb.from_user.id)
    if not user or not user.get("phone"):
        await ui_upsert(cb.message, "Чтобы начать работу, отправьте номер телефона (кнопка ниже).", reply_markup=kb_phone(), tg_id=int(cb.from_user.id))
        await cb.answer()
        return
    if not user.get("role"):
        await ui_upsert(cb.message, "Выберите, кто вы:", reply_markup=inline_choose_role(), tg_id=int(cb.from_user.id))
        await cb.answer()
        return
    await show_menu(cb.message, user, tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.callback_query(F.data == "c:switch_role")
async def cb_switch_role(cb: CallbackQuery):
    _awaiting_order_text.discard(int(cb.from_user.id))
    await ui_upsert(cb.message, "Выберите новую роль:", reply_markup=inline_choose_role(), tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.callback_query(F.data == "c:order")
async def cb_order(cb: CallbackQuery):
    _awaiting_order_text.discard(int(cb.from_user.id))
    user = await get_user_tg(cb.from_user.id)
    if not user or user.get("role") != "client":
        await ui_upsert(
            cb.message,
            "Заказ доступен только для клиента. Смените роль.",
            reply_markup=inline_main_driver() if user and user.get("role") == "driver" else inline_choose_role(),
            tg_id=int(cb.from_user.id),
        )
        await cb.answer()
        return
    await ui_upsert(cb.message, "Как оформить заказ?", reply_markup=inline_order_menu(), tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.callback_query(F.data == "order:text")
async def cb_order_text(cb: CallbackQuery):
    user = await get_user_tg(cb.from_user.id)
    if not user or user.get("role") != "client":
        await ui_upsert(cb.message, "Текстовый заказ доступен только клиенту.", reply_markup=inline_cancel_to_menu(), tg_id=int(cb.from_user.id))
        await cb.answer()
        return
    _awaiting_order_text.add(int(cb.from_user.id))
    await ui_upsert(
        cb.message,
        "📝 *Текстовый заказ*\n\n"
        "Отправьте одним сообщением маршрут в формате:\n"
        "`Откуда -> Остановка (опционально) -> Куда`\n\n"
        "Пример:\n"
        "`Вилючинск, Профсоюзная 10 -> Петропавловск-Камчатский, Аэропорт`\n\n"
        "Комментарий можно добавить через `|` (палка).\n"
        "Пример: `... -> ... | Детское кресло`",
        reply_markup=inline_cancel_to_menu(),
        parse_mode="Markdown",
        tg_id=int(cb.from_user.id),
    )
    await cb.answer()


@dp.callback_query(F.data == "d:geo")
async def cb_driver_geo(cb: CallbackQuery):
    _awaiting_order_text.discard(int(cb.from_user.id))
    user = await get_user_tg(cb.from_user.id)
    if not user or user.get("role") != "driver":
        await ui_upsert(cb.message, "Эта кнопка для водителей. Смените роль.", reply_markup=inline_choose_role(), tg_id=int(cb.from_user.id))
        await cb.answer()
        return
    # For location request we must use reply-keyboard (Telegram limitation)
    await ui_upsert(cb.message, "Нажмите кнопку ниже и отправьте геопозицию:", reply_markup=kb_driver_geo(), tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.callback_query(F.data == "d:reg")
async def cb_driver_reg(cb: CallbackQuery):
    _awaiting_order_text.discard(int(cb.from_user.id))
    if DRIVER_REG_LINK:
        await ui_upsert(cb.message, "Регистрация водителя:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🧑‍✈️ Стать водителем", url=DRIVER_REG_LINK)],
            [InlineKeyboardButton(text="⬅️ В меню", callback_data="menu:main")],
        ]), tg_id=int(cb.from_user.id))
    else:
        await ui_upsert(cb.message, "DRIVER_REG_LINK не задан", reply_markup=inline_cancel_to_menu(), tg_id=int(cb.from_user.id))
    await cb.answer()


@dp.message(F.text == "🔁 Сменить роль")
@dp.message(F.text.startswith("/role"))
async def switch_role(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    _awaiting_order_text.discard(int(m.from_user.id))
    await ui_upsert(m, "Выберите новую роль:", reply_markup=inline_choose_role())


@dp.message(F.text == "⬅️ Назад")
async def back(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    _awaiting_order_text.discard(int(m.from_user.id))
    await show_menu(m, user)


@dp.message(F.text == "🗺️ Карта (MiniApp)")
async def map_open(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    _awaiting_order_text.discard(int(m.from_user.id))
    await ui_upsert(m, "Открывай карту:", reply_markup=inline_open_map())


@dp.message(F.location)
async def location(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "driver":
        await ui_upsert(m, "Геопозицию принимаю только от водителей.", reply_markup=inline_cancel_to_menu())
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
    await ui_upsert(m, "✅ Геопозиция водителя обновлена.", reply_markup=inline_main_driver())


@dp.message(F.web_app_data)
async def webapp(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "client":
        await ui_upsert(m, "Заказы создаёт только клиент.", reply_markup=inline_cancel_to_menu())
        return

    try:
        data = json.loads(m.web_app_data.data)
    except Exception:
        await ui_upsert(m, "Не смог прочитать данные с карты. Попробуйте ещё раз.", reply_markup=inline_order_menu())
        return

    phone = (user.get("phone") or "").strip()
    if not phone:
        await ui_upsert(m, "Сначала зарегистрируйте телефон через /start", reply_markup=kb_phone())
        return

    from_obj = data.get("from") or {}
    to_list = data.get("to") or []
    if not from_obj or not to_list:
        await ui_upsert(m, "Нужно указать Откуда и Куда.", reply_markup=inline_order_menu())
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
        await ui_upsert(m, f"Ошибка создания заказа: {e.response.text[:1200]}", reply_markup=inline_order_menu())
        return

    _awaiting_order_text.discard(int(m.from_user.id))
    await ui_upsert(
        m,
        f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидайте назначения водителя.",
        reply_markup=inline_main_client(),
    )


def _split_comment(text: str) -> tuple[str, str]:
    # route | comment
    if "|" in (text or ""):
        left, right = text.split("|", 1)
        return left.strip(), right.strip()
    return (text or "").strip(), ""


def _parse_route(text: str) -> list[str]:
    """Parse a route from free text.

    Accept formats:
      A -> B
      A -> Stop -> B
      A; Stop; B
      lines: A\nStop\nB
    """
    t = (text or "").strip()
    if not t:
        return []

    if any(x in t for x in ("->", "→", "=>")):
        parts = [p.strip() for p in re.split(r"\s*(?:->|→|=>)\s*", t) if p.strip()]
        return parts
    if ";" in t:
        return [p.strip() for p in t.split(";") if p.strip()]
    if "\n" in t:
        return [p.strip() for p in t.splitlines() if p.strip()]
    return []


def _urlencode_q(q: str) -> str:
    return httpx.QueryParams({"q": q})["q"]


async def _geo_first(q: str) -> tuple[str, float | None, float | None]:
    """Geocode via backend geo proxy; best-effort."""
    try:
        res = await backend_get(f"/api/geo/search?q={_urlencode_q(q)}&limit=1")
    except Exception:
        return q, None, None
    if isinstance(res, list) and res:
        best = res[0]
        try:
            lat = float(best.get("lat"))
            lon = float(best.get("lon"))
        except Exception:
            lat = None
            lon = None
        return (best.get("display_name") or q), lat, lon
    return q, None, None


@dp.message(F.text)
async def fallback_text(m: Message):
    """Client-side UX:
    - keep chat clean (delete user's messages)
    - allow text orders when user is in order-text mode, or when message clearly looks like a route
    """
    try:
        if (m.text or "").startswith("/"):
            return

        user = await ensure_user(m)
        if not user:
            return

        tg_id = int(m.from_user.id)
        role = user.get("role") or "client"
        text_raw = (m.text or "").strip()

        if not text_raw:
            await ui_upsert(m, "Откройте меню ниже.", reply_markup=inline_main_client() if role == "client" else inline_main_driver())
            return

        route_text, comment = _split_comment(text_raw)
        route = _parse_route(route_text)
        looks_like_route = len(route) >= 2

        if role == "client" and (tg_id in _awaiting_order_text or looks_like_route):
            if not looks_like_route:
                await ui_upsert(
                    m,
                    "Не понял маршрут. Пример: `Адрес 1 -> Адрес 2`",
                    reply_markup=inline_cancel_to_menu(),
                    parse_mode="Markdown",
                )
                return

            phone = (user.get("phone") or "").strip()
            if not phone:
                await ui_upsert(m, "Сначала зарегистрируйте телефон через /start", reply_markup=kb_phone())
                return

            def ctx(addr: str) -> str:
                a = addr.strip()
                low = a.lower()
                if "камчат" in low or "вилючин" in low or "петропав" in low:
                    return a
                return f"{a}, Вилючинск, Камчатка"

            names: list[str] = []
            lats: list[float | None] = []
            lons: list[float | None] = []
            for addr in route:
                n, lat, lon = await _geo_first(ctx(addr))
                names.append(n)
                lats.append(lat)
                lons.append(lon)

            from_address = names[0]
            to_addresses = names[1:]

            extern_id = f"tg-{tg_id}-{uuid.uuid4().hex[:10]}"
            payload = {
                "phone": phone,
                "client_name": (user.get("full_name") or m.from_user.full_name or "").strip(),
                "comment": comment,
                "from_address": from_address,
                "from_lat": lats[0],
                "from_lon": lons[0],
                "to_addresses": to_addresses,
                "to_lats": lats[1:],
                "to_lons": lons[1:],
                "tg_user_id": tg_id,
                "extern_id": extern_id,
            }

            try:
                res = await backend_post("/api/orders/create", payload)
            except httpx.HTTPStatusError as e:
                await ui_upsert(m, f"Ошибка создания заказа: {e.response.text[:1200]}", reply_markup=inline_order_menu())
                return

            _awaiting_order_text.discard(tg_id)
            await ui_upsert(
                m,
                f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидайте назначения водителя.",
                reply_markup=inline_main_client(),
            )
            return

        await ui_upsert(
            m,
            "Откройте меню ниже.",
            reply_markup=inline_main_client() if role == "client" else inline_main_driver(),
        )
    finally:
        await safe_delete(m)


async def main():
    logging.basicConfig(level=logging.INFO)
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
