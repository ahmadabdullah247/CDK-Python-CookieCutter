# cdk-python-cookiecutter

A [cookiecutter](https://cookiecutter.readthedocs.io) template for AWS CDK projects in
Python: an ARM64 or x86_64 Lambda with a cross-installed dependency layer, a Task-driven
workflow, and a least-privilege CDK bootstrap instead of `AdministratorAccess`.

## Usage

```bash
pip install cookiecutter
cookiecutter gh:your-org/cdk-python-cookiecutter
# or, locally:
cookiecutter /path/to/cdk-python-cookiecutter
```

## Prompts

| Variable | Default | Notes |
| --- | --- | --- |
| `project_name` | `CDK Python Service` | Everything else derives from this |
| `project_slug` | derived | Directory name, kebab-case |
| `module_name` | derived | snake_case; names the stack module. Must be a valid Python identifier |
| `class_prefix` | derived | PascalCase; names `<prefix>Stack` and `<prefix>Config` |
| `lambda_name` | `hello_world` | snake_case; names the zip, the stack variable, and (PascalCased) the constructs |
| `aws_region` | `eu-central-1` | Seeds `.env.example` and the policy's region condition |
| `aws_account_id` | `123456789012` | Seeds `.env.example`; must be 12 digits |
| `bootstrap_qualifier` | derived | **Max 10 alphanumeric chars** — an AWS constraint |
| `iam_policy_name` | derived | The CloudFormation execution policy name |
| `python_version` | `3.14` | Drives `.python-version`, the CDK runtime enum, and pip's `--python-version` |
| `lambda_architecture` | `arm64` / `x86_64` | Drives the CDK architecture and pip's `--platform` |

Values prefixed `__` in `cookiecutter.json` are computed, not prompted: `__cdk_runtime`
turns `3.14` into `PYTHON_3_14`, and `__pip_platform` / `__cdk_architecture` turn the
architecture choice into `manylinux2014_aarch64` and `ARM_64`. This is what keeps the
layer's wheels, the runtime, and the architecture from drifting apart — the single most
common way these projects break, because a mismatch installs cleanly and only fails at
import time inside Lambda.

## Maintaining the template

Two files contain syntax that collides with Jinja2 and must stay fenced:

- **`Taskfile.yml`** uses Go templating (`{{ "{{" }}.PYTHON{{ "}}" }}`). Everything below
  the `vars:` block is inside `{% raw %}` / `{% endraw %}`. Put new project-specific
  values in `vars:` and reference them as Task variables below the fence — do not add
  Jinja inside the raw block.
- **`scripts/update-cf-execution-policy.sh`** contains `${#VERSION_IDS[@]}`. The `{#`
  opens a **Jinja comment**, which swallows content silently rather than erroring, so
  that line is individually fenced.

Before committing a change, run the tests — they bake the template and assert the result
is a working project, not just that files exist.

```bash
python3 -m venv .venv && ./.venv/bin/pip install -r requirements-dev.txt
./.venv/bin/pytest -v
```
