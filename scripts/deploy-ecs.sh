#!/usr/bin/env bash
set -euo pipefail

image=${1:?Supply an ECR image pinned by digest}
[[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/cicd-webserver@sha256:[0-9a-f]{64}$ ]] ||
  { echo "Invalid ECR image: $image" >&2; exit 1; }

cluster=cicd-webserver
service=cicd-webserver
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

describe_service() {
  aws ecs describe-services --cluster "$cluster" --services "$service" --output json
}

state=$(describe_service)
current=$(jq -er '.services[0] | select(.status == "ACTIVE") | .taskDefinition' <<< "$state") ||
  { echo "ECS service missing. Run aws-lab-reset.sh --restore first." >&2; exit 1; }

# Keep only fields accepted by RegisterTaskDefinition.
aws ecs describe-task-definition --task-definition "$service-template" --output json |
  jq -ceS --arg image "$image" --arg family "$service" '
    .taskDefinition
    | {
        family: $family, executionRoleArn, networkMode, requiresCompatibilities,
        cpu, memory, runtimePlatform,
        containerDefinitions: (.containerDefinitions | map(if .name == "nginx" then .image = $image else . end))
      }
    | select([.containerDefinitions[] | select(.name == "nginx")] | length == 1)
  ' > "$tmp/task.json"

# A rerun with the same digest and template can reuse the current revision.
current_config=$(aws ecs describe-task-definition --task-definition "$current" --output json |
  jq -cS --slurpfile template "$tmp/task.json" '.taskDefinition | with_entries(select(.key as $key | $template[0] | has($key)))')
revision="$current"
if [[ "$current_config" != "$(cat "$tmp/task.json")" ]]; then
  revision=$(aws ecs register-task-definition --cli-input-json "file://$tmp/task.json" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
fi

if [[ "$revision" != "$current" ]] || ! jq -e '.services[0].desiredCount == 1' <<< "$state" >/dev/null; then
  aws ecs update-service --cluster "$cluster" --service "$service" \
    --task-definition "$revision" --desired-count 1 >/dev/null
elif jq -e '.services[0].deployments[] | select(.status == "PRIMARY" and .rolloutState == "FAILED")' <<< "$state" >/dev/null; then
  aws ecs update-service --cluster "$cluster" --service "$service" \
    --task-definition "$revision" --desired-count 1 --force-new-deployment >/dev/null
fi

# Verify the requested revision as well as the deployment status.
for ((attempt = 1; attempt <= 60; attempt++)); do
  state=$(describe_service)
  if jq -e --arg revision "$revision" 'any(.services[0].deployments[];
      .status == "PRIMARY" and .taskDefinition == $revision and .rolloutState == "FAILED")' <<< "$state" >/dev/null; then
    jq '.services[0].events[:5]' <<< "$state" >&2
    exit 1
  fi
  if jq -e --arg revision "$revision" '
    .services[0] | .taskDefinition == $revision and .desiredCount == 1 and
    .runningCount == 1 and .pendingCount == 0 and (.deployments | length) == 1 and
    .deployments[0].rolloutState == "COMPLETED"
  ' <<< "$state" >/dev/null; then
    break
  fi
  if (( attempt == 60 )); then
    jq '.services[0].events[:5]' <<< "$state" >&2
    echo "Timed out waiting for $revision" >&2
    exit 1
  fi
  sleep 10
done

task=$(aws ecs list-tasks --cluster "$cluster" --service-name "$service" \
  --desired-status RUNNING --output json | jq -er '.taskArns | select(length == 1) | .[0]')
eni=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task" --output json |
  jq -er --arg revision "$revision" '
    .tasks[0] | select(.taskDefinitionArn == $revision and .lastStatus == "RUNNING")
    | .attachments[] | select(.type == "ElasticNetworkInterface")
    | .details[] | select(.name == "networkInterfaceId") | .value
  ')
ip=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" \
  --output json | jq -er '.NetworkInterfaces[0].Association.PublicIp')
url="http://$ip/"
curl --fail --silent --show-error --retry 8 --retry-all-errors --retry-delay 3 \
  --max-time 10 --output "$tmp/index.html" "$url"
cmp "$root/index.html" "$tmp/index.html"
echo "Fargate verified at $url ($revision, $image)"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Fargate smoke test passed at %s\n\nImage: `%s`\n' "$url" "$image" >> "$GITHUB_STEP_SUMMARY"
fi
