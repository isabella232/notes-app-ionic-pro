#!/usr/bin/env bash

# http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Enhance debugging by expanding and showing shell commands
# set -x

# Credit to Stack Overflow questioner Jiarro and answerer Dave Dopson
# http://stackoverflow.com/questions/59895/can-a-bash-script-tell-what-directory-its-stored-in
# http://stackoverflow.com/a/246128/424301
declare DIR
# shellcheck disable=SC2034
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

. "$DIR/../common.sh"

declare COMMIT_MESSAGE
declare S3_CONFIG_BUCKET
declare PACKAGE_NAME
declare BUILD_DIR
declare BUILD_DIR_LATEST
declare WAIT

COMMIT_MESSAGE="${1:?'You must specify the commit message.'}"
S3_CONFIG_BUCKET="${2:?'You must specify the S3 config bucket.'}"
PACKAGE_NAME="${3}"
BUILD_DIR="${4}"
BUILD_DIR_LATEST="${BUILD_DIR}/latest"
WAIT=30

case $(uname -s) in
    Linux)
        PLATFORM="ANDROID"
        UPLOAD_TYPE="ANDROID_APP"
        PACKAGE_EXT="apk"
        mv "${BUILD_DIR}"/android-debug."${PACKAGE_EXT}" "${BUILD_DIR}/${PACKAGE_NAME}.${PACKAGE_EXT}"
    ;;

    Darwin)
        PLATFORM="IOS"
        UPLOAD_TYPE="IOS_APP"
        PACKAGE_EXT="ipa"
    ;;

    *)
        echo "Unknown OS"
        exit 1
    ;;
esac

config_dir=$(mktemp -d)
# Get our configs from S3
aws s3 cp s3://"${S3_CONFIG_BUCKET}"/"${PLATFORM,,}"/device-pool.json "${config_dir}"/"${PLATFORM,,}"/device-pool.json
aws s3 cp s3://"${S3_CONFIG_BUCKET}"/tests/BUILTIN_EXPLORER.jinja2 "${config_dir}"/tests/BUILTIN_EXPLORER.jinja2

# Create project
project_arn=$(aws devicefarm create-project \
    --name "${PACKAGE_NAME}.${PACKAGE_EXT}" \
    --query 'project.arn' \
    --output text \
    --region us-west-2)

# Create device pool
device_pool_arn=$(aws devicefarm create-device-pool \
    --project-arn "${project_arn}" \
    --name "${PLATFORM,,}"-devices \
    --rules file://"${config_dir}"/"${PLATFORM,,}"/device-pool.json \
    --query 'devicePool.arn' \
    --output text \
    --region us-west-2)

cd "${BUILD_DIR}"

# Create an upload
IFS=$' ' read -ra upload_meta <<< $(aws devicefarm create-upload \
    --name "${PACKAGE_NAME}.${PACKAGE_EXT}" \
    --type "${UPLOAD_TYPE}" \
    --project-arn "${project_arn}" \
    --query 'upload.[url,arn]' \
    --output text \
    --region us-west-2)
upload_url="${upload_meta[0]}"
upload_arn="${upload_meta[1]}"

curl -T "${BUILD_DIR}/${PACKAGE_NAME}.${PACKAGE_EXT}" "${upload_url}"

# Schedule a run
echo "{\"upload_arn\":\"$upload_arn\"}" > "${config_dir}"/upload_arn.json
test_file=$(jinja2 \
    "${config_dir}"/tests/BUILTIN_EXPLORER.jinja2 \
    "${config_dir}"/upload_arn.json \
    --format=json)

# We trim the commit message down to 256 characters since that's the character
# constraint for the `name` option.
run_arn=$(aws devicefarm schedule-run \
        --project-arn "${project_arn}" \
        --app-arn "${upload_arn}" \
        --device-pool-arn "${device_pool_arn}" \
        --name "${COMMIT_MESSAGE:0:256}" \
        --test "$test_file" \
        --query 'run.arn' \
        --output text \
        --region us-west-2)

# Get info on a run
get_run() {
    local run_arn
    run_arn="${1}"

    aws devicefarm get-run \
        --arn "$run_arn" \
        --query 'run.[status,arn,result,counters]' \
        --output json \
        --region us-west-2
}
declare -a get_run_output
get_run_output=$(get_run "$run_arn")
run_status=$(echo "$get_run_output" | jq -r '.[0]')
run_result=$(echo "$get_run_output" | jq -r '.[2]')
run_overview=$(echo "$get_run_output" | jq -r '.[3]')

echo "########## AWS Device Farm run started"
echo ""
progress=""
output=""
# See: https://docs.aws.amazon.com/cli/latest/reference/devicefarm/get-run.html#output
while [[ $run_status != "COMPLETED" ]]; do
    if [[ -n "$output" ]]; then
        sleep "$WAIT"
    fi
    progress="${progress}."
    get_run_output=$(get_run "$run_arn")
    run_status=$(echo "$get_run_output" | jq -r '.[0]')
    run_result=$(echo "$get_run_output" | jq -r '.[2]')
    run_overview=$(echo "$get_run_output" | jq -r '.[3]')

    output=$(printf "%s\n%s" "$progress" "$run_overview")
    echo "$output"
done
echo "########## Test runs done with result \"$run_result\""

results=$(aws devicefarm list-jobs \
    --arn "$run_arn" \
    --output json \
    --region us-west-2)

header="Name|Model|Form|Operating System|Resolution|RAM/CPU|Result|Duration\n"
res_length=$(echo "$results" | jq '.jobs | length')
content=""
counter=0
while [ $counter -lt "$res_length" ]; do
    res_device=$(echo "$results" | jq -r ".jobs[$counter].device | {
        # The device's display name.
        name,
        # The device's model ID.
        modelId,
        # The device's form factor.
        formFactor,
        # The device's platform and the device's operating system type.
        \"os\": \"\(.platform) \(.os)\",
        # The resolution of the device, expressed in pixels.
        \"resolution\": \"\(.resolution.width)x\(.resolution.height)\",
        # The device's total memory size converted bytes to GB and
        # the clock speed of the device's CPU converted from Hz to GHz.
        \"memory\": \"\(.memory / 1000 / 1000 / 1000|tostring + \"GB\")/\(.cpu[\"clock\"] * .10 + 0.5|floor/100.0|tostring + \"GHz\")\"
    } | join(\"|\")")
    # The job's result.
    res_root=$(echo "$results" | jq -r ".jobs[$counter].result")
    # The total minutes used by the resource to run tests.
    res_device_minutes=$(echo "$results" | jq -r ".jobs[$counter].deviceMinutes.total|tostring + \" mins\"")

    content="${content}${res_device}|${res_root}|${res_device_minutes}\n"
    let counter=counter+1
done

echo -e "${header}${content}" | column -c80 -s"|" -t

# Fail the build if it doesn't pass.
if [[ $run_result == "ERRORED" ]] || [[ $run_result == "FAILED" ]]; then
    echo "Terminating build"
    exit 1
fi

# Move the built file to a dir on its own since the entire dir will be uploaded
# to the S3 bucket.
rm -rf "${BUILD_DIR_LATEST}"
mkdir -p "${BUILD_DIR_LATEST}"
mv \
    "${BUILD_DIR}/${PACKAGE_NAME}.${PACKAGE_EXT}" \
    "${BUILD_DIR_LATEST}/${PACKAGE_NAME}.${PACKAGE_EXT}"

# Download test artifacts. S3 will upload it in the `deploy` step.
COUNTER=0
for type in FILE SCREENSHOT; do
    while read i; do
        artifact_url=$(echo "$i" | jq -r '.url')
        artifact_type=$(echo "$i" | jq -r '.type')
        artifact_ext=$(echo "$i" | jq -r '.extension')
        artifact_name=$(echo "$i" | jq -r '.name')
        artifact_filename="${artifact_name}-${RANDOM}.${artifact_ext}"

        mkdir -p "${BUILD_DIR_LATEST}/${PACKAGE_NAME}/${artifact_type}"
        set +e
        try_with_backoff curl -o \
            "${BUILD_DIR_LATEST}/${PACKAGE_NAME}/${artifact_type}/${artifact_filename}" \
            "${artifact_url}"
        set -e
        let COUNTER=COUNTER+1
    done < <(aws devicefarm list-artifacts \
        --arn "$run_arn" \
        --type "$type" \
        --output json \
        --region us-west-2 \
        | jq -cr '.[] | .[] | {url: .url, type: .type, extension: .extension, name: .name}')
done

echo "$results" > "${BUILD_DIR_LATEST}/${PACKAGE_NAME}/list-jobs.json"

aws devicefarm delete-project \
    --arn "${project_arn}" \
    --output json \
    --region us-west-2
