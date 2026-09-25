from pathlib import Path

from aws_cdk import (
    CfnOutput,
    Duration,
    RemovalPolicy,
    Stack,
    aws_lambda,
    aws_logs,
)
from constructs import Construct

from infrastructure.config import {{ cookiecutter.class_prefix }}Config

# Assets are resolved from this file, not the cwd: cdk.json runs ".venv/bin/python app.py",
# so the working directory is not guaranteed to be the repository root.
ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"


class {{ cookiecutter.class_prefix }}Stack(Stack):
    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        config: {{ cookiecutter.class_prefix }}Config,
        **kwargs,
    ) -> None:
        super().__init__(scope, construct_id, **kwargs)

        name_prefix = f"{config.stage}-"

        layer = aws_lambda.LayerVersion(
            self,
            name_prefix + "{{ cookiecutter.__lambda_construct }}LambdaLayer",
            code=aws_lambda.AssetCode(str(ASSETS_DIR / "layer")),
            compatible_runtimes=[aws_lambda.Runtime.{{ cookiecutter.__cdk_runtime }}],
            compatible_architectures=[aws_lambda.Architecture.{{ cookiecutter.__cdk_architecture }}],
            removal_policy=RemovalPolicy.DESTROY,
        )

        log_group = aws_logs.LogGroup(
            self,
            name_prefix + "{{ cookiecutter.__lambda_construct }}LambdaLogGroup",
            retention=aws_logs.RetentionDays.TWO_WEEKS,
            removal_policy=RemovalPolicy.RETAIN,
        )

        {{ cookiecutter.lambda_name }}_lambda = aws_lambda.Function(
            self,
            name_prefix + "{{ cookiecutter.__lambda_construct }}Lambda",
            runtime=aws_lambda.Runtime.{{ cookiecutter.__cdk_runtime }},
            architecture=aws_lambda.Architecture.{{ cookiecutter.__cdk_architecture }},
            code=aws_lambda.AssetCode(str(ASSETS_DIR / "{{ cookiecutter.lambda_name }}.zip")),
            handler="index.handler",
            memory_size=128,
            timeout=Duration.seconds(10),
            layers=[layer],
            log_group=log_group,
            environment={"LOG_LEVEL": config.log_level},
            # RETAIN: a rollback points the alias back at the previous version, so that
            # version has to survive the stack update that superseded it.
            current_version_options=aws_lambda.VersionOptions(
                removal_policy=RemovalPolicy.RETAIN
            ),
        )

        # The function has no explicit physical name, so CloudFormation generates one.
        # Publishing it as an output is how integration tests and other stacks find it
        # without depending on that generated name.
        CfnOutput(
            self,
            "{{ cookiecutter.__lambda_construct }}FunctionName",
            value={{ cookiecutter.lambda_name }}_lambda.function_name,
            description="Name of the deployed {{ cookiecutter.__lambda_construct }} Lambda function",
        )
