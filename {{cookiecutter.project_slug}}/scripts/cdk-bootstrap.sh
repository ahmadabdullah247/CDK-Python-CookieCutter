#!/usr/bin/env bash
#
# cdk-bootstrap.sh
#
# Bootstraps an AWS account/region for CDK deployments following the
# least-privilege principle, instead of the default AdministratorAccess.
#
# Inspired by:
# https://betterdev.blog/cdk-bootstrap-least-deployment-privilege/
#
# What it does:
#   1. Creates (or updates) a custom IAM Policy from a local JSON file.
#      This policy is used as the CloudFormation Execution Policy, so the
#      CDK can only deploy the services you actually use.
#   2. Runs `cdk bootstrap` with that policy instead of AdministratorAccess.
#   3. Optionally uses a project-specific qualifier + toolkit stack name,
#      so multiple projects on one account each get their own scoped roles.
#
# Usage:
#   ./cdk-bootstrap.sh [options]        (run with bash, not sh)
#
# Options:
#   -r REGION       AWS region to bootstrap (default: from AWS CLI config)
#   -p POLICY_FILE  Path to the execution policy JSON (default: ./iam/cdkCFExecutionPolicy.json)
#   -n POLICY_NAME  Name of the IAM policy (default: {{ cookiecutter.iam_policy_name }})
#   -q QUALIFIER    CDK bootstrap qualifier for project isolation (optional).
#                   Implies -s QUALIFIER unless -s is given, so a custom qualifier
#                   never overwrites the account's default CDKToolkit stack.
#   -s STACK_NAME   Suffix for the toolkit stack, named CDKToolkit-<STACK_NAME>
#                   (default: CDKToolkit, or CDKToolkit-<QUALIFIER> when -q is used)
#   -P PROFILE      AWS CLI profile to use (optional)
#   -f              Re-qualify an existing toolkit stack (destructive, see below)
#   -h              Show this help
#
# Examples:
#   # Simple: bootstrap default region with ./iam/cdkCFExecutionPolicy.json
#   ./cdk-bootstrap.sh
#
#   # Second project on the same account, isolated roles + policy + toolkit stack
#   ./cdk-bootstrap.sh -q {{ cookiecutter.bootstrap_qualifier }} -n {{ cookiecutter.iam_policy_name }} -r {{ cookiecutter.aws_region }}
#
set -euo pipefail

# dash/POSIX mode breaks the arrays below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

# Absolute, so the delegated script resolves regardless of the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# The qualifier `cdk bootstrap` uses when none is given; the one the whole account
# shares unless a project opts out via @aws-cdk/core:bootstrapQualifier.
DEFAULT_QUALIFIER="hnb659fds"

POLICY_FILE="./iam/cdkCFExecutionPolicy.json"
POLICY_NAME="{{ cookiecutter.iam_policy_name }}"
QUALIFIER=""
FORCE=""
STACK_NAME=""
REGION=""
PROFILE=""

usage() {
  # sed '$d', not `head -n -1`: negative counts are a GNU extension, so BSD head on
  # macOS fails the whole -h path with "illegal line count".
  sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit 0
}

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

while getopts "r:p:n:q:s:P:fh" opt; do
  case "$opt" in
    r) REGION="$OPTARG" ;;
    p) POLICY_FILE="$OPTARG" ;;
    n) POLICY_NAME="$OPTARG" ;;
    q) QUALIFIER="$OPTARG" ;;
    s) STACK_NAME="$OPTARG" ;;
    P) PROFILE="$OPTARG" ;;
    f) FORCE="1" ;;
    h) usage ;;
    *) die "Unknown option. Use -h for help." ;;
  esac
done

# Avoids empty-array expansion, which breaks under `set -u` on bash < 4.4.
awscli() {
  if [[ -n "$PROFILE" ]]; then
    command aws "$@" --profile "$PROFILE"
  else
    command aws "$@"
  fi
}

# ------------------------------------------------------------------
# Preflight checks
# ------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install it first."
command -v cdk >/dev/null 2>&1 || die "CDK CLI not found. Run: npm install -g aws-cdk"
[[ -f "$POLICY_FILE" ]] || die "Policy file not found: $POLICY_FILE
Create it first (see cdkCFExecutionPolicy.json example) and commit it to your repo."

# Validate the policy file is valid JSON
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$POLICY_FILE" >/dev/null 2>&1 \
    || die "Policy file is not valid JSON: $POLICY_FILE"
fi

# Resolve region
if [[ -z "$REGION" ]]; then
  REGION="$(awscli configure get region 2>/dev/null || true)"
  [[ -n "$REGION" ]] || die "No region set. Pass -r REGION or configure the AWS CLI."
fi

# Resolve account
ACCOUNT_ID="$(awscli sts get-caller-identity --query "Account" --output text)" \
  || die "Could not determine AWS account. Are your credentials configured?"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

log "Account:      $ACCOUNT_ID"
log "Region:       $REGION"
log "Policy file:  $POLICY_FILE"
log "Policy name:  $POLICY_NAME"
[[ -n "$QUALIFIER" ]] && log "Qualifier:    $QUALIFIER"

# ------------------------------------------------------------------
# Resolve the toolkit stack, and refuse to re-qualify an existing one
# ------------------------------------------------------------------
# Resolved before anything is mutated, so a rejected run leaves no half-applied
# IAM policy behind.
#
# A qualifier renames every bootstrap resource: the five IAM roles, the staging
# bucket, the ECR repo and the SSM version parameter. Applied to the default
# CDKToolkit stack it therefore rewrites the account's shared bootstrap in place,
# breaking every already-deployed stack that synthesised against the old qualifier
# (and orphaning the old staging bucket, which is retained on replacement). So a
# custom qualifier always gets its own toolkit stack unless -s says otherwise.
if [[ -n "$QUALIFIER" && -z "$STACK_NAME" && "$QUALIFIER" != "$DEFAULT_QUALIFIER" ]]; then
  STACK_NAME="$QUALIFIER"
  log "No -s given; deriving toolkit stack from -q"
fi

if [[ -n "$STACK_NAME" ]]; then
  TOOLKIT_STACK="CDKToolkit-${STACK_NAME}"
else
  TOOLKIT_STACK="CDKToolkit"
fi
log "Toolkit stack: $TOOLKIT_STACK"

# Second line of defence: deriving the stack name above stops the common slip, but an
# explicit -s pointing at a stack bootstrapped under a different qualifier is just as
# destructive. Changing a live stack's qualifier is never an in-place edit, so refuse
# unless the caller says -f and has a plan for the orphaned staging bucket.
EXISTING_QUALIFIER="$(awscli cloudformation describe-stacks \
  --region "$REGION" --stack-name "$TOOLKIT_STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='Qualifier'].ParameterValue | [0]" \
  --output text 2>/dev/null || true)"

WANTED_QUALIFIER="${QUALIFIER:-$DEFAULT_QUALIFIER}"

if [[ -n "$EXISTING_QUALIFIER" && "$EXISTING_QUALIFIER" != "None" \
      && "$EXISTING_QUALIFIER" != "$WANTED_QUALIFIER" && -z "$FORCE" ]]; then
  die "Stack $TOOLKIT_STACK is bootstrapped with qualifier '$EXISTING_QUALIFIER', but this
run would change it to '$WANTED_QUALIFIER'.

That renames every bootstrap resource, so any stack already deployed with
'$EXISTING_QUALIFIER' can no longer be updated, and the old staging bucket
cdk-${EXISTING_QUALIFIER}-assets-${ACCOUNT_ID}-${REGION} is orphaned rather than deleted.

Use -s to give this qualifier its own toolkit stack, or pass -f if re-qualifying
$TOOLKIT_STACK is really what you want."
fi

# ------------------------------------------------------------------
# Execution policy (delegated)
# ------------------------------------------------------------------
# Delegated, so bootstrapping and a later policy-only change run the same code. Both need
# administrator credentials, which is why neither lives in the deploy pipeline.
POLICY_ARGS=(-p "$POLICY_FILE" -n "$POLICY_NAME")
if [[ -n "$PROFILE" ]]; then
  POLICY_ARGS+=(-P "$PROFILE")
fi

"$SCRIPT_DIR/update-cf-execution-policy.sh" "${POLICY_ARGS[@]}"

# ------------------------------------------------------------------
# Bootstrap the CDK with the custom execution policy
# ------------------------------------------------------------------
BOOTSTRAP_ARGS=(
  "aws://${ACCOUNT_ID}/${REGION}"
  --cloudformation-execution-policies "$POLICY_ARN"
)

if [[ -n "$QUALIFIER" ]]; then
  BOOTSTRAP_ARGS+=(--qualifier "$QUALIFIER")
fi

if [[ -n "$STACK_NAME" ]]; then
  BOOTSTRAP_ARGS+=(--toolkit-stack-name "CDKToolkit-${STACK_NAME}")
fi

if [[ -n "$PROFILE" ]]; then
  BOOTSTRAP_ARGS+=(--profile "$PROFILE")
fi

log "Running: cdk bootstrap ${BOOTSTRAP_ARGS[*]}"
# Run from a temp dir: bootstrap doesn't need the app, and running it inside
# a CDK project would trigger app synthesis (which can fail for unrelated
# reasons, e.g. missing build artifacts like Lambda layer assets).
BOOTSTRAP_TMP="$(mktemp -d)"
trap 'rm -rf "$BOOTSTRAP_TMP"' EXIT
(cd "$BOOTSTRAP_TMP" && cdk bootstrap "${BOOTSTRAP_ARGS[@]}")

log "Done. CDK is bootstrapped with least-privilege execution policy."

# ------------------------------------------------------------------
# Remind about cdk.json when a qualifier is used
# ------------------------------------------------------------------
if [[ -n "$QUALIFIER" ]]; then
  cat <<EOF

NOTE: Since you used a custom qualifier, add it to your project's cdk.json
so the app uses the right bootstrap roles:

  {
    "app": "...",
    "context": {
      "@aws-cdk/core:bootstrapQualifier": "$QUALIFIER"
    }
  }
EOF
fi