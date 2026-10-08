"""Клиент iikoCloud API: токен, запросы, отправка заказа на стол."""

import asyncio
import json
import time

import aiohttp

from config import setting

BASE = "https://api-ru.iiko.services"
TOKEN_TTL = 45 * 60  # токен живёт час, обновляем заранее

_token: str | None = None
_token_at = 0.0


class IikoError(Exception):
    pass


async def request(session: aiohttp.ClientSession, path: str, body: dict, token: str | None = None) -> dict:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    async with session.post(BASE + path, json=body, headers=headers) as resp:
        text = await resp.text()
        if resp.status != 200:
            try:
                text = json.loads(text).get("errorDescription") or text
            except ValueError:
                pass
            raise IikoError(f"{path} -> {resp.status}: {text}")
        return json.loads(text)


async def post(session: aiohttp.ClientSession, path: str, body: dict, token: str | None = None):
    """Как request, но печатает ошибку и возвращает None — для разведочных скриптов."""
    try:
        return await request(session, path, body, token)
    except IikoError as e:
        print(f"\n!!! {e}")
        return None


async def access_token(session: aiohttp.ClientSession) -> str:
    global _token, _token_at
    if _token and time.monotonic() - _token_at < TOKEN_TTL:
        return _token
    if setting.IIKO_APP_ID and setting.IIKO_CLIENT_SECRET:
        auth = await request(
            session,
            "/api/v2/access_token",
            {
                "apiKey": setting.TOKEN,
                "clientSecret": setting.IIKO_CLIENT_SECRET,
                "appId": setting.IIKO_APP_ID,
            },
        )
    else:
        auth = await request(session, "/api/1/access_token", {"apiLogin": setting.TOKEN})
    _token, _token_at = auth["token"], time.monotonic()
    return _token


async def get_token(session: aiohttp.ClientSession) -> str | None:
    try:
        return await access_token(session)
    except IikoError as e:
        print(f"\n!!! {e}")
        return None


async def send_table_order(
    org_id: str,
    terminal_group_id: str,
    table_id: str,
    items: list[dict],
) -> tuple[str, int | None]:
    """Создаёт заказ на стол и ждёт, пока его примет касса.
    Возвращает id заказа в iiko и его номер — тот, что кассир видит в iikoFront.

    items: [{"productId", "price", "amount", "comment"}]
    """
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await access_token(session)
        created = await request(
            session,
            "/api/1/order/create",
            {
                "organizationId": org_id,
                "terminalGroupId": terminal_group_id,
                "order": {
                    "tableIds": [table_id],
                    "items": [{"type": "Product", **item} for item in items],
                },
                "createOrderSettings": {"servicePrint": False, "transportToFrontTimeout": 40},
            },
            token,
        )
        order_id = created["orderInfo"]["id"]

        # Заказ доставляется на кассу асинхронно
        for _ in range(20):
            await asyncio.sleep(3)
            status = await request(
                session,
                "/api/1/commands/status",
                {"organizationId": org_id, "correlationId": created["correlationId"]},
                token,
            )
            if status["state"] == "Success":
                found = await request(
                    session, "/api/1/order/by_id", {"organizationIds": [org_id], "orderIds": [order_id]}, token
                )
                order = (found["orders"] or [{}])[0].get("order") or {}
                return order_id, order.get("number")
            if status["state"] == "Error":
                reason = status.get("errorReason") or status.get("exception") or "неизвестная ошибка"
                raise IikoError(f"касса не приняла заказ: {reason}")
        raise IikoError("касса не подтвердила заказ за минуту — проверьте, что iikoFront онлайн")
