#!/bin/bash -eu

# OS detection

case "$(uname -s)" in
Darwin)
  export TOOL_OS="darwin"
  ;;
Linux)
  export TOOL_OS="linux"
  ;;
esac

# Utility function for a fatal error.
die() {
  echo "$0:" "$@" 1>&2
  exit 1
}

# Utility function to log a command before running it.
logged() {
  echo "$0:" "$@" 1>&2
  "$@"
}

# Utility function to make a duplo API call with curl, and output JSON.
duplo_api() {
    local path="${1:-}"
    [ $# -eq 0 ] || shift

    [ -z "${path:-}" ] && die "internal error: no API path was given"
    [ -z "${DUPLO_HOST:-}" ] && die "internal error: duplo_host environment variable must be set"
    [ -z "${DUPLO_TOKEN:-}" ] && die "internal error: duplo_token environment variable must be set"

    curl -Ssf -H 'Content-type: application/json' -H "Authorization: Bearer $DUPLO_TOKEN" "$@" "${DUPLO_HOST}/${path}"
}

duplo_api_post() {
    local path="${1:-}"
    [ $# -eq 0 ] || shift

    [ -z "${path:-}" ] && die "internal error: no API path was given"
    [ -z "${DUPLO_HOST:-}" ] && die "internal error: duplo_host environment variable must be set"
    [ -z "${DUPLO_TOKEN:-}" ] && die "internal error: duplo_token environment variable must be set"

    curl -Ssf -H 'Content-type: application/json' -X POST -H "Authorization: Bearer $DUPLO_TOKEN" "$@"  "${DUPLO_HOST}/${path}" --data-binary "@sd_dev.json"
}


# Utility function to set up AWS credentials before running a command.
with_aws() {
  local duplo_tenant_id="${DUPLO_TENANT_ID:-}"
  [ -z "$duplo_tenant_id" ] && duplo_tenant_id="${duplo_default_tenant_id:-}"

  # Run the command in the configured way.
  case "${AWS_RUNNER:-duplo-admin}" in
  env)
    [ -z "${profile:-}" ] && die "internal error: no AWS profile selected"
    env AWS_PROFILE="$profile" AWS_SDK_LOAD_CONFIG=1 "$@"
    ;;
  duplo-admin)
    # Get just-in-time AWS credentials from Duplo and use them to execute the command.
    # shellcheck disable=SC2046     # NOTE: we want word splitting
    env -u AWS_PROFILE AWS_SDK_LOAD_CONFIG=1 $( duplo_api adminproxy/GetJITAwsConsoleAccessUrl |
            jq -r '{AWS_ACCESS_KEY_ID: .AccessKeyId, AWS_SECRET_ACCESS_KEY: .SecretAccessKey, AWS_REGION: .Region, AWS_DEFAULT_REGION: .Region, AWS_SESSION_TOKEN: .SessionToken} | to_entries | map("\(.key)=\(.value)") | .[]'
        ) "$@"
    ;;
  duplo)
    # Get just-in-time AWS credentials from Duplo and use them to execute the command.
    # shellcheck disable=SC2046     # NOTE: we want word splitting
    env -u AWS_PROFILE AWS_SDK_LOAD_CONFIG=1 $( duplo_api "subscriptions/${duplo_tenant_id}/GetAwsConsoleTokenUrl" |
            jq -r '{AWS_ACCESS_KEY_ID: .AccessKeyId, AWS_SECRET_ACCESS_KEY: .SecretAccessKey, AWS_REGION: .Region, AWS_DEFAULT_REGION: .Region, AWS_SESSION_TOKEN: .SessionToken} | to_entries | map("\(.key)=\(.value)") | .[]'
        ) "$@"
    ;;
  esac
}

# Utility function to run Terraform with AWS credentials.
# Also logs the command.
tf() {
  logged with_aws terraform "$@"
}

# Utility function to run "terraform init" with proper arguments, and clean state.
tf_init() {
  rm -f .terraform/environment .terraform/terraform.tfstate
  tf init "$@"
}

get_tag(){
  # case "${CIRCLE_BRANCH:-na}" in
	# 	master)
	# 	post_fix=""
	# 	;;
	# 	dev)
	# 	post_fix="-dev-${CIRCLE_BUILD_NUM}"
	# 	;;
	# 	duplo)
	# 	post_fix="-rc-${CIRCLE_BUILD_NUM}"
	# 	;;
	# esac
	echo "$@"
}

get_docker_tag(){
  echo "${DOCKER_REPO}/${DOCKER_IMAGE_NAME}:$(get_tag $@)"
}

push_container(){
  tag=$(get_docker_tag $@)
  with_aws aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin $DOCKER_REPO
  with_aws docker push $tag
}

update_service(){
  tag=$(get_docker_tag $@)
  # case "${CIRCLE_BRANCH:-na}" in
	# 	master)
	# 	tenant="${PROD_TENANT_ID}"
	# 	;;
	# 	dev)
	# 	tenant="${DEV_TENANT_ID}"
	# 	;;
	# 	release/@tag)
	# 	tenant="${QA_TENANT_ID}"
	# 	;;
	# esac
  tenant="${DEV_TENANT_ID}"
  echo "Tenant Id ${tenant}"
  data="{\"Name\": \"${SERVICE_NAME}\",\"Image\":\"${tag}\"}"
   echo "Tenant Id ${data}"
  curl -Ssf -H 'Content-type: application/json' -X POST -H "Authorization: Bearer $DUPLO_TOKEN" -X POST --data "${data}" "${DUPLO_HOST}/subscriptions/${tenant}/ReplicationControllerChange" 
}