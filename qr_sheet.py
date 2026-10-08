"""Лист QR-кодов столов для печати: одна HTML-страница, картинки встроены, работает без сервера."""

import base64
import html
import io

import qrcode


def qr_png(url: str) -> str:
    buf = io.BytesIO()
    qrcode.make(url, box_size=12, border=2).save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def render_sheet(tables: list[dict], base_url: str) -> str:
    """tables: [{"name", "token"}]"""
    base_url = base_url.rstrip("/")
    cards = "".join(
        f'<div class="card"><img src="{qr_png(f"{base_url}/t/{t["token"]}")}" alt="">'
        f'<div class="name">{html.escape(t["name"])}</div>'
        f'<div class="hint">Наведите камеру, чтобы сделать заказ</div></div>'
        for t in tables
    )
    return f"""<!doctype html>
<html lang="ru">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>QR-коды столов — Брутто</title>
<style>
  body {{ font-family: Montserrat, -apple-system, sans-serif; margin: 0; color: #212121; }}
  .bar {{ display: flex; gap: 12px; align-items: center; padding: 16px; border-bottom: 1px solid #e2e2e2; flex-wrap: wrap; }}
  .bar button {{ padding: 10px 18px; border: 0; border-radius: 10px; background: #ec1c24; color: #fff; font: 700 15px/1 inherit; cursor: pointer; }}
  .bar span {{ color: #7a7a7a; font-size: 14px; }}
  .grid {{ display: grid; grid-template-columns: repeat(3, 1fr); }}
  .card {{ text-align: center; padding: 18px; border: 1px dashed #ccc; break-inside: avoid; }}
  img {{ width: 100%; max-width: 210px; }}
  .name {{ font-size: 24px; font-weight: 800; margin-top: 4px; }}
  .hint {{ color: #7a7a7a; font-size: 13px; }}
  @media print {{ .bar {{ display: none; }} }}
  @media (max-width: 600px) {{ .grid {{ grid-template-columns: repeat(2, 1fr); }} }}
</style>
<div class="bar">
  <button onclick="print()">Печать</button>
  <span>{len(tables)} столов · ссылки ведут на {html.escape(base_url)}</span>
</div>
<div class="grid">{cards}</div>
</html>
"""
