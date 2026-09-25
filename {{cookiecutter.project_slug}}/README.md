# {{ cookiecutter.project_name }}

An AWS CDK project in Python, deploying {{ cookiecutter.lambda_architecture }} Lambda
functions with a shared dependency layer.

## Features

- **Least-privilege CDK bootstrap.** The CloudFormation execution role deploys under a
  scoped IAM policy you keep in version control, not `AdministratorAccess`. Supports
  per-project qualifiers so several projects can share one account without sharing roles.
- **Reproducible Lambda builds.** Layer dependencies are cross-installed for
  `linux/{{ cookiecutter.lambda_architecture }}` + Python {{ cookiecutter.python_version }},
  so wheels match the runtime instead of the build machine.
- **Task-driven workflow.** One command per job — `task install`, `task build`,
  `task deploy` — with dependency and staleness tracking, so nothing rebuilds needlessly.
- **Structured logging** via AWS Lambda Powertools, in the layer rather than the
  function package.
- **Explicit log group.** The log group is a stack resource, so retention is managed and
  it isn't left orphaned when the stack is deleted.
- **Environment-based config** through a frozen dataclass that fails fast on missing
  required variables.

## Project structure

```
.
├── app.py                          CDK entrypoint: builds config, instantiates the stack
├── cdk.json                        CDK Toolkit config + feature flags + bootstrap qualifier
├── Taskfile.yml                    Every developer and CI workflow
├── .env.example                    Template for .env (which is gitignored)
│
├── infrastructure/                 The CDK app — what gets deployed
│   ├── config.py                   {{ cookiecutter.class_prefix }}Config, loaded from the environment
│   └── {{ cookiecutter.module_name }}_stack.py
│
├── src/                            Lambda source — what runs
│   ├── lambdas/
│   │   └── index.py                Handler (handler="index.handler")
│   ├── layer/
│   │   └── requirements.txt        Dependencies bundled into the layer
│   └── services/                   Shared business logic, imported as a package
│
├── tests/                          (empty — add your tests here)
│
├── scripts/
│   ├── cdk-bootstrap.sh            One-time account bootstrap with a scoped policy
│   └── update-cf-execution-policy.sh   Publish a new version of that policy
│
├── iam/
│   └── cdkCFExecutionPolicy.json   The CloudFormation execution policy, version-controlled
│
└── assets/                         Build output (gitignored, created by `task build`)
    ├── layer/python/               Cross-installed layer dependencies
    └── {{ cookiecutter.lambda_name }}.zip
```

### What the stack creates

| Resource | Notes |
| --- | --- |
| `LayerVersion` | From `assets/layer`, pinned to Python {{ cookiecutter.python_version }} / {{ cookiecutter.lambda_architecture }}. Destroyed with the stack. |
| `Function` | 128 MB, 10 s timeout, `index.handler`, `LOG_LEVEL` passed from config. Versions are retained so a rollback has something to roll back to. |
| `LogGroup` | Two-week retention, **retained** on stack deletion so logs survive a teardown. |
| `CfnOutput` | The generated function name, so integration tests and other stacks can find it. |

Resources are prefixed `{stage}-`, where stage comes from `AWS_STAGE`.

## Prerequisites

| Tool | Why |
| --- | --- |
| Python {{ cookiecutter.python_version }} | Matches `.python-version` and the Lambda runtime |
| [Task](https://taskfile.dev) | Runs everything in `Taskfile.yml` |
| Node.js + `npm i -g aws-cdk` | The CDK CLI is not a Python package |
| AWS CLI v2 | Credentials, and used by the bootstrap scripts |
| `zip` | Packages the function |

## Getting started

**1. Configure the environment.** Generation already copied `.env.example` to `.env`.
Fill in `AWS_ACCOUNT_ID` and `AWS_REGION` — `config.py` raises on either being absent.
[Credentials](#credentials).

**2. Install dependencies.**

```bash
task install
```

Creates `.venv` and installs both runtime and dev requirements. Every other task depends
on this, so you rarely run it directly.

**3. Bootstrap the account** (once per account/region, with administrator credentials):

```bash
./scripts/cdk-bootstrap.sh -q {{ cookiecutter.bootstrap_qualifier }} -n {{ cookiecutter.iam_policy_name }} -P <admin-profile> -r {{ cookiecutter.aws_region }}
```

The `-q {{ cookiecutter.bootstrap_qualifier }}` is not optional — `cdk.json` sets
`@aws-cdk/core:bootstrapQualifier` to `{{ cookiecutter.bootstrap_qualifier }}`, and the
app will look for bootstrap roles under that qualifier. If you change one, change the other.

**4. Build, then deploy.**

```bash
task build     # cross-install the layer, zip the handler
task synth     # emit the CloudFormation template
task diff      # review against what's deployed
task deploy
```

`task synth` depends on `build`, and `task deploy` on `synth`, so `task deploy` alone is
enough once you trust the diff.

## Commands

| Command | Description |
| --- | --- |
| `task install` | Create `.venv`, install runtime + dev dependencies |
| `task lint` | `ruff check` and `ruff format --check` |
| `task lint:fix` | Auto-fix and format |
| `task build` | Build the layer and the function zip |
| `task build:layer` | Cross-install layer dependencies only |
| `task build:lambda` | Zip handler + services only |
| `task synth` | Synthesize the CloudFormation template |
| `task diff` | Diff against the deployed stack |
| `task deploy` | Deploy (`--require-approval never`) |
| `task destroy` | Tear down the stack |
| `task cleanup:cdk` | Remove `cdk.out` and `assets` |
| `task cleanup:all` | **Destructive** — also removes `.venv` and `.env` |

Run `task --list-all` for the full set.

## How the build works

Two details here are easy to get wrong, which is why they're automated.

**The layer is cross-installed.** `task build:layer` runs pip with
`--platform {{ cookiecutter.__pip_platform }} --python-version {{ cookiecutter.python_version }} --implementation cp --only-binary=:all:`,
installing into `assets/layer/python` — the path Lambda adds to `sys.path` for a layer.
Without those flags pip resolves wheels for *your* machine; a macOS or x86 wheel installs
perfectly well locally and then fails to import inside Lambda. The target platform lives
in `LAMBDA_PLATFORM` / `LAMBDA_PYTHON_VERSION` at the top of `Taskfile.yml` and must stay
in step with the runtime and architecture declared in the stack.

**The zip mirrors two different layouts.** `src/lambdas/` is flattened to the archive
root, so `handler="index.handler"` resolves; `src/services/` keeps its directory so it
can be imported as a package. Add a dependency by editing `src/layer/requirements.txt`
and re-running `task build` — Task rebuilds the layer only when that file changes.

## Least-privilege bootstrap

The default `cdk bootstrap` grants the CloudFormation execution role
`AdministratorAccess`, which means anyone who can deploy can do anything. Instead,
`scripts/cdk-bootstrap.sh` publishes `iam/cdkCFExecutionPolicy.json` as a customer-managed
policy named `{{ cookiecutter.iam_policy_name }}` and bootstraps against that, so
deployments are limited to the services you actually use.

To widen the policy later, edit the JSON and run:

```bash
./scripts/update-cf-execution-policy.sh -P <admin-profile>
```

No re-bootstrap is needed — the execution role references the policy by ARN, so a new
default version applies on the next deployment. Only creating the policy from scratch
requires re-bootstrapping.

This is deliberately **not** part of `task deploy` or the CI deploy stage: a principal
that can publish a new version of this policy can rewrite it to `"Action": "*"` and grant
itself an admin role, which is exactly the escalation the scoped policy exists to prevent.
Run it with administrator credentials, by hand.

The policy's own `NotResource` guard excludes `{{ cookiecutter.iam_policy_name }}` and the
`cdk-*` roles, so the execution role cannot rewrite the policy it deploys under. If you
rename the policy, update that ARN in `iam/cdkCFExecutionPolicy.json` too.

## Configuration

`.env` is read by Task (which exports it to every task) and by `infrastructure/config.py`
via `python-dotenv`. It is gitignored.

| Variable | Required | Default | Used for |
| --- | --- | --- | --- |
| `AWS_ACCOUNT_ID` | yes | — | Target account for `cdk.Environment` |
| `AWS_REGION` | yes | — | Target region |
| `AWS_STAGE` | no | `dev` | Resource name prefix (`{stage}-`) |
| `LOG_LEVEL` | no | `INFO` | Passed to the function as an environment variable |

### Credentials

`.env.example` includes `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. Long-lived access
keys in a dotfile are the most common way AWS credentials leak. `.env` is gitignored —
keep it that way.

## CI/CD

`Taskfile.yml` is written to map onto pipeline stages:

| Stage | Commands |
| --- | --- |
| build | `task install`, `task build` |
| test | `task lint`, `task synth` |
| deploy | `task deploy` |

The deployment principal needs no IAM write access — that's reserved for the bootstrap
scripts, which are run by hand.

## Not yet wired up

- **No tests.** `tests/` is empty and there are no test tasks. `pytest` and `syrupy` are
  already in `requirements-dev.txt`; a CloudFormation snapshot test of the synthesized
  stack is the usual first one to add.
- **No CI configuration.** The stage mapping above is a guide, not a pipeline file.
