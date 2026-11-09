#!/usr/bin/env bash
# Simulate ECS, ECR digest input and HTTP. No cloud credentials are used.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

state_dir=$(mktemp -d)
trap 'rm -rf "$state_dir"' EXIT
export TEST_STATE="$state_dir"
export TEST_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/cicd-webserver@sha256:$(printf '%064d' 1)"
export TEST_REVISION="arn:aws:ecs:us-east-1:123456789012:task-definition/cicd-webserver:7"
export TEST_TEMPLATE="arn:aws:ecs:us-east-1:123456789012:task-definition/cicd-webserver-template:1"

aws() {
  case "$1 $2" in
    'ecs describe-services')
      if [[ -e "$TEST_STATE/updated" ]]; then
        jq -nc --arg revision "$TEST_REVISION" '{services:[{status:"ACTIVE",taskDefinition:$revision,
          desiredCount:1,runningCount:1,pendingCount:0,deployments:[{rolloutState:"COMPLETED"}]}]}'
      else
        jq -nc --arg revision "$TEST_TEMPLATE" '{services:[{status:"ACTIVE",taskDefinition:$revision,
          desiredCount:0,runningCount:0,deployments:[]}]}'
      fi
      ;;
    'ecs describe-task-definition')
      if [[ "$4" == "$TEST_REVISION" ]]; then
        jq '{taskDefinition:.}' "$TEST_STATE/registered"
      else
        echo '{"taskDefinition":{"family":"cicd-webserver-template","executionRoleArn":"execution",
          "networkMode":"awsvpc","requiresCompatibilities":["FARGATE"],"cpu":"256","memory":"512",
          "runtimePlatform":{"cpuArchitecture":"X86_64","operatingSystemFamily":"LINUX"},
          "containerDefinitions":[{"name":"nginx","image":"placeholder","portMappings":[{"containerPort":80}]}]}}'
      fi
      ;;
    'ecs register-task-definition')
      [[ ! -e "$TEST_STATE/registered" ]] || return 91
      cp "${4#file://}" "$TEST_STATE/registered"
      jq -e --arg image "$TEST_IMAGE" '.family == "cicd-webserver" and
        .containerDefinitions[0].image == $image and
        .containerDefinitions[0].portMappings[0].containerPort == 80' "$TEST_STATE/registered" >/dev/null
      echo "$TEST_REVISION"
      ;;
    'ecs update-service')
      [[ "$*" == *"--task-definition $TEST_REVISION --desired-count 1" ]] || return 92
      touch "$TEST_STATE/updated"
      ;;
    'ecs list-tasks')
      echo '{"taskArns":["task-1"]}'
      ;;
    'ecs describe-tasks')
      jq -nc --arg revision "$TEST_REVISION" '{tasks:[{taskDefinitionArn:$revision,lastStatus:"RUNNING",
        attachments:[{type:"ElasticNetworkInterface",details:[{name:"networkInterfaceId",value:"eni-test"}]}]}]}'
      ;;
    'ec2 describe-network-interfaces')
      [[ "$4" == eni-test ]] || return 93
      echo '{"NetworkInterfaces":[{"Association":{"PublicIp":"192.0.2.1"}}]}'
      ;;
    *)
      echo "Unexpected AWS command: $*" >&2
      return 99
      ;;
  esac
}

curl() {
  while [[ "$1" != --output ]]; do shift; done
  [[ "$3" == http://192.0.2.1/ ]] || return 94
  if [[ "${MOCK_WRONG_PAGE:-}" == yes ]]; then
    echo 'Welcome to nginx!' > "$2"
  else
    cp index.html "$2"
  fi
}
export -f aws curl

bash scripts/deploy-ecs.sh "$TEST_IMAGE"
bash scripts/deploy-ecs.sh "$TEST_IMAGE" # Identical image/template must not register again.
if MOCK_WRONG_PAGE=yes bash scripts/deploy-ecs.sh "$TEST_IMAGE"; then
  echo 'Smoke test accepted the wrong page.' >&2
  exit 1
fi
