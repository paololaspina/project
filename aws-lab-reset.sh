#!/usr/bin/env bash

# Git-Ausgaben ohne interaktiven Pager anzeigen.
export GIT_PAGER=cat
# AWS training lab recovery for paololaspina/project.
# --check: read-only diagnostics; --restore: account-aware provisioning and deployment;
# --deploy: redeploy the image for the current GitHub main commit.
set -Eeuo pipefail
trap 'rc=$?; echo "FEHLER (Zeile $LINENO, Exit $rc). Letzte Meldung beachten." >&2' ERR

# AWS-Profil auch für Terraform und das S3-Backend setzen.
export AWS_PROFILE="${AWS_PROFILE:-lab}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

MODE=${1:---help}
PROFILE=${AWS_PROFILE:-lab}
REGION=${AWS_REGION:-us-east-1}
REPO=${GITHUB_REPOSITORY:-paololaspina/project}
ECR_NAME=${ECR_REPOSITORY:-cicd-webserver}
ROLE_NAME=GitHubActions-CICD-Role
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TF_DIR="$ROOT/terraform"
WORKFLOW="$ROOT/.github/workflows/aws-cicd.yml"
BACKEND_KEY=cicd-webserver/terraform.tfstate
ACCOUNT=''
BUCKET=''

log(){ printf '\n==> %s\n' "$*"; }
fail(){ printf 'FEHLER: %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "Benötigt: $1"; }
awsx(){ aws --profile "$PROFILE" --region "$REGION" "$@"; }
confirm(){ local a; read -r -p "$1 [ja/NEIN] " a; [[ "$a" == ja ]]; }
preflight(){
  need aws; need jq; need git
  if [[ "$MODE" == --restore ]]; then
    need terraform; need python3; need curl
  fi
  [[ "$REGION" == us-east-1 ]] || fail 'Dieses Lab verwendet us-east-1.'
  [[ -d "$TF_DIR" && -f "$WORKFLOW" ]] || fail 'Terraform-Ordner oder AWS-Workflow fehlt.'
  ACCOUNT=$(awsx sts get-caller-identity --query Account --output text) || fail 'AWS-Zugangsdaten prüfen.'
  [[ "$ACCOUNT" =~ ^[0-9]{12}$ ]] || fail 'Ungültige AWS-Account-ID.'
  BUCKET="cicd-terraform-state-$ACCOUNT"
  log "Account $ACCOUNT | Region $REGION | Repo $REPO"
}
aws_error_code(){ sed -nE 's/.*\(([[:alnum:]_]+)\) when calling.*/\1/p' <<< "$1" | head -n1; }
check_bucket(){
  local out rc
  if out=$(awsx s3api head-bucket --bucket "$BUCKET" 2>&1); then
    echo "S3 vorhanden: $BUCKET"; return 0
  else
    rc=$(aws_error_code "$out")
    if [[ "$rc" == 404 || "$rc" == NoSuchBucket || "$out" == *'404'* ]]; then
      echo "S3 fehlt: $BUCKET"; return 1
    fi
    fail "S3-Prüfung fehlgeschlagen (kein nachgewiesenes 404): $out"
  fi
}
ensure_bucket(){
  log 'S3-State-Backend'
  if ! check_bucket; then
    if [[ "$REGION" == us-east-1 ]]; then
      awsx s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
      awsx s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
  fi
  awsx s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true' >/dev/null
  awsx s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled >/dev/null
  awsx s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
}
ensure_ecr(){
  log 'ECR-Repository'
  awsx ecr describe-repositories --repository-names "$ECR_NAME" >/dev/null 2>&1 || \
    awsx ecr create-repository --repository-name "$ECR_NAME" --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE >/dev/null
}
ensure_identity(){
  log 'GitHub OIDC + Push-Rolle'
  local provider="arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
  local trust sub policy
  local error code
  if ! error=$(awsx iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" 2>&1); then
    code=$(aws_error_code "$error")
    [[ "$code" == NoSuchEntity ]] || fail "OIDC-Prüfung fehlgeschlagen: $error"
    awsx iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com >/dev/null
  fi
  # Preserve the previously working custom subject, if present; do not guess a new subject format.
  sub="repo:$REPO:ref:refs/heads/main"
  if [[ -f "$ROOT/github-oidc-trust.json" ]]; then
    sub=$(jq -er '[.Statement[]?.Condition.StringEquals["token.actions.githubusercontent.com:sub"]?] | map(select(type=="string")) | first' "$ROOT/github-oidc-trust.json") || fail 'OIDC-Subject in github-oidc-trust.json fehlt.'
  fi
  trust=$(jq -nc --arg arn "$provider" --arg sub "$sub" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Federated:$arn},Action:"sts:AssumeRoleWithWebIdentity",Condition:{StringEquals:{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com","token.actions.githubusercontent.com:sub":$sub}}}]}')
  if error=$(awsx iam get-role --role-name "$ROLE_NAME" 2>&1); then
    awsx iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$trust" >/dev/null
  else
    code=$(aws_error_code "$error")
    [[ "$code" == NoSuchEntity ]] || fail "IAM-Rollenprüfung fehlgeschlagen: $error"
    awsx iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$trust" >/dev/null
  fi
  policy=$(jq -nc --arg repo "arn:aws:ecr:$REGION:$ACCOUNT:repository/$ECR_NAME" '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:"ecr:GetAuthorizationToken",Resource:"*"},{Effect:"Allow",Action:["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage"],Resource:$repo}]}')
  awsx iam put-role-policy --role-name "$ROLE_NAME" --policy-name GitHubActions-ECR-Push --policy-document "$policy" >/dev/null
}
prepare_configuration(){
  log 'Lokale Konfiguration accountabhängig erstellen'
  [[ -f "$TF_DIR/backend.tf" ]] || fail 'terraform/backend.tf fehlt.'
  # Refuse to reuse a real local state or unrecognized account references.
  [[ ! -s "$TF_DIR/terraform.tfstate" ]] || fail 'Lokaler terraform.tfstate ist befüllt; erst manuell untersuchen.'
  [[ ! -s "$TF_DIR/terraform.tfstate.backup" ]] || echo 'Hinweis: lokales State-Backup vorhanden; wird nicht verwendet.'
  if grep -REq '"(vpc-[0-9a-f]+|subnet-[0-9a-f]+)"' "$TF_DIR" --include='*.tf'; then
    fail 'Terraform enthält noch hartcodierte VPC-/Subnetz-IDs.'
  fi
  # S3 backend settings are narrowly defined; reconfigure without state migration.
  local existing
  existing=$(grep -E '^[[:space:]]*bucket[[:space:]]*=' "$TF_DIR/backend.tf" | wc -l)
  [[ "$existing" -eq 1 ]] || fail 'backend.tf hat eine unerwartete Struktur.'
  if ! grep -Fq "\"$BUCKET\"" "$TF_DIR/backend.tf"; then
    cp "$TF_DIR/backend.tf" "$TF_DIR/backend.tf.pre-reset.bak"
    cat > "$TF_DIR/backend.tf" <<BACKEND
terraform {
  backend "s3" {
    bucket       = "$BUCKET"
    key          = "$BACKEND_KEY"
    region       = "$REGION"
    encrypt      = true
    use_lockfile = true
  }
}
BACKEND
  fi
  # Change only known ARN account components in *.tf; save originals if needed.
  AWS_NEW_ACCOUNT="$ACCOUNT" TF_UPDATE_DIR="$TF_DIR" python3 - <<'PY'
import os, re
from pathlib import Path
account = os.environ['AWS_NEW_ACCOUNT']
pattern = re.compile(r'(arn:aws(?:-[a-z]+)?:[a-z0-9-]+:[^:\s]*:)(\d{12})(?=:)')
for path in Path(os.environ['TF_UPDATE_DIR']).glob('*.tf'):
    content = path.read_text()
    changed = pattern.sub(lambda m: m.group(1) + account, content)
    if changed != content:
        path.with_name(path.name + '.pre-reset.bak').write_text(content)
        path.write_text(changed)
        print('ARN korrigiert:', path.name)
PY
  # Any leftover foreign 12-digit account number needs human inspection.
  local foreign
  foreign=$(grep -REho '[0-9]{12}' "$TF_DIR" --include='*.tf' | grep -vx "$ACCOUNT" | sort -u || true)
  [[ -z "$foreign" ]] || fail "Fremde Account-IDs verbleiben in Terraform: $foreign"
  sed -E -i "s#arn:aws:iam::[0-9]{12}:role/GitHubActions-CICD-Role#arn:aws:iam::$ACCOUNT:role/GitHubActions-CICD-Role#g" "$WORKFLOW"
  terraform -chdir="$TF_DIR" fmt >/dev/null
}
verify_remote_state(){
  local out rc
  if out=$(awsx s3api head-object --bucket "$BUCKET" --key "$BACKEND_KEY" 2>&1); then
    echo 'Remote-State für DIESEN Account vorhanden.'
  else
    rc=$(aws_error_code "$out")
    if [[ "$rc" == 404 || "$rc" == NoSuchKey || "$out" == *'404'* ]]; then
      echo 'Neuer Remote-State (kein State-Objekt vorhanden).'
    else
      fail "Remote-State nicht lesbar / Berechtigungsfehler: $out"
    fi
  fi
}
prepare_loki_lambda(){
  log 'Lambda-Paket für Grafana Loki prüfen'
  local manifest="$TF_DIR/loki-lambda-release.json"
  local archive="$TF_DIR/.terraform/lambda-promtail.zip"
  local url expected actual download
  url=$(jq -er '.url' "$manifest")
  expected=$(jq -er '.sha256_base64' "$manifest")
  mkdir -p "$(dirname "$archive")"
  if [[ -f "$archive" ]]; then
    actual=$(loki_package_hash "$archive")
    [[ "$actual" != "$expected" ]] || return 0
  fi
  download=$(mktemp "${archive}.XXXXXX")
  if ! curl --fail --silent --show-error --location --retry 3 --max-time 120 --output "$download" "$url" ||
    [[ "$(loki_package_hash "$download")" != "$expected" ]]; then
    rm -f "$download"
    fail 'Das Lambda-Paket konnte nicht verifiziert werden.'
  fi
  mv -f "$download" "$archive"
}

loki_package_hash(){
  python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha256(open(sys.argv[1], "rb").read()).digest()).decode())' "$1"
}

terraform_restore(){
  log 'Terraform initialisieren und planen'
  verify_remote_state
  terraform -chdir="$TF_DIR" init -reconfigure -input=false
  terraform -chdir="$TF_DIR" validate
  local plan plan_json
  plan=$(mktemp /tmp/cicd-lab-plan.XXXXXX)
  terraform -chdir="$TF_DIR" plan -input=false -out="$plan"
  # Fail closed on proposed deletions/replacements.
  plan_json=$(terraform -chdir="$TF_DIR" show -json "$plan")
  jq -e 'type == "object" and has("format_version")' <<< "$plan_json" >/dev/null ||
    fail 'Terraform-Plan konnte nicht ausgewertet werden.'
  if ! jq -e 'all(.resource_changes[]?; .change.actions | index("delete") | not)' <<< "$plan_json" >/dev/null; then
    rm -f "$plan"; fail 'Terraform plant Löschen/Ersetzen. Kein automatisches Apply.'
  fi
  if confirm 'Terraform-Plan anwenden?'; then
    terraform -chdir="$TF_DIR" apply -input=false "$plan"
  else
    rm -f "$plan"; fail 'Apply abgelehnt; Pipeline wird NICHT gestartet.'
  fi
  rm -f "$plan"
}
verify_git(){
  need gh
  gh auth status >/dev/null 2>&1 || fail 'GitHub CLI: gh auth login ausführen.'
  [[ "$(git -C "$ROOT" branch --show-current)" == main ]] || fail 'Bitte Branch main verwenden.'
  [[ "$(git -C "$ROOT" remote get-url origin)" == *"$REPO"* ]] || fail 'Git-Remote passt nicht zum konfigurierten Repository.'
  git -C "$ROOT" fetch origin main
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse origin/main)" ]] || fail 'Lokaler main ist nicht mit origin/main synchron.'
  [[ -z "$(git -C "$ROOT" diff --cached --name-only)" ]] || fail 'Es liegen bereits gestagte Dateien vor; bitte zuerst prüfen.'
}
sync_github(){
  log 'Account-Konfiguration per Pull Request synchronisieren'
  verify_git

  local files=(
    terraform/backend.tf
    terraform/iam.tf
    .github/workflows/aws-cicd.yml
  )

  git -C "$ROOT" add -- "${files[@]}"

  if git -C "$ROOT" diff --cached --quiet; then
    echo 'GitHub-Konfiguration bereits synchronisiert.'
    return 0
  fi

  git -C "$ROOT" diff --cached --check
  git -C "$ROOT" diff --cached --stat

  confirm 'Account-Konfiguration als Pull Request übertragen?' ||
    fail 'GitHub-Synchronisierung abgelehnt.'

  local branch pr checks
  branch="restore/aws-$ACCOUNT-$(date +%s)"

  git -C "$ROOT" switch -c "$branch"
  git -C "$ROOT" commit -m "Update AWS lab for account $ACCOUNT"
  git -C "$ROOT" push -u origin "$branch"

  pr=$(gh pr create \
    --repo "$REPO" \
    --base main \
    --head "$branch" \
    --title "Restore AWS lab account $ACCOUNT" \
    --body "Synchronisiert Terraform-Backend und GitHub-OIDC-Rolle für den aktuellen AWS-Account.")

  echo "Pull Request: $pr"
  echo 'Warte auf GitHub-Prüfungen ...'

  gh pr checks "$pr" --repo "$REPO" --watch ||
    fail 'GitHub-Checks fehlgeschlagen oder nicht abgeschlossen.'

  checks=$(gh pr view "$pr" --repo "$REPO" \
    --json statusCheckRollup \
    --jq '[.statusCheckRollup[] |
      select((.name | contains("Terraform Validate")) and
      .conclusion == "SUCCESS")] | length')

  [[ "$checks" -ge 1 ]] ||
    fail 'Erfolgreicher Terraform-Validate-Check fehlt.'

  confirm 'Pull Request nach erfolgreicher Prüfung mergen?' ||
    fail 'Merge nicht bestätigt. Pull Request bleibt offen.'

  gh pr merge "$pr" --repo "$REPO" --squash --delete-branch ||
    fail 'Pull-Request-Merge fehlgeschlagen.'

  git -C "$ROOT" switch main
  git -C "$ROOT" pull --ff-only origin main ||
    fail 'Lokaler main konnte nicht aktualisiert werden.'

  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$(git -C "$ROOT" rev-parse origin/main)" ]] ||
    fail 'Lokaler main ist nicht synchron.'

  echo 'GitHub-Synchronisierung abgeschlossen.'
}

sync_operator_profile(){
  log 'AWS Operator-Profil fuer aktuellen Account aktualisieren'
  need aws

  local role="Terraform-Operator-Role"
  local arn="arn:aws:iam::$ACCOUNT:role/$role"
  local identity

  awsx iam get-role --role-name "$role" >/dev/null ||
    fail "Operator-Rolle fehlt: $role"

  aws configure set role_arn "$arn" --profile operator
  aws configure set source_profile "$PROFILE" --profile operator
  aws configure set region "$REGION" --profile operator
  aws configure set role_session_name lab-operator --profile operator

  identity=$(aws sts get-caller-identity \
    --profile operator \
    --query Arn \
    --output text) || fail 'Operator-Rollenuebernahme fehlgeschlagen.'

  [[ "$identity" == "arn:aws:sts::$ACCOUNT:assumed-role/$role/"* ]] ||
    fail "Unerwartete Operator-Identitaet: $identity"

  echo "Operator-Profil bereit: $identity"
}

sync_terraform_roles(){
  log 'GitHub Terraform-Rollen fuer aktuellen AWS-Account synchronisieren'
  need gh

  local role arn actual
  for role in Plan Apply; do
    awsx iam get-role \
      --role-name "GitHubActions-Terraform-${role}-Role" \
      >/dev/null || fail "Terraform-${role}-Rolle fehlt."

    arn="arn:aws:iam::$ACCOUNT:role/GitHubActions-Terraform-${role}-Role"

    gh variable set "TERRAFORM_${role^^}_ROLE_ARN" \
      --repo "$REPO" \
      --body "$arn" || fail "GitHub-Variable fuer ${role} konnte nicht gesetzt werden."

    actual=$(gh variable get "TERRAFORM_${role^^}_ROLE_ARN" \
      --repo "$REPO" --json value --jq '.value') || fail "GitHub-Variable fuer ${role} nicht lesbar."

    [[ "$actual" == "$arn" ]] || fail "GitHub-Variable fuer ${role} stimmt nicht."

    echo "TERRAFORM_${role^^}_ROLE_ARN: $actual"
  done
}

sync_ecs_role(){
  local role=GitHubActions-ECS-Deploy-Role
  local arn="arn:aws:iam::$ACCOUNT:role/$role"
  local actual
  awsx iam get-role --role-name "$role" >/dev/null
  gh variable set ECS_DEPLOY_ROLE_ARN --repo "$REPO" --body "$arn"
  actual=$(gh variable get ECS_DEPLOY_ROLE_ARN --repo "$REPO" --json value --jq '.value')
  [[ "$actual" == "$arn" ]] || fail 'GitHub-Variable für ECS stimmt nicht.'
}

image_exists(){
  awsx ecr describe-images --repository-name "$ECR_NAME" --image-ids "imageTag=$1" >/dev/null 2>&1
}
current_sha(){ gh api "repos/$REPO/commits/main" --jq '.sha'; }
run_pipeline(){
  verify_git
  log 'GitHub Actions / ECR / Fargate'
  local sha run_id restore_id attempt
  sha=$(git -C "$ROOT" rev-parse HEAD)
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail 'Ungültiger GitHub Commit-SHA.'
  restore_id="restore-$ACCOUNT-$(date +%s)-$$"

  # A previous run or image may belong to an earlier sandbox. Always start
  # a new run, which reuses the image in this account if it already exists.
  gh workflow run aws-cicd.yml -R "$REPO" --ref main -f "restore_id=$restore_id"
  for attempt in {1..30}; do
    run_id=$(gh run list -R "$REPO" --workflow aws-cicd.yml --branch main --commit "$sha" \
      --event workflow_dispatch --limit 20 --json databaseId,displayTitle \
      --jq ".[] | select(.displayTitle == \"AWS CI/CD $restore_id\") | .databaseId")
    [[ -n "$run_id" ]] && break
    sleep 5
  done
  [[ -n "$run_id" ]] || fail 'Restore-Lauf für diesen main-Commit nicht gefunden.'
  echo "GitHub-Actions-Lauf: https://github.com/$REPO/actions/runs/$run_id"
  gh run watch "$run_id" -R "$REPO" --exit-status || fail 'CI/CD-Pipeline fehlgeschlagen.'
  image_exists "$sha" || fail 'ECR-Image für den geprüften Commit fehlt im Sandbox-Account.'
  DEPLOY_SHA=$sha
}
wait_for_ec2_target(){
  local target_group=$1 instance=$2 state attempt
  for attempt in {1..36}; do
    state=$(awsx elbv2 describe-target-health --target-group-arn "$target_group" \
      --targets "Id=$instance,Port=80" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
    [[ "$state" != healthy ]] || return 0
    sleep 5
  done
  awsx elbv2 describe-target-health --target-group-arn "$target_group" --targets "Id=$instance,Port=80"
  fail "ALB-Ziel $instance ist nicht healthy."
}

deploy_ec2_target(){
  local instance=$1 params=$2 ping_status attempt command_id result status
  log "SSM-Deployment auf $instance"
  for attempt in {1..36}; do
    ping_status=$(awsx ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$instance" \
      --query 'InstanceInformationList[0].PingStatus' --output text)
    [[ "$ping_status" == Online ]] && break
    sleep 5
  done
  [[ "$ping_status" == Online ]] || fail "SSM-Agent für $instance ist nicht online."
  command_id=$(awsx ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
    --parameters "$params" --query 'Command.CommandId' --output text)
  if ! awsx ssm wait command-executed --command-id "$command_id" --instance-id "$instance"; then
    echo "SSM Waiter meldet für $instance noch keinen Erfolg; Detailstatus folgt." >&2
  fi
  result=$(awsx ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" --output json)
  status=$(jq -r '.Status' <<< "$result")
  if [[ "$status" != Success ]]; then
    jq '{Status,StandardErrorContent,StandardOutputContent}' <<< "$result"
    fail "SSM-Deployment auf $instance fehlgeschlagen: $status"
  fi
}

deploy_web(){
  preflight; need curl; need gh
  log 'EC2-Deployment hinter dem Application Load Balancer'
  local sha registry image params target_group targets instance dns
  local -a instances
  sha=${DEPLOY_SHA:-$(current_sha)}
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail 'Ungültiger GitHub Commit-SHA.'
  image_exists "$sha" || fail "ECR-Image für main ($sha) fehlt. Zuerst --restore ausführen."
  target_group=$(awsx elbv2 describe-target-groups --names cicd-lab-web \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
  targets=$(awsx elbv2 describe-target-health --target-group-arn "$target_group" \
    --query 'TargetHealthDescriptions[].Target.Id' --output json)
  jq -e 'length == 2 and (unique | length == 2) and all(.[]; test("^i-[0-9a-f]+$"))' <<< "$targets" >/dev/null ||
    fail 'Der ALB erwartet genau zwei verschiedene EC2-Ziele.'
  mapfile -t instances < <(jq -r '.[]' <<< "$targets")

  registry="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
  image="$registry/$ECR_NAME:$sha"
  params=$(jq -nc --arg region "$REGION" --arg registry "$registry" --arg image "$image" '{
    commands: [
      "set -eu",
      "cloud-init status --wait || systemctl is-active --quiet docker",
      ("aws ecr get-login-password --region " + $region + " | docker login --username AWS --password-stdin " + $registry),
      ("docker pull " + $image),
      "docker logout >/dev/null 2>&1 || true",
      "docker rm -f cicd-webserver 2>/dev/null || true",
      ("docker run -d --name cicd-webserver --restart unless-stopped -p 80:80 " + $image),
      "curl --fail --silent --show-error --retry 5 --retry-connrefused --max-time 5 http://127.0.0.1/ >/dev/null"
    ]
  }')
  for instance in "${instances[@]}"; do
    deploy_ec2_target "$instance" "$params"
    wait_for_ec2_target "$target_group" "$instance"
  done

  dns=$(awsx elbv2 describe-load-balancers --names cicd-lab-web \
    --query 'LoadBalancers[0].DNSName' --output text)
  [[ -n "$dns" && "$dns" != None ]] || fail 'Der ALB hat keinen DNS-Namen.'
  curl --retry 8 --retry-all-errors --retry-delay 3 --fail --silent --show-error \
    --max-time 10 "http://$dns/" >/dev/null || fail "Website unter http://$dns/ nicht erreichbar"
  echo "ERFOLG: Beide EC2-Ziele sind healthy. Website erreichbar: http://$dns/"
}
check(){
  preflight
  log 'Read-only Bestandsaufnahme'
  check_bucket || true
  if awsx ecr describe-repositories --repository-names "$ECR_NAME" >/dev/null 2>&1; then echo "ECR: $ECR_NAME vorhanden"; else echo 'ECR: fehlt oder nicht lesbar'; fi
  if awsx iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then echo 'GitHub-IAM-Rolle: vorhanden'; else echo 'GitHub-IAM-Rolle: fehlt oder nicht lesbar'; fi
  printf 'Git-Arbeitsverzeichnis:\n'; git -C "$ROOT" status --short
}
restore(){
  preflight
  verify_git
  log "RESTORE für $ACCOUNT — Änderungen an S3/ECR/IAM und Terraform"
  confirm 'Wiederherstellung beginnen?' || fail 'Abgebrochen.'
  ensure_bucket
  prepare_configuration
  prepare_loki_lambda
  terraform_restore
  sync_operator_profile
  sync_terraform_roles
  sync_ecs_role
  sync_github
  run_pipeline
  deploy_web
  log 'Wiederherstellung abgeschlossen.'
}
case "$MODE" in
  --check) check ;;
  --restore) restore ;;
  --deploy) deploy_web ;;
  --help|-h) cat <<'HELP'
AWS Lab: ./aws-lab-reset.sh --check | --restore | --deploy
Voraussetzungen: aws, terraform, jq, git, gh, curl, python3; AWS-Profil lab.
Vor Restore: AWS-Zugangsdaten erneuern (aws configure --profile lab), gh auth login nur einmalig.
Sicherheit: Kein Terraform-State-Migration; kein Apply bei geplanten Löschungen;
           nur ausgewählte AWS-Konfigurationsdateien werden nach Bestätigung gepusht.
Einschränkungen: AWS-Berechtigungen, Standard-VPC/Subnetz und GitHub-OIDC-Subject
                  müssen zur neuen Sandbox passen. Neuer Account ist ungetestet.
HELP
  ;;
  *) fail "Unbekannter Modus: $MODE" ;;
esac
