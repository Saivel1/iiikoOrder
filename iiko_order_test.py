"""Тестовый заказ на стол в iiko: создаёт заказ и ждёт, пока он доедет до iikoFront."""

import asyncio
import json

import aiohttp

from iiko import get_token, post

ORG_ID = "e423edf3-39e5-464d-842c-fd599e5ac7d4"  # Кофейня Брутто
TERMINAL_GROUP_ID = "cd803bf4-dcad-e53e-01a0-34222af20067"  # Кофейня Брутто
TABLE_ID = "143fb2eb-6add-44b8-ad11-9884d49d5a47"  # Зал, Стол 3 (в iiko number=2)
PRODUCT_ID = "20badb7f-18a2-4f20-bccf-099ab9d16b6f"  # Печенье с Шоколадной крошкой
PRICE = 120.0


async def main() -> None:
    timeout = aiohttp.ClientTimeout(total=60)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await get_token(session)
        if not token:
            return

        created = await post(
            session,
            "/api/1/order/create",
            {
                "organizationId": ORG_ID,
                "terminalGroupId": TERMINAL_GROUP_ID,
                "order": {
                    "tableIds": [TABLE_ID],
                    "items": [
                        {
                            "type": "Product",
                            "productId": PRODUCT_ID,
                            "price": PRICE,
                            "amount": 1,
                            "comment": "ТЕСТ API",
                        }
                    ],
                },
                "createOrderSettings": {"servicePrint": False, "transportToFrontTimeout": 60},
            },
            token,
        )
        if not created:
            return
        print(json.dumps(created, ensure_ascii=False, indent=2))

        # Заказ доставляется на кассу асинхронно — опрашиваем статус команды
        for _ in range(12):
            await asyncio.sleep(5)
            status = await post(
                session,
                "/api/1/commands/status",
                {"organizationId": ORG_ID, "correlationId": created["correlationId"]},
                token,
            )
            print("статус команды:", status)
            if status and status.get("state") != "InProgress":
                break

        order_id = created["orderInfo"]["id"]
        order = await post(
            session,
            "/api/1/order/by_id",
            {"organizationIds": [ORG_ID], "orderIds": [order_id]},
            token,
        )
        print(json.dumps(order, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
