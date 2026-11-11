#!/usr/bin/env bash
# Run a bounded CPU load on the two EC2 targets of the lab ALB.
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
  echo "Usage: bash scripts/ec2-load.sh [duration_seconds (30–600, default 360)]"
  exit 0
fi

duration=${1:-360}
if (( $# > 1 )) || [[ ! "$duration" =~ ^[1-9][0-9]{1,2}$ ]] || (( duration < 30 || duration > 600 )); then
  echo "Laufzeit in Sekunden angeben (30–600)." >&2
  exit 2
fi

awsx(){ aws --profile "${AWS_PROFILE:-lab}" --region "${AWS_REGION:-us-east-1}" "$@"; }

target_group=$(awsx elbv2 describe-target-groups --names cicd-lab-web \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
targets=$(awsx elbv2 describe-target-health --target-group-arn "$target_group" --output json |
  jq -er '.TargetHealthDescriptions
    | select(length == 2 and all(.[]; .TargetHealth.State == "healthy"))
    | [.[].Target.Id] | unique | select(length == 2) | join(",")') ||
  { echo "Der ALB muss zwei unterschiedliche, gesunde Ziele haben." >&2; exit 1; }

instances=$(awsx ec2 describe-instances --filters "Name=instance-id,Values=$targets" \
  'Name=tag:Project,Values=cicd-lab' 'Name=instance-state-name,Values=running' --output json)
instance_id(){
  jq -er --arg name "$1" '
    [.Reservations[].Instances[] | select(any(.Tags[]; .Key == "Name" and .Value == $name))]
    | select(length == 1) | .[0].InstanceId
  ' <<< "$instances"
}
primary=$(instance_id cicd-webserver)
secondary=$(instance_id cicd-webserver-2)

managed=$(awsx ssm describe-instance-information --filters "Key=InstanceIds,Values=$primary,$secondary" --output json)
jq -e '.InstanceInformationList | length == 2 and all(.[]; .PingStatus == "Online")' <<< "$managed" >/dev/null ||
  { echo "Beide Instanzen müssen in SSM online sein." >&2; exit 1; }

start_load(){
  local instance=$1 workers=$2 parameters command_id
  parameters=$(jq -nc --argjson workers "$workers" --argjson duration "$duration" '{
    commands: [
      "set -eu",
      "exec 9>/run/lock/cicd-lab-load.lock",
      "flock -n 9 || { echo \"Lasttest läuft bereits.\" >&2; exit 1; }",
      "workers=\($workers)",
      "duration=\($duration)",
      "pids=",
      "for i in $(seq 1 \"$workers\"); do nice -n 10 timeout \"${duration}s\" yes >/dev/null & pids=\"$pids $!\"; done",
      "failed=0",
      "for pid in $pids; do rc=0; wait \"$pid\" || rc=$?; [ \"$rc\" -eq 124 ] || failed=1; done",
      "exit \"$failed\""
    ],
    executionTimeout: [($duration + 30 | tostring)]
  }')
  command_id=$(awsx ssm send-command --instance-ids "$instance" --document-name AWS-RunShellScript \
    --comment "AWS DevLab CPU load: $workers worker(s), ${duration}s" --parameters "$parameters" \
    --query 'Command.CommandId' --output text)
  printf '%s: %s CPU-Worker für %ss, SSM Command ID %s\n' "$instance" "$workers" "$duration" "$command_id"
}

start_load "$primary" 1
start_load "$secondary" 2
