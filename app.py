"""Заказы со столиков: гость заказывает по QR, заказ уходит на кассу iiko, бариста ведёт только стоп-лист.
Запуск в один воркер — лимит частоты заказов живёт в памяти процесса.

    uv run uvicorn app:app --host 0.0.0.0 --port 8000 --workers 1
"""

import asyncio
import json
import secrets
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

import aiosqlite
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field

import db
import iiko
from config import setting

RATE_LIMIT_SECONDS = 10
MENU_PHOTOS = Path("static/menu")
PHOTO_EXTS = (".webp", ".jpg", ".jpeg", ".png")

conn: aiosqlite.Connection
last_order_at: dict[tuple[int, str], float] = {}
background_tasks: set[asyncio.Task] = set()
templates = Jinja2Templates(directory="templates")


@asynccontextmanager
async def lifespan(_: FastAPI):
    global conn
    conn = await db.connect()
    yield
    await conn.close()


app = FastAPI(lifespan=lifespan)
MENU_PHOTOS.mkdir(parents=True, exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


async def load_order(order_id: int) -> dict | None:
    async with conn.execute(
        """SELECT o.*, t.name AS table_name, t.token AS table_token
           FROM orders o JOIN tables t ON t.id = o.table_id WHERE o.id = ?""",
        (order_id,),
    ) as cur:
        row = await cur.fetchone()
    if not row:
        return None
    order = dict(row)
    async with conn.execute(
        """SELECT menu_item_id, qty, price_snapshot AS price, name_snapshot AS name, modifiers
           FROM order_items WHERE order_id = ?""",
        (order_id,),
    ) as cur:
        order["items"] = [{**dict(r), "modifiers": json.loads(r["modifiers"])} async for r in cur]
    return order


# ---------- Гость ----------


@app.get("/t/{token}", response_class=HTMLResponse)
async def table_page(request: Request, token: str):
    async with conn.execute("SELECT name FROM tables WHERE token = ?", (token,)) as cur:
        table = await cur.fetchone()
    if not table:
        raise HTTPException(404, "Стол не найден")
    return templates.TemplateResponse(request, "table.html", {"table_name": table["name"], "token": token})


def local_photos() -> dict[str, str]:
    """Свои фото: static/menu/<артикул iiko>.jpg — перекрывают фото из iiko."""
    photos = {}
    for f in MENU_PHOTOS.iterdir():
        if f.suffix.lower() in PHOTO_EXTS:
            photos[f.stem] = f"/static/menu/{f.name}?v={int(f.stat().st_mtime)}"
    return photos


@app.get("/api/menu")
async def menu():
    photos = local_photos()
    async with conn.execute(
        """SELECT id, name, price, category, description, sku, image_url, modifiers
           FROM menu_items WHERE is_available = 1 ORDER BY sort"""
    ) as cur:
        rows = [dict(r) async for r in cur]
    for r in rows:
        r["image"] = photos.get(r.pop("sku") or "") or r.pop("image_url")
        r.pop("image_url", None)
        r["modifiers"] = json.loads(r["modifiers"])
    return rows


class ModifierIn(BaseModel):
    id: str
    amount: int = Field(ge=1, le=10)


class OrderItemIn(BaseModel):
    menu_item_id: int
    qty: int = Field(ge=1, le=10)
    modifiers: list[ModifierIn] = Field(default=[], max_length=30)


def check_modifiers(item_name: str, groups: list[dict], chosen: list[ModifierIn]) -> list[dict]:
    """Проверяет выбор по ограничениям iiko и возвращает снимок модификаторов с ценами из меню."""
    known = {m["id"]: m for g in groups for m in g["items"]}
    amounts: dict[str, int] = {}
    for c in chosen:
        if c.id not in known:
            raise HTTPException(409, f"«{item_name}»: меню обновилось, соберите позицию заново")
        amounts[c.id] = amounts.get(c.id, 0) + c.amount

    snapshot = []
    for g in groups:
        total = 0
        for m in g["items"]:
            amount = amounts.get(m["id"], 0)
            if not m["min"] <= amount <= m["max"]:
                raise HTTPException(422, f"«{item_name}»: слишком много «{m['name']}»")
            total += amount
            if amount:
                snapshot.append(
                    {"id": m["id"], "name": m["name"], "price": m["price"], "amount": amount, "group_id": g["group_id"]}
                )
        if total < g["min"]:
            raise HTTPException(422, f"«{item_name}»: выберите «{g['name']}»")
        if total > g["max"]:
            raise HTTPException(422, f"«{item_name}»: в «{g['name']}» можно не больше {g['max']}")
    return snapshot


class OrderIn(BaseModel):
    table_token: str
    guest_name: str = Field(min_length=1, max_length=30)
    items: list[OrderItemIn] = Field(min_length=1, max_length=20)
    comment: str = Field(default="", max_length=200)


@app.post("/api/orders")
async def create_order(body: OrderIn):
    async with conn.execute("SELECT id FROM tables WHERE token = ?", (body.table_token,)) as cur:
        table = await cur.fetchone()
    if not table:
        raise HTTPException(404, "Стол не найден")

    guest_name = body.guest_name.strip()
    if not guest_name:
        raise HTTPException(422, "Укажите имя")
    key = (table["id"], guest_name.lower())
    if time.monotonic() - last_order_at.get(key, 0) < RATE_LIMIT_SECONDS:
        raise HTTPException(429, "Подождите пару секунд перед следующим заказом")

    ids = [i.menu_item_id for i in body.items]
    placeholders = ",".join("?" * len(ids))
    async with conn.execute(
        f"SELECT id, name, price, modifiers FROM menu_items WHERE is_available = 1 AND id IN ({placeholders})",
        ids,
    ) as cur:
        available = {r["id"]: r async for r in cur}
    missing = [i for i in ids if i not in available]
    if missing:
        raise HTTPException(409, "Часть позиций закончилась, обновите меню")

    lines = []
    for i in body.items:
        item = available[i.menu_item_id]
        mods = check_modifiers(item["name"], json.loads(item["modifiers"]), i.modifiers)
        lines.append((i.menu_item_id, i.qty, item["price"], item["name"], json.dumps(mods, ensure_ascii=False)))

    ts = now()
    iiko_status = "sending" if setting.IIKO_SEND_ORDERS else "off"
    cur = await conn.execute(
        """INSERT INTO orders (table_id, guest_name, comment, created_at, updated_at, iiko_status)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (table["id"], guest_name, body.comment.strip(), ts, ts, iiko_status),
    )
    order_id = cur.lastrowid
    await conn.executemany(
        """INSERT INTO order_items (order_id, menu_item_id, qty, price_snapshot, name_snapshot, modifiers)
           VALUES (?, ?, ?, ?, ?, ?)""",
        [(order_id, *line) for line in lines],
    )
    await conn.commit()
    last_order_at[key] = time.monotonic()

    if setting.IIKO_SEND_ORDERS:
        start_iiko_send(order_id)
    return {"id": order_id}


@app.get("/api/orders/{order_id}")
async def order_status(order_id: int, token: str):
    order = await load_order(order_id)
    # Токен стола обязателен, чтобы нельзя было перебирать чужие заказы по id
    if not order or not secrets.compare_digest(order["table_token"], token):
        raise HTTPException(404, "Заказ не найден")
    return {k: order[k] for k in ("id", "status", "guest_name", "comment", "created_at", "items", "iiko_status", "iiko_number")}


# ---------- iiko ----------


def iiko_comment(order: dict) -> str:
    parts = [order["guest_name"], order["comment"]]
    return " · ".join(p for p in parts if p)[:255]


async def send_to_iiko(order_id: int) -> None:
    order = await load_order(order_id)
    meta = await db.get_meta(conn)
    async with conn.execute(
        """SELECT t.iiko_table_id, oi.qty, oi.price_snapshot, oi.modifiers, m.iiko_product_id
           FROM order_items oi
           JOIN orders o ON o.id = oi.order_id
           JOIN tables t ON t.id = o.table_id
           JOIN menu_items m ON m.id = oi.menu_item_id
           WHERE oi.order_id = ?""",
        (order_id,),
    ) as cur:
        rows = [dict(r) async for r in cur]

    comment = iiko_comment(order)
    try:
        iiko_order_id, iiko_number = await iiko.send_table_order(
            meta["org_id"],
            meta["terminal_group_id"],
            rows[0]["iiko_table_id"],
            [
                {
                    "productId": r["iiko_product_id"],
                    "price": r["price_snapshot"],
                    "amount": r["qty"],
                    "comment": comment,
                    # amount модификатора — на одну порцию блюда
                    "modifiers": [
                        {
                            "productId": m["id"],
                            "amount": m["amount"],
                            "price": m["price"],
                            **({"productGroupId": m["group_id"]} if m["group_id"] else {}),
                        }
                        for m in json.loads(r["modifiers"])
                    ],
                }
                for r in rows
            ],
        )
        update = ("sent", iiko_order_id, iiko_number, None)
    except Exception as e:  # сеть, iiko, что угодно — гость увидит, что надо подойти к бариста
        update = ("error", None, None, str(e)[:500])

    await conn.execute(
        "UPDATE orders SET iiko_status = ?, iiko_order_id = ?, iiko_number = ?, iiko_error = ? WHERE id = ?",
        (*update, order_id),
    )
    await conn.commit()


def start_iiko_send(order_id: int) -> None:
    task = asyncio.create_task(send_to_iiko(order_id))
    background_tasks.add(task)
    task.add_done_callback(background_tasks.discard)


# ---------- Бариста: стоп-лист ----------


def bar_auth(key: str = Query(...)) -> None:
    if not secrets.compare_digest(key, setting.BAR_KEY):
        raise HTTPException(403, "Неверный ключ")


@app.get("/bar", response_class=HTMLResponse, dependencies=[Depends(bar_auth)])
async def bar_page(request: Request, key: str):
    return templates.TemplateResponse(request, "bar.html", {"key": key})


@app.get("/api/bar/menu", dependencies=[Depends(bar_auth)])
async def bar_menu():
    async with conn.execute("SELECT id, name, price, category, is_available FROM menu_items ORDER BY sort") as cur:
        return [dict(r) async for r in cur]


class AvailabilityIn(BaseModel):
    is_available: bool


@app.patch("/api/bar/menu/{item_id}", dependencies=[Depends(bar_auth)])
async def set_availability(item_id: int, body: AvailabilityIn):
    cur = await conn.execute("UPDATE menu_items SET is_available = ? WHERE id = ?", (int(body.is_available), item_id))
    await conn.commit()
    if not cur.rowcount:
        raise HTTPException(404, "Позиция не найдена")
    return {"id": item_id, "is_available": body.is_available}
