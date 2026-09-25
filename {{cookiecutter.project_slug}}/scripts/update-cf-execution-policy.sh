#!/usr/bin/env bash
#
# update-cf-execution-policy.sh
#
# Creates, or publishes a new default version of, the IAM policy that the CDK's
# CloudFormation execution role deploys under.
#
# Run this with administrator credentials. It is deliberately not part of `task deploy`
# or the GitLab deploy stage: a principal that can publish a new default version of this
# policy can rewrite it to `"Action": "*"` and then deploy itself an admin role, which is
# the escalation the least-privilege bootstrap exists to prevent. AWS's guidance is to
# "use administrative credentials only to bootstrap and to provision the initial
# pipeline" and to deploy through the pipeline afterwards.
# https://docs.aws.amazon.com/cdk/v2/guide/cdk-pipeline.html
#
# Re-bootstrapping is not required when the policy already exists: the execution role
# references it by ARN, so a new default version applies on the next deployment. Creating
# it fresh DOES require a re-bootstrap - nothing attaches a new policy to the execution
# role except the toolkit stack's CloudFormationExecutionPolicies parameter.
#
# Usage:
#   ./update-cf-execution-policy.sh [options]      (run with bash, not sh)
#
# Options:
#   -p POLICY_FILE  Path to the execution policy JSON (default: ./iam/cdkCFExecutionPolicy.json)
#   -n POLICY_NAME  Name of the IAM policy (default: {{ cookiecutter.iam_policy_name }})
#   -P PROFILE      AWS CLI profile to use (optional)
#   -h              Show this help
#
# Examples:
#   # Publish the repo's policy to the account the profile points at
#   ./update-cf-execution-policy.sh -P AWSAdministratorAccess-<account-id>
#
#   # A second project's policy on the same account
#   ./update-cf-execution-policy.sh -n cdkCFExecutionPolicyProj2
#
set -euo pipefail

# dash/POSIX mode breaks the arrays below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

POLICY_FILE="./iam/cdkCFExecutionPolicy.json"
POLICY_NAME="{{ cookiecutter.iam_policy_name }}"
PROFILE=""

# IAM keeps at most 5 versions of a policy and one of them is always the default, so 4
# non-default versions means the next create would fail with LimitExceeded.
MAX_NON_DEFAULT_VERSIONS=4

usage() {
  # sed '$d', not `head -n -1`: negative counts are a GNU extension, so BSD head on
  # macOS fails the whole -h path with "illegal line count".
  sed -n '/^# Usage:/,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
  exit 0
}

log()  { printf '\033[1;34m[policy]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

while getopts "p:n:P:h" opt; do
  case "$opt" in
    p) POLICY_FILE="$OPTARG" ;;
    n) POLICY_NAME="$OPTARG" ;;
    P) PROFILE="$OPTARG" ;;
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
# `aws --version`, not `command -v aws`: a pip-installed aws in a venv under a path with
# a space has an unusable shebang, which only shows up on the first real invocation.
command aws --version >/dev/null 2>&1 \
  || die "AWS CLI not found, or found but not executable. Check 'aws --version'."

[[ -f "$POLICY_FILE" ]] || die "Policy file not found: $POLICY_FILE"

if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$POLICY_FILE" >/dev/null 2>&1 \
    || die "Policy file is not valid JSON: $POLICY_FILE"
fi

ACCOUNT_ID="$(awscli sts get-caller-identity --query "Account" --output text)" \
  || die "Could not determine the AWS account. Are your credentials configured?"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"

log "Account:      $ACCOUNT_ID"
log "Policy file:  $POLICY_FILE"
log "Policy name:  $POLICY_NAME"

# ------------------------------------------------------------------
# Create the policy, or publish a new default version of it
# ------------------------------------------------------------------
# stderr is captured rather than discarded so a missing policy can be told apart from an
# unreadable one. Treating both as "does not exist" makes an AccessDenied surface as a
# confusing failure to create a policy that is already there.
if NON_DEFAULT_VERSION_IDS="$(awscli iam list-policy-versions --policy-arn "$POLICY_ARN" \
     --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text 2>&1)"; then
  log "Policy exists - publishing a new version and setting it as default..."

  read -r -a VERSION_IDS <<<"$NON_DEFAULT_VERSION_IDS"
  {% raw %}if [[ "${#VERSION_IDS[@]}" -ge "$MAX_NON_DEFAULT_VERSIONS" ]]; then{% endraw %}
    # sort -V, not sort: IDs keep incrementing past the 5 retained, so v9 must precede v10
    OLDEST="$(printf '%s\n' "${VERSION_IDS[@]}" | sort -V | head -n 1)"
    log "Version limit reached - deleting oldest version $OLDEST"
    awscli iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
  fi

  awscli iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://$POLICY_FILE" \
    --set-as-default >/dev/null
  log "Policy updated: $POLICY_ARN"
elif [[ "$NON_DEFAULT_VERSION_IDS" == *NoSuchEntity* ]]; then
  log "Creating IAM policy $POLICY_NAME..."
  awscli iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://$POLICY_FILE" >/dev/null
  log "Policy created: $POLICY_ARN"
else
  die "Could not read $POLICY_ARN:
$NON_DEFAULT_VERSION_IDS"
fi
