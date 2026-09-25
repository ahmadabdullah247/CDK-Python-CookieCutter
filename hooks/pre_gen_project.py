"""Validate the answers before any files are written.

Each check here guards a value that AWS or Python rejects later, at a point where the
error is much harder to trace back to the prompt that caused it.
"""

import keyword
import re
import sys

MODULE_NAME = "{{ cookiecutter.module_name }}"
LAMBDA_NAME = "{{ cookiecutter.lambda_name }}"
QUALIFIER = "{{ cookiecutter.bootstrap_qualifier }}"
POLICY_NAME = "{{ cookiecutter.iam_policy_name }}"
CLASS_PREFIX = "{{ cookiecutter.class_prefix }}"
ACCOUNT_ID = "{{ cookiecutter.aws_account_id }}"
PYTHON_VERSION = "{{ cookiecutter.python_version }}"

errors = []

if not MODULE_NAME.isidentifier() or keyword.iskeyword(MODULE_NAME):
    errors.append(
        f"module_name {MODULE_NAME!r} is not a valid Python identifier. "
        "Pick a project_name that yields one (letters, digits, underscores; "
        "not starting with a digit)."
    )

if not LAMBDA_NAME.isidentifier() or keyword.iskeyword(LAMBDA_NAME):
    errors.append(
        f"lambda_name {LAMBDA_NAME!r} is not a valid Python identifier; it is used "
        "as a variable name in the stack."
    )

if not CLASS_PREFIX.isidentifier():
    errors.append(
        f"class_prefix {CLASS_PREFIX!r} is not a valid Python identifier; it names "
        "the stack and config classes."
    )

# AWS hard-limits the qualifier to 10 alphanumeric characters. Exceeding it fails at
# `cdk bootstrap`, long after generation, with an opaque CloudFormation error.
if not re.fullmatch(r"[a-z0-9]{1,10}", QUALIFIER):
    errors.append(
        f"bootstrap_qualifier {QUALIFIER!r} must be 1-10 lowercase alphanumeric "
        "characters (an AWS constraint)."
    )

# https://docs.aws.amazon.com/IAM/latest/APIReference/API_CreatePolicy.html
if not re.fullmatch(r"[\w+=,.@-]{1,128}", POLICY_NAME):
    errors.append(
        f"iam_policy_name {POLICY_NAME!r} must be 1-128 characters from [\\w+=,.@-]."
    )

if not re.fullmatch(r"\d{12}", ACCOUNT_ID):
    errors.append(
        f"aws_account_id {ACCOUNT_ID!r} must be exactly 12 digits. "
        "This only seeds .env.example, but a wrong value is confusing later."
    )

if not re.fullmatch(r"3\.\d{1,2}", PYTHON_VERSION):
    errors.append(
        f"python_version {PYTHON_VERSION!r} must look like '3.13'. It is used to "
        "build the CDK runtime enum (PYTHON_3_13) and the pip --python-version flag."
    )

if errors:
    print("\nCannot generate the project:\n", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    print(file=sys.stderr)
    sys.exit(1)
