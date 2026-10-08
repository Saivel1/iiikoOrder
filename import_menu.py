"""Забирает из iiko меню, столы и id кассы в app.db. Можно запускать повторно:
цены и названия обновятся, стоп-лист и токены столов (QR) сохранятся."""

import asyncio
import json
import re
import secrets

import aiohttp

import db
from config import setting
from iiko import access_token, request

SKIP_ITEMS = {"Свободный товар"}
# Гости сидят за столом — упаковка «с собой» им не нужна
SKIP_MODIFIERS = re.compile(r"^с собой", re.I)
# Технические названия групп из iiko → понятные гостю
GROUP_TITLES = {
    "Модификаторы": "Добавки",
    "Модификатор Чёрный кофе": "Добавить в кофе",
    "Мороженное мод": "Вкус",
    "Чай Авторские Бочонки": "Чай",
    "Основа фреш": "Фрукт",
    "Чайная основа": "Чай",
}


def parse_modifiers(size: dict) -> list[dict]:
    """Группы модификаторов размера блюда. У каждого модификатора — эффективные min/max:
    для «простых» (childModifiersHaveMinMaxRestrictions) свои, у групповых ограничивает только группа."""
    groups = []
    for g in size.get("itemModifierGroups") or []:
        if g.get("isHidden"):
            continue
        own_limits = bool(g.get("childModifiersHaveMinMaxRestrictions"))
        group_max = g["restrictions"]["maxQuantity"]
        mods = []
        for m in g["items"]:
            if m.get("isHidden") or SKIP_MODIFIERS.match(m["name"]):
                continue
            r = m["restrictions"]
            mods.append(
                {
                    "id": m["itemId"],
                    "name": m["name"].lstrip("- ").strip(),
                    "price": (m["prices"][0]["price"] if m.get("prices") else None) or 0,
                    "min": r["minQuantity"] if own_limits else 0,
                    "max": r["maxQuantity"] if own_limits and r["maxQuantity"] else group_max,
                }
            )
        if not mods:
            continue
        groups.append(
            {
                "name": GROUP_TITLES.get(g["name"], g["name"]),
                "group_id": g.get("itemGroupId"),  # есть только у групповых модификаторов
                "min": g["restrictions"]["minQuantity"],
                "max": group_max,
                "items": mods,
            }
        )
    return groups



async def fetch() -> dict:
    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await access_token(session)

        orgs = await request(session, "/api/1/organizations", {}, token)
        org_id = orgs["organizations"][0]["id"]

        tg = await request(session, "/api/1/terminal_groups", {"organizationIds": [org_id]}, token)
        terminal_group_id = tg["terminalGroups"][0]["items"][0]["id"]

        menus = await request(session, "/api/2/menu", {}, token)
        body = {"externalMenuId": menus["externalMenus"][0]["id"], "organizationIds": [org_id]}
        # iiko то требует категорию цен, то отклоняет её — передаём, только если вернулась
        if menus.get("priceCategories"):
            body["priceCategoryId"] = menus["priceCategories"][0]["id"]
        menu = await request(session, "/api/2/menu/by_id", body, token)

        sections = await request(
            session,
            "/api/1/reserve/available_restaurant_sections",
            {"terminalGroupIds": [terminal_group_id]},
            token,
        )
    return {"org_id": org_id, "terminal_group_id": terminal_group_id, "menu": menu, "sections": sections}


def parse_menu(menu: dict) -> list[dict]:
    items = []
    for cat in menu["itemCategories"]:
        if cat.get("isHidden") or not cat.get("name"):
            continue
        for item in cat["items"]:
            if item.get("isHidden") or item["name"] in SKIP_ITEMS:
                continue
            size = next((s for s in item["itemSizes"] if s.get("isDefault")), item["itemSizes"][0])
            price = size["prices"][0]["price"] if size["prices"] else None
            if price is None:
                continue
            items.append(
                {
                    "name": item["name"],
                    "price": price,
                    "category": cat["name"],
                    "sort": len(items),
                    "iiko_product_id": item["itemId"],
                    "sku": item.get("sku") or size.get("sku"),
                    "description": (item.get("description") or "").strip(),
                    # Фото в iiko живёт на размере; своё фото в static/menu/ перекрывает его
                    "image_url": size.get("buttonImageUrl")
                    or next((s["buttonImageUrl"] for s in item["itemSizes"] if s.get("buttonImageUrl")), None),
                    "modifiers": json.dumps(parse_modifiers(size), ensure_ascii=False),
                }
            )
    return items


def parse_tables(sections: dict) -> list[dict]:
    tables = []
    for section in sections["restaurantSections"]:
        for t in sorted(section["tables"], key=lambda t: t["number"]):
            if t.get("isDeleted"):
                continue
            # На кассе бариста видит название стола, номер в iiko с ним не совпадает
            tables.append({"name": f"{section['name']} · {t['name']}", "iiko_table_id": t["id"]})
    return tables


async def main() -> None:
    data = await fetch()
    items = parse_menu(data["menu"])
    tables = parse_tables(data["sections"])

    conn = await db.connect()
    try:
        await conn.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [("org_id", data["org_id"]), ("terminal_group_id", data["terminal_group_id"])],
        )
        await conn.executemany(
            """INSERT INTO menu_items (name, price, category, sort, iiko_product_id, sku, description, image_url, modifiers)
               VALUES (:name, :price, :category, :sort, :iiko_product_id, :sku, :description, :image_url, :modifiers)
               ON CONFLICT(iiko_product_id) DO UPDATE SET
                 name = excluded.name, price = excluded.price,
                 category = excluded.category, sort = excluded.sort, sku = excluded.sku,
                 description = excluded.description, image_url = excluded.image_url,
                 modifiers = excluded.modifiers""",
            items,
        )
        await conn.executemany(
            """INSERT INTO tables (name, token, iiko_table_id) VALUES (:name, :token, :iiko_table_id)
               ON CONFLICT(iiko_table_id) DO UPDATE SET name = excluded.name""",
            [{**t, "token": secrets.token_urlsafe(8)} for t in tables],
        )
        await conn.commit()

        with_photo = sum(1 for i in items if i["image_url"])
        with_mods = sum(1 for i in items if i["modifiers"] != "[]")
        print(
            f"Меню: {len(items)} позиций (с фото из iiko: {with_photo}, с модификаторами: {with_mods}), "
            f"столов: {len(tables)}"
        )
        async with conn.execute("SELECT name, token FROM tables ORDER BY id") as cur:
            async for row in cur:
                print(f"  {row['name']:<20} {setting.BASE_URL}/t/{row['token']}")
        print(f"\nСтоп-лист для бариста: {setting.BASE_URL}/bar?key={setting.BAR_KEY}")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
