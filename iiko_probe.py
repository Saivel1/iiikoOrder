import asyncio
import json
from pathlib import Path

import aiohttp

from iiko import get_token, post

DUMPS = Path("dumps")


def show(name: str, data) -> None:
    print(f"\n===== {name} =====")
    print(json.dumps(data, ensure_ascii=False, indent=2))
    DUMPS.mkdir(exist_ok=True)
    (DUMPS / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2))



def nomenclature_summary(data: dict) -> None:
    groups = {g["id"]: g["name"] for g in data.get("groups", [])}
    print(f"\n--- группы ({len(groups)}) ---")
    for gid, name in groups.items():
        print(f"  {name}  [{gid}]")

    products = data.get("products", [])
    print(f"\n--- продукты ({len(products)}) ---")
    for p in products:
        sizes = p.get("sizePrices") or []
        price = sizes[0]["price"].get("currentPrice") if sizes else None
        group = groups.get(p.get("parentGroup"), "-")
        print(f"  {p['name']:<40} {price!s:>8}  {p.get('type')}  ({group})  [{p['id']}]")


def menu_summary(data: dict) -> None:
    for cat in data.get("itemCategories", []):
        hidden = " (скрыта)" if cat.get("isHidden") else ""
        print(f"\n--- {cat['name']}{hidden} ({len(cat['items'])}) ---")
        for item in cat["items"]:
            sizes = ", ".join(
                f"{sz.get('sizeName') or '-'}: {sz['prices'][0]['price'] if sz['prices'] else None}"
                for sz in item["itemSizes"]
            )
            mods = sum(len(sz.get("itemModifierGroups") or []) for sz in item["itemSizes"])
            hidden = " (скрыт)" if item.get("isHidden") else ""
            print(f"  {item['name']:<40} {sizes}  мод.групп: {mods}{hidden}  [{item['itemId']}]")


async def main() -> None:
    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await get_token(session)
        if not token:
            return
        print("access_token получен")

        orgs = await post(
            session,
            "/api/1/organizations",
            {"returnAdditionalInfo": True, "includeDisabled": True},
            token,
        )
        if not orgs:
            return
        show("organizations", orgs)
        org_ids = [o["id"] for o in orgs["organizations"]]

        tg = await post(session, "/api/1/terminal_groups", {"organizationIds": org_ids}, token)
        tg_ids = []
        if tg:
            show("terminal_groups", tg)
            tg_ids = [t["id"] for g in tg["terminalGroups"] for t in g["items"]]

        for org_id in org_ids:
            nom = await post(session, "/api/1/nomenclature", {"organizationId": org_id}, token)
            if nom:
                show(f"nomenclature_{org_id}", nom)
                nomenclature_summary(nom)

        menus = await post(session, "/api/2/menu", {}, token)
        if menus:
            show("external_menus", menus)
            ext = menus.get("externalMenus") or []
            if ext:
                body = {"externalMenuId": ext[0]["id"], "organizationIds": org_ids}
                # iiko то требует категорию цен, то отклоняет её — передаём, только если вернулась
                if menus.get("priceCategories"):
                    body["priceCategoryId"] = menus["priceCategories"][0]["id"]
                menu = await post(session, "/api/2/menu/by_id", body, token)
                if menu:
                    show(f"menu_{ext[0]['id']}", menu)
                    menu_summary(menu)

        stops = await post(session, "/api/1/stop_lists", {"organizationIds": org_ids}, token)
        if stops:
            show("stop_lists", stops)

        if tg_ids:
            sections = await post(
                session,
                "/api/1/reserve/available_restaurant_sections",
                {"terminalGroupIds": tg_ids},
                token,
            )
            if sections:
                show("restaurant_sections", sections)


if __name__ == "__main__":
    asyncio.run(main())
