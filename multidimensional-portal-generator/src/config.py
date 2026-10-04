import os
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["sandbox", "production", "testing"]
environment = os.getenv("ENVIRONMENT", "sandbox")


class Settings(BaseSettings):
    ENVIRONMENT: Environment = "sandbox"
    DEBUG: bool = True
    SECRET_KEY: str = "development-only-change-me"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    DATABASE_URL: str = "sqlite+aiosqlite:///./portal.db"
    PORT: int = 8000

    model_config = SettingsConfigDict(
        env_file=f".env.{environment}",
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
