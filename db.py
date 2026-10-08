from pathlib import Path

import aiosqlite

DB_PATH = Path("app.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tables (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    token TEXT NOT NULL UNIQUE,
    iiko_table_id TEXT UNIQUE
);
CREATE TABLE IF NOT EXISTS menu_items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    price REAL NOT NULL,
    category TEXT NOT NULL,
    is_available INTEGER NOT NULL DEFAULT 1,
    sort INTEGER NOT NULL DEFAULT 0,
    iiko_product_id TEXT UNIQUE,
    sku TEXT,
    description TEXT NOT NULL DEFAULT '',
    image_url TEXT,
    modifiers TEXT NOT NULL DEFAULT '[]'  -- JSON: группы модификаторов из iiko
);
CREATE TABLE IF NOT EXISTS orders (
    id INTEGER PRIMARY KEY,
    table_id INTEGER NOT NULL REFERENCES tables(id),
    status TEXT NOT NULL DEFAULT 'new',
    guest_name TEXT NOT NULL,
    comment TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    iiko_status TEXT NOT NULL DEFAULT 'off',
    iiko_order_id TEXT,
    iiko_number INTEGER,  -- номер заказа в iikoFront, по нему кассир находит заказ
    iiko_error TEXT
);
CREATE TABLE IF NOT EXISTS order_items (
    order_id INTEGER NOT NULL REFERENCES orders(id),
    menu_item_id INTEGER NOT NULL REFERENCES menu_items(id),
    qty INTEGER NOT NULL,
    price_snapshot REAL NOT NULL,
    name_snapshot TEXT NOT NULL,
    modifiers TEXT NOT NULL DEFAULT '[]'  -- JSON: выбранные модификаторы со снимком цен
);
-- id организации и терминальной группы iiko, их пишет import_menu.py
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

# Колонки, добавленные после первого запуска: CREATE TABLE IF NOT EXISTS их в старую базу не добавит
MIGRATIONS = {
    "menu_items": {
        "sku": "TEXT",
        "description": "TEXT NOT NULL DEFAULT ''",
        "image_url": "TEXT",
        "modifiers": "TEXT NOT NULL DEFAULT '[]'",
    },
    "orders": {
        "iiko_number": "INTEGER",
    },
    "order_items": {
        "modifiers": "TEXT NOT NULL DEFAULT '[]'",
    },
}


async def migrate(conn: aiosqlite.Connection) -> None:
    for table, columns in MIGRATIONS.items():
        async with conn.execute(f"PRAGMA table_info({table})") as cur:
            existing = {row["name"] async for row in cur}
        for name, ddl in columns.items():
            if name not in existing:
                await conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {ddl}")


async def connect() -> aiosqlite.Connection:
    conn = await aiosqlite.connect(DB_PATH)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA foreign_keys = ON")
    await conn.execute("PRAGMA journal_mode = WAL")
    await conn.executescript(SCHEMA)
    await migrate(conn)
    await conn.commit()
    return conn


async def get_meta(conn: aiosqlite.Connection) -> dict[str, str]:
    async with conn.execute("SELECT key, value FROM meta") as cur:
        return {row["key"]: row["value"] async for row in cur}
