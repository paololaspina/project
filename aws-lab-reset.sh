#!/usr/bin/env bash
# AWS lab recovery for paololaspina/project. Run from repository root.
set -Eeuo pipefail
trap 'echo "FEHLER in Zeile $LINENO (Exitcode $?). Prüfe die Meldung darüber." >&2' ERR

MODE=${1:---help}
PROFILE=${AWS_PROFILE:-lab}
REGION=${AWS_REGION:-us-east-1}
REPO=${GITHUB_REPOSITORY:-paololaspina/project}
ECR_NAME=${ECR_REPOSITORY:-cicd-webserver}
ROLE_NAME=GitHubActions-CICD-Role
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TF_DIR="$ROOT/terraform"
BACKEND_KEY=cicd-webserver/terraform.tfstate
ACCOUNT=''

log(){ printf '\n==> %s\n' "$*"; }
fail(){ echo "FEHLER: $*" >&2; exit 1; }
awsx(){ aws --profile "$PROFILE" --region "$REGION" "$@"; }
exists(){ command -v "$1" >/dev/null 2>&1; }
need(){ exists "$1" || fail "Fehlendes Werkzeug: $1"; }
confirm(){ local ans; read -r -p "$1 [ja/NEIN] " ans; [[ "$ans" == ja ]]; }
aws_id(){ awsx sts get-caller-identity --query Account --output text; }
repo_url(){ git -C "$ROOT" remote get-url origin 2>/dev/null || true; }
preflight(){
  need aws; need jq; need git; need terraform
  [[ -d "$TF_DIR" ]] || fail "Terraform-Ordner fehlt: $TF_DIR"
  ACCOUNT=$(aws_id) || fail "AWS-Authentifizierung gescheitert: Profil $PROFILE prüfen (aws configure --profile $PROFILE)."
  [[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || fail "Unerwartete Account-ID: $ACCOUNT"
  log "AWS-Account: $ACCOUNT | Region: $REGION | Git-Remote: $(repo_url)"
}
check(){
  preflight
  local bucket="cicd-terraform-state-$ACCOUNT"
  log "Ressourcen prüfen (keine Änderungen)"
  if awsx s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then echo "S3: vorhanden ($bucket)"; else echo "S3: fehlt ($bucket)"; fi
  if awsx ecr describe-repositories --repository-names "$ECR_NAME" >/dev/null 2>&1; then
    echo "ECR: vorhanden ($ECR_NAME)"
    awsx ecr describe-images --repository-name "$ECR_NAME" --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags' --output json 2>/dev/null || true
  else echo "ECR: fehlt ($ECR_NAME)"; fi
  if awsx iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com" >/dev/null 2>&1; then echo 'OIDC: vorhanden'; else echo 'OIDC: fehlt'; fi
  if awsx iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then echo 'GitHub-IAM-Rolle: vorhanden'; else echo 'GitHub-IAM-Rolle: fehlt'; fi
  if [[ -f "$TF_DIR/backend.tf" ]]; then
    grep -n 'bucket\|key\|region' "$TF_DIR/backend.tf" || true
  fi
  git -C "$ROOT" status --short
}
ensure_bucket(){
  local bucket="cicd-terraform-state-$ACCOUNT"
  log "S3-State-Bucket prüfen: $bucket"
  if ! awsx s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    if [[ "$REGION" == us-east-1 ]]; then awsx s3api create-bucket --bucket "$bucket" >/dev/null
    else awsx s3api create-bucket --bucket "$bucket" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
  fi
  awsx s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  awsx s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
  awsx s3api put-bucket-encryption --bucket "$bucket" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}
ensure_ecr(){
  log "ECR-Repository prüfen: $ECR_NAME"
  awsx ecr describe-repositories --repository-names "$ECR_NAME" >/dev/null 2>&1 || \
    awsx ecr create-repository --repository-name "$ECR_NAME" --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE >/dev/null
}
ensure_oidc(){
  local arn="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
  log 'GitHub OIDC prüfen'
  awsx iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 || \
    awsx iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com >/dev/null
}
ensure_github_role(){
  log "GitHub-OIDC-Rolle prüfen: $ROLE_NAME"
  local trust policy arn="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
  trust=$(jq -nc --arg arn "$arn" --arg sub "repo:$REPO:ref:refs/heads/main" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:$arn},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com","token.actions.githubusercontent.com:sub":$sub}}}]}')
  if ! awsx iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    awsx iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$trust" >/dev/null
  else
    # Updating only our known-purpose role; preserves its other policies.
    awsx iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$trust"
  fi
  policy=$(jq -nc --arg repo "arn:aws:ecr:$REGION:$ACCOUNT:repository/$ECR_NAME" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"ecr:GetAuthorizationToken",Resource:"*"},{Effect:"Allow",Action:["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage"],Resource:$repo}]}')
  awsx iam put-role-policy --role-name "$ROLE_NAME" --policy-name GitHubActions-ECR-Push --policy-document "$policy"
}
prepare_tf(){
  log 'Terraform-Konfiguration für neue Sandbox prüfen'
  local bucket="cicd-terraform-state-$ACCOUNT"
  [[ -f "$TF_DIR/backend.tf" ]] || fail "backend.tf fehlt; für diese Version muss das Terraform-Projekt vorhanden sein."
  # Fail closed: do not change arbitrary Terraform files / hardcoded VPC or subnet IDs.
  local found
  found=$(grep -REho '[0-9]{12}' "$TF_DIR" --include='*.tf' 2>/dev/null | sort -u || true)
  if [[ -n "$found" ]] && [[ "$found" != "$ACCOUNT" ]]; then
    echo "Fremde Account-IDs in Terraform: $found" >&2
    fail 'Alte Account-IDs in .tf-Dateien: Terraform zunächst auf dynamische IDs umstellen. Keine automatische riskante Textersetzung.'
  fi
  if grep -REq '"(vpc-[a-z0-9]+|subnet-[a-z0-9]+)"' "$TF_DIR" --include='*.tf'; then
    fail 'Fest verdrahtete VPC-/Subnetz-ID gefunden. Zuerst Terraform-Datenquellen für die neue Sandbox einrichten.'
  fi
  # Own a narrowly defined backend.tf only after checking its contents.
  if ! grep -q "bucket[[:space:]]*=[[:space:]]*\"$bucket\"" "$TF_DIR/backend.tf"; then
    [[ -f "$TF_DIR/backend.tf" ]] && cp "$TF_DIR/backend.tf" "$TF_DIR/backend.tf.pre-reset.bak"
    cat > "$TF_DIR/backend.tf" <<BACKEND
terraform {
  backend "s3" {
    bucket       = "$bucket"
    key          = "$BACKEND_KEY"
    region       = "$REGION"
    encrypt      = true
    use_lockfile = true
  }
}
BACKEND
  fi
  terraform -chdir="$TF_DIR" fmt -check >/dev/null || terraform -chdir="$TF_DIR" fmt
  terraform -chdir="$TF_DIR" init -reconfigure -input=false
  terraform -chdir="$TF_DIR" validate
  terraform -chdir="$TF_DIR" plan -out=/tmp/cicd-lab-restore.tfplan -input=false
  echo 'Terraform-Plan liegt lokal unter /tmp/cicd-lab-restore.tfplan.'
}
update_workflow(){
  local workflow="$ROOT/.github/workflows/aws-cicd.yml"
  [[ -f "$workflow" ]] || fail "Workflow fehlt: $workflow"
  log 'GitHub-Actions-IAM-ARN aktualisieren'
  # Only replace role ARN, never touch credentials or commit/push automatically.
  sed -E -i "s#arn:aws:iam::[0-9]{12}:role/GitHubActions-CICD-Role#arn:aws:iam::$ACCOUNT:role/GitHubActions-CICD-Role#g" "$workflow"
  echo 'Workflow angepasst. Git-Push ist später erforderlich, um einen neuen Image-Build auszulösen.'
}
restore(){
  preflight
  log "Wiederherstellung für Account $ACCOUNT"
  echo 'Dieses Skript ändert S3/ECR/IAM und lokale Dateien; Terraform apply erfolgt erst nach gesonderter Bestätigung.'
  confirm 'Wiederherstellung starten?' || fail 'Abgebrochen.'
  ensure_bucket; ensure_ecr; ensure_oidc; ensure_github_role
  update_workflow
  prepare_tf
  echo
  echo 'Terraform-Plan prüfen. Er darf keine unerwarteten Löschungen enthalten.'
  if confirm 'Terraform-Plan jetzt anwenden?'; then
    terraform -chdir="$TF_DIR" apply -input=false /tmp/cicd-lab-restore.tfplan
  else echo 'Terraform apply übersprungen.'; fi
  log 'Abschluss: GitHub-Workflow kontrollieren, ggf. committen/pushen; Deployment separat auslösen.'
  git -C "$ROOT" status --short
}
case "$MODE" in
 --check) check;;
 --restore) restore;;
 --help|-h) cat <<HELP
Verwendung: ./aws-lab-reset.sh --check | --restore
Voraussetzungen: awscli, jq, git, terraform; gültiges AWS-Profil 'lab'.
Optional: AWS_PROFILE, AWS_REGION, GITHUB_REPOSITORY, ECR_REPOSITORY.
WICHTIG: Dieses Skript erstellt noch keinen vollständigen automatischen EC2-Deploy.
Es vermeidet absichtlich blindes Terraform-State-Migrieren und Git-Pushes.
HELP
 ;;
 *) fail "Unbekannter Modus: $MODE";;
esac
