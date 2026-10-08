from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env")

    TOKEN: str
    IIKO_APP_ID: str | None = None
    IIKO_CLIENT_SECRET: str | None = None

    BAR_KEY: str
    MASTER_PASSWORD: str | None = None  # нужен, чтобы распечатать QR-коды со страницы бариста
    BASE_URL: str = "http://localhost:8000"  # адрес, который зашивается в QR
    IIKO_SEND_ORDERS: bool = False  # отправлять заказы гостей на кассу iiko
    MENU_SYNC_MINUTES: int = 15  # как часто подтягивать меню, фото и цены из iiko; 0 — не подтягивать
    DB_PATH: str = "app.db"



setting = Settings() #type: ignore
