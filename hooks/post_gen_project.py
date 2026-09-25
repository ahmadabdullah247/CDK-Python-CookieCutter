"""Finish the generated project: make scripts executable, seed .env, init git.

Deliberately does NOT run `task install` or `cdk bootstrap`. Installing pulls the AWS
CDK library over the network, and bootstrapping mutates an AWS account — neither should
happen as a side effect of scaffolding.
"""

import os
import shutil
import stat
import subprocess

SCRIPTS = ("scripts/cdk-bootstrap.sh", "scripts/update-cf-execution-policy.sh")


def make_executable(path):
    """git does not preserve the mode through cookiecutter's copy."""
    mode = os.stat(path).st_mode
    os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def main():
    for script in SCRIPTS:
        make_executable(script)

    # Task's `dotenv:` directive reads .env at parse time, so every task fails without
    # it. Seed from the example; the developer still has to fill in real values.
    if not os.path.exists(".env"):
        shutil.copyfile(".env.example", ".env")

    if shutil.which("git"):
        try:
            subprocess.run(["git", "init", "--quiet"], check=True)
            subprocess.run(["git", "add", "."], check=True)
        except subprocess.CalledProcessError:
            # A missing repo is not worth failing generation over.
            pass

    print(
        "\n"
        "  Created {{ cookiecutter.project_slug }}\n"
        "\n"
        "  Next:\n"
        "    cd {{ cookiecutter.project_slug }}\n"
        "    $EDITOR .env                 # fill in AWS_ACCOUNT_ID and AWS_REGION\n"
        "    task install\n"
        "    ./scripts/cdk-bootstrap.sh -q {{ cookiecutter.bootstrap_qualifier }} "
        "-n {{ cookiecutter.iam_policy_name }} -P <admin-profile>\n"
        "    task build && task synth\n"
    )


if __name__ == "__main__":
    main()
