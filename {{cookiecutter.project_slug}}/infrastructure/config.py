import os
from dataclasses import dataclass

from dotenv import load_dotenv

# Import-time side effect: .env must be loaded before any from_env() call,
# including when this module is imported only for the type.
load_dotenv()


@dataclass(frozen=True)
class {{ cookiecutter.class_prefix }}Config:
    stage: str
    log_level: str
    account: str
    region: str

    @classmethod
    def from_env(cls) -> "{{ cookiecutter.class_prefix }}Config":
        return cls(
            stage=os.environ.get("AWS_STAGE", "dev"),
            log_level=os.environ.get("LOG_LEVEL", "INFO"),
            account=os.environ["AWS_ACCOUNT_ID"],
            region=os.environ["AWS_REGION"],
        )
