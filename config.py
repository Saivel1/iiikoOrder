from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env")

    TOKEN: str
    IIKO_APP_ID: str | None = None
    IIKO_CLIENT_SECRET: str | None = None

    BAR_KEY: str
    BASE_URL: str = "http://localhost:8000"  # адрес, который зашивается в QR
    IIKO_SEND_ORDERS: bool = False  # отправлять заказы гостей на кассу iiko



setting = Settings() #type: ignore
