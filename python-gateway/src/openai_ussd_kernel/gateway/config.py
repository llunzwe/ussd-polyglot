"""Gateway configuration settings."""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    orchestrator_addr: str = "localhost:9090"
    gateway_port: int = 8000
    redis_url: str = "redis://localhost:6379/0"
    default_language: str = "en"
    rate_limit_rps: float = 10.0  # requests per minute per phone number

    model_config = {"env_prefix": "", "case_sensitive": False}


settings = Settings()
