"""Tests for the cookiecutter template itself.

These assert the *generated* project is coherent — that identifiers were substituted
everywhere, that no Jinja syntax leaked through, and that validation rejects values AWS
would reject later. Baking is cheap; the expensive end-to-end check (task build && task
synth) is marked slow and skipped by default.
"""

import re
import subprocess

import pytest


def test_bakes_with_defaults(cookies):
    result = cookies.bake()
    assert result.exception is None
    assert result.exit_code == 0
    assert result.project_path.is_dir()


def test_names_are_substituted_from_project_name(cookies):
    result = cookies.bake(extra_context={"project_name": "Geo Locator"})
    project = result.project_path

    assert project.name == "geo-locator"
    assert (project / "infrastructure" / "geo_locator_stack.py").is_file()

    stack = (project / "infrastructure" / "geo_locator_stack.py").read_text()
    assert "class GeoLocatorStack(Stack):" in stack
    assert "GeoLocatorConfig" in stack

    app = (project / "app.py").read_text()
    assert "from infrastructure.geo_locator_stack import GeoLocatorStack" in app


def test_lambda_name_drives_zip_construct_and_service(cookies):
    result = cookies.bake(extra_context={"lambda_name": "geo_lookup"})
    project = result.project_path

    stack = (project / "infrastructure").glob("*_stack.py").__next__().read_text()
    assert '"geo_lookup.zip"' in stack
    assert "GeoLookupLambda" in stack
    assert "geo_lookup_lambda = aws_lambda.Function(" in stack

    # The powertools service name derives from the same value, so it can't drift.
    assert '"GeoLookup"' in (project / "src" / "lambdas" / "index.py").read_text()
    assert "ZIP_NAME: geo_lookup.zip" in (project / "Taskfile.yml").read_text()


@pytest.mark.parametrize(
    ("architecture", "pip_platform", "cdk_architecture"),
    [
        ("arm64", "manylinux2014_aarch64", "ARM_64"),
        ("x86_64", "manylinux2014_x86_64", "X86_64"),
    ],
)
def test_architecture_is_consistent_between_layer_and_runtime(
    cookies, architecture, pip_platform, cdk_architecture
):
    """A mismatch here installs fine locally and fails at import inside Lambda."""
    result = cookies.bake(extra_context={"lambda_architecture": architecture})
    project = result.project_path

    assert f"LAMBDA_PLATFORM: {pip_platform}" in (project / "Taskfile.yml").read_text()
    stack = (project / "infrastructure").glob("*_stack.py").__next__().read_text()
    assert stack.count(f"aws_lambda.Architecture.{cdk_architecture}") == 2


def test_python_version_drives_the_cdk_runtime_enum(cookies):
    result = cookies.bake(extra_context={"python_version": "3.13"})
    project = result.project_path

    assert (project / ".python-version").read_text().strip() == "3.13"
    stack = (project / "infrastructure").glob("*_stack.py").__next__().read_text()
    assert stack.count("aws_lambda.Runtime.PYTHON_3_13") == 2
    assert 'LAMBDA_PYTHON_VERSION: "3.13"' in (project / "Taskfile.yml").read_text()


def test_task_go_templating_survives_generation(cookies):
    """Cookiecutter must not eat Task's own {{.VAR}} syntax."""
    taskfile = (cookies.bake().project_path / "Taskfile.yml").read_text()

    assert "{{.PYTHON}} -m pip install" in taskfile
    assert "mkdir -p {{.PACKAGES_DESTINATION}}" in taskfile
    assert "--platform {{.LAMBDA_PLATFORM}}" in taskfile
    assert "assets/{{.ZIP_NAME}}" in taskfile
    # The fences themselves must be consumed.
    assert "{% raw %}" not in taskfile


def test_bash_parameter_expansion_survives_generation(cookies):
    """'${#' opens a Jinja comment; without a fence this line vanishes silently."""
    script = (
        cookies.bake().project_path / "scripts" / "update-cf-execution-policy.sh"
    ).read_text()

    assert '"${#VERSION_IDS[@]}" -ge "$MAX_NON_DEFAULT_VERSIONS"' in script
    assert "{% raw %}" not in script


def test_no_unrendered_jinja_anywhere(cookies):
    """Catch leftover template syntax, not the word 'cookiecutter' in prose."""
    project = cookies.bake().project_path
    # '{{.VAR}}' is Task's syntax and legitimate, so match only a cookiecutter
    # reference or a Jinja statement/comment delimiter. '${#' is bash parameter
    # expansion, not a Jinja comment, so exclude it via the lookbehind.
    leftover = re.compile(r"\{\{\s*cookiecutter\.|\{%|(?<!\$)\{#")
    offenders = [
        path.relative_to(project)
        for path in project.rglob("*")
        # .git exists because the post-gen hook inits a repo; its blobs are copies.
        if path.is_file()
        and ".git" not in path.parts
        and leftover.search(path.read_text(errors="ignore"))
    ]
    assert not offenders, f"unrendered template syntax in: {offenders}"


def test_execution_policy_cannot_rewrite_itself(cookies):
    """The NotResource guard must name the policy the scripts actually create."""
    result = cookies.bake(extra_context={"project_name": "Geo Locator"})
    project = result.project_path

    policy = (project / "iam" / "cdkCFExecutionPolicy.json").read_text()
    bootstrap = (project / "scripts" / "cdk-bootstrap.sh").read_text()
    update = (project / "scripts" / "update-cf-execution-policy.sh").read_text()

    expected = "cdkCFExecutionPolicyGeoLocator"
    assert f'"arn:aws:iam::*:policy/{expected}"' in policy
    assert f'POLICY_NAME="{expected}"' in bootstrap
    assert f'POLICY_NAME="{expected}"' in update


def test_scripts_are_executable(cookies):
    project = cookies.bake().project_path
    for script in ("cdk-bootstrap.sh", "update-cf-execution-policy.sh"):
        import os

        assert os.access(project / "scripts" / script, os.X_OK), script


def test_env_is_seeded_but_not_committed(cookies):
    project = cookies.bake().project_path
    assert (project / ".env").is_file(), "Task's dotenv: directive needs .env to exist"
    assert ".env" in (project / ".gitignore").read_text()


@pytest.mark.parametrize(
    ("context", "reason"),
    [
        ({"project_name": "9 Lives"}, "module_name would start with a digit"),
        ({"bootstrap_qualifier": "waytoolongqualifier"}, "AWS caps this at 10 chars"),
        ({"aws_account_id": "123"}, "account IDs are 12 digits"),
        ({"python_version": "3"}, "needs a minor version to build PYTHON_3_x"),
    ],
)
def test_invalid_input_is_rejected(cookies, context, reason):
    result = cookies.bake(extra_context=context)
    assert result.exit_code != 0, f"should have been rejected: {reason}"


@pytest.mark.slow
def test_generated_project_builds_and_synths(cookies):
    """The real check. Requires network, node, and the cdk CLI; opt in with -m slow."""
    project = cookies.bake(extra_context={"project_name": "Geo Locator"}).project_path

    for command in (["task", "install"], ["task", "lint"], ["task", "build"]):
        completed = subprocess.run(command, cwd=project, capture_output=True, text=True)
        assert completed.returncode == 0, f"{command} failed:\n{completed.stderr}"
