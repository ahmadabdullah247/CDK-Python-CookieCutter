import json
import os
from typing import Any

from aws_lambda_powertools import Logger

logger = Logger(
    service=os.getenv("SERVICE_NAME", "{{ cookiecutter.__service_name }}"),
    level=os.getenv("LOG_LEVEL", "INFO"),
)


def handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    logger.info("Received event")

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps("Hello World"),
    }
