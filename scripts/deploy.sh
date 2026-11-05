#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export AWS_PAGER=''
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK_PREFIX="${STACK_PREFIX:-quest}"
NETWORK_STACK="${STACK_PREFIX}-net"
ECR_STACK="${STACK_PREFIX}-ecr"
APP_STACK="${STACK_PREFIX}-app"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_command aws
[[ "$AWS_REGION" == us-east-1 ]] || fail 'This MVP pins a us-east-1 AMI; set AWS_REGION=us-east-1.'
[[ "$STACK_PREFIX" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,69}$ ]] ||
  fail 'STACK_PREFIX must start with a letter and contain at most 70 letters, digits, or hyphens.'

stack_output() {
  local value
  value=$(aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue | [0]" --output text)
  [[ -n "$value" && "$value" != None ]] || fail "Missing output $2 in stack $1."
  printf '%s\n' "$value"
}

create_certificate() (
  require_command openssl
  [[ $# -eq 1 && ${#1} -le 253 && "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] ||
    fail 'Provide a valid certificate hostname, e.g. quest.local.'
  umask 077
  DIRECTORY=$(mktemp -d)
  trap 'rm -rf "$DIRECTORY"' EXIT
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 \
    -subj "/CN=$1" -addext "subjectAltName=DNS:$1" \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout "$DIRECTORY/key.pem" -out "$DIRECTORY/cert.pem" >&2
  aws acm import-certificate \
    --certificate "fileb://$DIRECTORY/cert.pem" \
    --private-key "fileb://$DIRECTORY/key.pem" \
    --query CertificateArn --output text
)

resolve_certificate_arn() {
  if [[ -z "${CERTIFICATE_ARN:-}" ]]; then
    local existing_arn
    existing_arn=$(aws cloudformation describe-stacks --stack-name "$APP_STACK" \
      --query "Stacks[0].Outputs[?OutputKey=='CertificateArn'].OutputValue | [0]" \
      --output text 2>/dev/null || true)
    if [[ -z "$existing_arn" || "$existing_arn" == None ]]; then
      existing_arn=$(aws cloudformation describe-stacks --stack-name "$APP_STACK" \
        --query "Stacks[0].Parameters[?ParameterKey=='CertificateArn'].ParameterValue | [0]" \
        --output text 2>/dev/null || true)
    fi
    if [[ -n "$existing_arn" && "$existing_arn" != None ]]; then
      CERTIFICATE_ARN=$existing_arn
    else
      CERTIFICATE_ARN=$(create_certificate quest.local) ||
        fail 'Could not obtain an ACM certificate ARN.'
    fi
  fi
  export CERTIFICATE_ARN
}

require_certificate() (
  require_command openssl
  [[ "${CERTIFICATE_ARN:-}" =~ ^arn:aws:acm:us-east-1:[0-9]{12}:certificate/[a-f0-9-]+$ ]] ||
    fail 'Could not resolve a valid ACM certificate ARN.'
  local certificate
  certificate=$(mktemp)
  trap 'rm -f "$certificate"' EXIT
  aws acm get-certificate --certificate-arn "$CERTIFICATE_ARN" \
    --query Certificate --output text > "$certificate"
  [[ "$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253 | cut -d= -f2-)" == \
     "$(openssl x509 -in "$certificate" -noout -issuer -nameopt RFC2253 | cut -d= -f2-)" ]] ||
    fail 'The ACM certificate must be self-signed.'
  openssl verify -check_ss_sig -purpose sslserver -CAfile "$certificate" "$certificate" >&2
)

bootstrap() {
  aws cloudformation deploy --stack-name "$NETWORK_STACK" \
    --template-file "$PROJECT_ROOT/infra/quest-net.yaml" --no-fail-on-empty-changeset
  aws cloudformation deploy --stack-name "$ECR_STACK" \
    --template-file "$PROJECT_ROOT/infra/quest-ecr.yaml" --no-fail-on-empty-changeset
}

build_and_push() (
  require_command docker
  [[ $# -le 1 ]] || fail 'Provide at most one image tag.'
  TAG=${1:-latest}
  [[ "$TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || fail 'Invalid Docker image tag.'
  if ! STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$ECR_STACK" \
    --query 'Stacks[0].StackStatus' --output text 2>&1); then
    if [[ "$STACK_STATUS" == *"Stack with id $ECR_STACK does not exist"* ]]; then
      bootstrap >&2
    else
      fail "$STACK_STATUS"
    fi
  fi
  REPOSITORY_URI=$(stack_output "$ECR_STACK" RepositoryUri)
  REGISTRY="${REPOSITORY_URI%%/*}"
  aws ecr get-login-password |
    docker login --username AWS --password-stdin "$REGISTRY" >&2
  docker buildx build --platform linux/amd64 \
    --tag "$REPOSITORY_URI:$TAG" --push "$PROJECT_ROOT" >&2
  printf '%s:%s\n' "$REPOSITORY_URI" "$TAG"
)

deploy() (
  SECRET_INPUT=''
  SET_SECRET=false
  IMAGE_URI=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set-secret)
        [[ $# -ge 2 && "$SET_SECRET" == false ]] || fail '--set-secret requires one word or file.'
        SECRET_INPUT=$2
        SET_SECRET=true
        shift 2
        ;;
      -*) fail "Unknown option: $1" ;;
      *)
        [[ -z "$IMAGE_URI" ]] || fail 'Provide at most one ECR image URI.'
        IMAGE_URI=$1
        shift
        ;;
    esac
  done

  if [[ "$SET_SECRET" == true ]]; then
    require_command python3
    umask 077
    WORK_DIRECTORY=$(mktemp -d)
    trap 'rm -rf "$WORK_DIRECTORY"' EXIT
    if [[ -f "$SECRET_INPUT" ]]; then
      SECRET_FILE=$SECRET_INPUT
    elif [[ -e "$SECRET_INPUT" ]]; then
      fail 'Secret path must be a regular file.'
    else
      SECRET_FILE="$WORK_DIRECTORY/secret"
      printf '%s' "$SECRET_INPUT" > "$SECRET_FILE"
    fi
    JSON_FILE="$WORK_DIRECTORY/parameter.json"
    python3 - "$SECRET_FILE" "/$STACK_PREFIX/secret-word" > "$JSON_FILE" <<'PY'
import json
import pathlib
import sys

value = pathlib.Path(sys.argv[1]).read_text().rstrip("\r\n")
if not value or any(char in value for char in "\r\n\0"):
    sys.exit("Error: secret must be a nonempty single line.")
print(json.dumps({
    "Name": sys.argv[2], "Value": value, "Type": "SecureString", "Overwrite": True
}))
PY
  elif [[ -z "$IMAGE_URI" ]]; then
    require_command docker
  fi

  resolve_certificate_arn
  require_certificate
  if [[ -z "$IMAGE_URI" ]]; then
    if [[ "$SET_SECRET" == true ]]; then
      IMAGE_URI=$(stack_output "$APP_STACK" ImageUri)
    else
      bootstrap >&2
      IMAGE_URI=$(build_and_push)
      export DEPLOYMENT_REVISION="${DEPLOYMENT_REVISION:-deploy-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM}"
    fi
  fi

  REPOSITORY_URI=$(stack_output "$ECR_STACK" RepositoryUri)
  [[ "$IMAGE_URI" == "$REPOSITORY_URI"@sha256:* || "$IMAGE_URI" == "$REPOSITORY_URI":* ]] ||
    fail 'Image must be a tag or digest URI from this deployment registry.'
  if [[ "$IMAGE_URI" == *@* ]]; then
    IMAGE_DIGEST=${IMAGE_URI##*@}
    [[ "$IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'Invalid image digest.'
    IMAGE_TAG=latest
  else
    IMAGE_TAG=${IMAGE_URI##*:}
    [[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]] || fail 'Invalid image tag.'
    IMAGE_DIGEST=''
  fi

  if [[ "$SET_SECRET" == true ]]; then
    aws ssm put-parameter --cli-input-json "file://$JSON_FILE" --output json >/dev/null
    export USE_SECRET=true
    export DEPLOYMENT_REVISION="secret-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  fi

  PARAMETERS=(
    "ImageTag=$IMAGE_TAG"
    "ImageDigest=$IMAGE_DIGEST"
    "CertificateArn=$CERTIFICATE_ARN"
  )

  if [[ "${USE_SECRET+x}" ]]; then
    PARAMETERS+=("UseSecret=$USE_SECRET")
  fi
  if [[ "${DEPLOYMENT_REVISION+x}" ]]; then
    PARAMETERS+=("DeploymentRevision=$DEPLOYMENT_REVISION")
  fi

  aws cloudformation deploy \
    --stack-name "$APP_STACK" \
    --template-file "$PROJECT_ROOT/infra/quest-app.yaml" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
      "ProjectPrefix=$STACK_PREFIX" \
      "NetworkStackName=$NETWORK_STACK" \
      "EcrStackName=$ECR_STACK" \
      "${PARAMETERS[@]}" \
    --no-fail-on-empty-changeset

  aws elbv2 wait target-in-service \
    --target-group-arn "$(stack_output "$APP_STACK" TargetGroupArn)"

  printf 'Application: %s\n' "$(stack_output "$APP_STACK" ApplicationUrl)"
  printf 'Self-signed TLS: browsers warn; use curl -k for this demo.\n'
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  deploy "$@"
fi
