"""QR-коды столов в qr/: PNG на каждый стол и qr/index.html — лист для печати."""

import asyncio
import html
from pathlib import Path

import qrcode

import db
from config import setting

OUT = Path("qr")


async def main() -> None:
    conn = await db.connect()
    async with conn.execute("SELECT id, name, token FROM tables ORDER BY id") as cur:
        tables = [dict(r) async for r in cur]
    await conn.close()

    OUT.mkdir(exist_ok=True)
    cards = []
    for t in tables:
        url = f"{setting.BASE_URL}/t/{t['token']}"
        filename = f"table-{t['id']}.png"
        qrcode.make(url, box_size=12, border=2).save(OUT / filename)
        cards.append(
            f'<div class="card"><img src="{filename}"><div class="name">{html.escape(t["name"])}</div>'
            f'<div class="hint">Сканируйте, чтобы заказать</div></div>'
        )

    (OUT / "index.html").write_text(
        """<!doctype html><meta charset="utf-8"><title>QR столов</title>
<style>
  body { font-family: -apple-system, sans-serif; margin: 0; }
  .grid { display: grid; grid-template-columns: repeat(3, 1fr); }
  .card { text-align: center; padding: 20px; border: 1px dashed #ccc; break-inside: avoid; }
  img { width: 100%; max-width: 220px; }
  .name { font-size: 28px; font-weight: 800; }
  .hint { color: #777; }
</style>
<div class="grid">"""
        + "".join(cards)
        + "</div>"
    )
    print(f"{len(tables)} QR-кодов в {OUT}/, лист для печати: {OUT / 'index.html'}")
    print(f"Ссылки ведут на {setting.BASE_URL} — перед печатью поставьте боевой BASE_URL в .env")


if __name__ == "__main__":
    asyncio.run(main())
