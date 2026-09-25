#!/usr/bin/env python3
import aws_cdk as cdk

from infrastructure.config import {{ cookiecutter.class_prefix }}Config
from infrastructure.{{ cookiecutter.module_name }}_stack import {{ cookiecutter.class_prefix }}Stack

config = {{ cookiecutter.class_prefix }}Config.from_env()
app = cdk.App()

{{ cookiecutter.class_prefix }}Stack(
    app,
    "{{ cookiecutter.class_prefix }}Stack",
    config=config,
    env=cdk.Environment(account=config.account, region=config.region),
)

app.synth()
