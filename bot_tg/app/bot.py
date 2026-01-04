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

async def safe_delete(m: Message):
    """Best-effort delete user's message to keep chat clean."""
    try:
        await m.delete()
    except Exception:
        return


async def ui_send(m: Message, text: str, reply_markup=None, parse_mode=None):
    """Keep a single 'UI' bot message: delete previous UI message then send new."""
    tg_id = int(m.from_user.id)
    chat_id = int(m.chat.id)

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

    # store last UI message id in backend
    await backend_post("/api/users/set_ui_message", {
        "platform": "tg",
        "external_id": tg_id,
        "chat_id": chat_id,
        "message_id": int(sent.message_id),
    })
    return sent


async def ensure_user(m: Message):
    user = await get_user_tg(m.from_user.id)
    if not user or not user.get("phone"):
        await ui_send(m, 
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return None
    if not user.get("role"):
        await ui_send(m, "Выберите, кто вы:", reply_markup=inline_choose_role())
        return None
    return user


async def show_menu(m: Message, user: dict):
    role = user.get("role") or "client"
    if role == "driver":
        await ui_send(m, f"Готово ✅ Текущая роль: {role_label(role)}", reply_markup=kb_main_driver())
    else:
        await ui_send(m, f"Готово ✅ Текущая роль: {role_label(role)}", reply_markup=kb_main_client())


@dp.message(CommandStart())
async def cmd_start(m: Message):
    await safe_delete(m)
    tg_id = m.from_user.id
    user = await get_user_tg(tg_id)

    if not user or not user.get("phone"):
        await ui_send(m, 
            "Чтобы начать работу, отправьте номер телефона (кнопка ниже).\n"
            "Роль можно будет менять в любой момент.",
            reply_markup=kb_phone(),
        )
        return

    if not user.get("role"):
        await ui_send(m, "Выберите, кто вы:", reply_markup=inline_choose_role())
        return

    await show_menu(m, user)


@dp.message(F.contact)
async def on_contact(m: Message):
    try:
        c = m.contact
        if not c:
            return
        if c.user_id and c.user_id != m.from_user.id:
            await ui_send(m, "Пожалуйста, отправьте *свой* телефон кнопкой ниже.", reply_markup=kb_phone(), parse_mode="Markdown")
            return

        await backend_post("/api/users/set_phone", {
            "platform": "tg",
            "external_id": int(m.from_user.id),
            "phone": c.phone_number,
            "full_name": m.from_user.full_name,
        })

        user = await get_user_tg(m.from_user.id)
        if not user or not user.get("role"):
            await ui_send(m, "Номер принят ✅ Теперь выберите роль:", reply_markup=inline_choose_role())
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
        await show_menu(cb.message, user)
    await cb.answer()


@dp.message(F.text == "🔁 Сменить роль")
@dp.message(F.text.startswith("/role"))
async def switch_role(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    await ui_send(m, "Выберите новую роль:", reply_markup=inline_choose_role())


@dp.message(F.text == "⬅️ Назад")
async def back(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    await show_menu(m, user)


@dp.message(F.text == "🗺️ Карта (MiniApp)")
async def map_open(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    await ui_send(m, "Открывай карту:", reply_markup=inline_open_map())


@dp.message(F.text == "🚕 Заказать такси")
async def order(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "client":
        await ui_send(m, "Эта кнопка для клиентов. Если вы водитель — нажмите «🔁 Сменить роль».")
        return
    await ui_send(m, "Заказ делается через карту:", reply_markup=inline_open_map())


@dp.message(F.text == "📍 Я водитель — поделиться гео")
async def driver_geo_menu(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "driver":
        await ui_send(m, "Эта кнопка для водителей. Если вы клиент — нажмите «🔁 Сменить роль».")
        return
    await ui_send(m, "Нажмите кнопку и отправьте геопозицию:", reply_markup=kb_driver_geo())


@dp.message(F.text == "🧑‍✈️ Стать водителем")
async def reg_driver(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if DRIVER_REG_LINK:
        await ui_send(m, "Регистрация водителя:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
            [InlineKeyboardButton(text="🧑‍✈️ Стать водителем", url=DRIVER_REG_LINK)]
        ]))
    else:
        await ui_send(m, "DRIVER_REG_LINK не задан")


@dp.message(F.text == "🛡️ Обход/ВПН")
async def vpn(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    await ui_send(m, "Бот обхода:", reply_markup=InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🛡️ Открыть", url=VPN_BOT_LINK)]
    ]))


@dp.message(F.location)
async def location(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "driver":
        await ui_send(m, "Геопозицию принимаю только от водителей.")
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
    await ui_send(m, "✅ Геопозиция водителя обновлена.")


@dp.message(F.web_app_data)
async def webapp(m: Message):
    await safe_delete(m)
    user = await ensure_user(m)
    if not user:
        return
    if user.get("role") != "client":
        await ui_send(m, "Заказы создаёт только клиент.")
        return

    try:
        data = json.loads(m.web_app_data.data)
    except Exception:
        await ui_send(m, "Не смог прочитать данные с карты. Попробуйте ещё раз.")
        return

    phone = (user.get("phone") or "").strip()
    if not phone:
        await ui_send(m, "Сначала зарегистрируйте телефон через /start")
        return

    from_obj = data.get("from") or {}
    to_list = data.get("to") or []
    if not from_obj or not to_list:
        await ui_send(m, "Нужно указать Откуда и Куда.")
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
        await ui_send(m, f"Ошибка создания заказа: {e.response.text[:1200]}")
        return

    await ui_send(m, f"✅ Заказ создан. ID: {res.get('taxomet_order_id')}\nОжидайте назначения водителя.")


async def main():
    logging.basicConfig(level=logging.INFO)
    await bot.delete_webhook(drop_pending_updates=True)
    await dp.start_polling(bot, allowed_updates=dp.resolve_used_update_types())


if __name__ == "__main__":
    asyncio.run(main())
