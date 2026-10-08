"""QR-коды столов в qr/index.html — лист для печати. То же самое печатается со страницы бариста
по мастер-паролю, этот скрипт — запасной вариант."""

import asyncio
from pathlib import Path

import db
from config import setting
from qr_sheet import render_sheet

OUT = Path("qr")


async def main() -> None:
    conn = await db.connect()
    async with conn.execute("SELECT name, token FROM tables ORDER BY id") as cur:
        tables = [dict(r) async for r in cur]
    await conn.close()

    OUT.mkdir(exist_ok=True)
    (OUT / "index.html").write_text(render_sheet(tables, setting.BASE_URL))
    print(f"{len(tables)} QR-кодов, лист для печати: {OUT / 'index.html'}")
    print(f"Ссылки ведут на {setting.BASE_URL} — перед печатью поставьте боевой BASE_URL в .env")


if __name__ == "__main__":
    asyncio.run(main())
