"""Фото блюд из iiko приходят оригиналами (сотни КБ). Скачиваем, уменьшаем и сохраняем в WebP —
меню на мобильном интернете грузится в разы быстрее. Отдаются по /photos/<файл>."""

import asyncio
import hashlib
import io
import logging
from pathlib import Path

import aiohttp
from PIL import Image, ImageOps

from config import setting

PHOTOS_DIR = Path(setting.PHOTOS_DIR)
URL_PREFIX = "/photos/"
MAX_SIDE = 640  # карточка на телефоне ~200 px, окно блюда ~560 px; на телефоне от 800 px не отличить
QUALITY = 72
MAX_DOWNLOAD = 20 * 1024 * 1024
PARALLEL = 5

log = logging.getLogger("uvicorn.error")


def file_name(url: str) -> str:
    # Новое фото в iiko — новая ссылка, значит и новый файл; старый удалится при следующей синхронизации.
    # Параметры сжатия тоже в имени: поменяли их — фото пересожмутся сами
    return hashlib.sha1(f"{url}|{MAX_SIDE}|{QUALITY}".encode()).hexdigest()[:20] + ".webp"


def compress(raw: bytes) -> bytes:
    with Image.open(io.BytesIO(raw)) as img:
        img = ImageOps.exif_transpose(img)  # фото с телефона бывают повёрнуты через EXIF
        img.thumbnail((MAX_SIDE, MAX_SIDE), Image.Resampling.LANCZOS)
        if img.mode not in ("RGB", "RGBA"):
            img = img.convert("RGBA" if "transparency" in img.info else "RGB")
        out = io.BytesIO()
        img.save(out, "WEBP", quality=QUALITY, method=6)
        return out.getvalue()


async def fetch_and_compress(session: aiohttp.ClientSession, url: str, path: Path) -> tuple[int, int]:
    async with session.get(url) as resp:
        resp.raise_for_status()
        # content.read(n) отдаёт столько, сколько уже пришло, а не весь файл — читаем кусками до конца
        raw = bytearray()
        async for chunk in resp.content.iter_chunked(64 * 1024):
            raw += chunk
            if len(raw) > MAX_DOWNLOAD:
                raise ValueError("файл больше 20 МБ")
    raw = bytes(raw)
    webp = await asyncio.to_thread(compress, raw)
    tmp = path.with_suffix(".tmp")
    tmp.write_bytes(webp)
    tmp.replace(path)  # чтобы гость никогда не получил недописанный файл
    return len(raw), len(webp)


async def localize(urls: set[str]) -> dict[str, str]:
    """Сжимает фото и возвращает {ссылка iiko: /photos/<файл>}. Уже сжатые не качает заново.
    Если фото не удалось обработать, его в ответе нет — останется ссылка iiko."""
    PHOTOS_DIR.mkdir(parents=True, exist_ok=True)
    result: dict[str, str] = {}
    todo = []
    for url in urls:
        path = PHOTOS_DIR / file_name(url)
        if path.exists():
            result[url] = URL_PREFIX + path.name
        else:
            todo.append((url, path))

    if todo:
        sem = asyncio.Semaphore(PARALLEL)
        before = after = 0

        async def one(session: aiohttp.ClientSession, url: str, path: Path) -> None:
            nonlocal before, after
            async with sem:
                try:
                    raw_size, webp_size = await fetch_and_compress(session, url, path)
                except Exception as e:
                    log.warning("Фото не сжато, остаётся оригинал iiko: %s (%s)", url, e)
                    return
            before += raw_size
            after += webp_size
            result[url] = URL_PREFIX + path.name

        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=60)) as session:
            await asyncio.gather(*(one(session, url, path) for url, path in todo))
        if after:
            log.info("Сжато фото: %d, %d КБ → %d КБ", len(todo), before // 1024, after // 1024)

    # Фото, которых больше нет в меню iiko, удаляем
    keep = {u.removeprefix(URL_PREFIX) for u in result.values()}
    for f in PHOTOS_DIR.glob("*.webp"):
        if f.name not in keep:
            f.unlink(missing_ok=True)
    return result
