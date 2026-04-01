#!/bin/bash
set -euo pipefail
trap 'exit 130' INT

if [[ ! -f .env ]];then
    echo "Requires .env"
    exit
fi

source .env
if [[ ! -d "$STATE_DIRS" ]]; then
    echo "Could not find state folder: $STATE_DIRS"
fi
DEPLOYMENTS="homelab cluster vault vault-conf nextcloud monitoring monitoring-conf"
DEPLOYMENT_DIR=$1

shift

if [[ "$DEPLOYMENT_DIR" != "all" && ! -d $DEPLOYMENT_DIR ]]; then
    echo "Could not find environment folder: $DEPLOYMENT_DIR"
    exit 1
fi

# This script is not intended for multi party use at the same time.
# Just a useful way to backup state in s3 and restore in on a second system later if need be

function encrypt() {
    for dep in $DEPLOYMENTS; do
        local state_file="$STATE_DIRS/$dep/terraform.tfstate"
        if [ ! -f "$state_file" ]; then echo "Skipping $dep: $state_file not found"; continue; fi
        echo "age -e -R $AGE_ENCRYPTION_KEY_PATH -o ${state_file}.age $state_file"
        age -e -R "$AGE_ENCRYPTION_KEY_PATH" -o "${state_file}.age" "$state_file"
    done
}

# function decrypt() {
#     for dep in $DEPLOYMENTS; do
#         local encrypted="$STATE_DIRS/$dep/terraform.tfstate.age"
#         local state_file="$STATE_DIRS/$dep/terraform.tfstate"
#         if [ ! -f "$encrypted" ]; then echo "Skipping $dep: $encrypted not found"; continue; fi
#         if [ -f "$state_file" ]; then
#             local backup_file="${state_file}.$(date +%s).backup"
#             echo "mv $state_file $backup_file"
#             mv "$state_file" "$backup_file"
#         fi
#         echo "age -d -i $AGE_DECRYPTION_KEY_PATH -o $state_file $encrypted"
#         age -d -i "$AGE_DECRYPTION_KEY_PATH" -o "$state_file" "$encrypted"
#     done
# }

# function pull() {
#     for dep in $DEPLOYMENTS; do
#         echo "aws s3 cp s3://$S3_BUCKET/$dep/terraform.tfstate.age $STATE_DIRS/$dep/terraform.tfstate.age"
#         aws s3 cp "s3://$S3_BUCKET/$dep/terraform.tfstate.age" "$STATE_DIRS/$dep/terraform.tfstate.age"
#     done
# }

# function restore() {
#     pull
#     decrypt
# }

function backup() {
    encrypt
    for dep in $DEPLOYMENTS; do
        local encrypted="$STATE_DIRS/$dep/terraform.tfstate.age"
        if [ ! -f "$encrypted" ]; then echo "Skipping $dep: $encrypted not found"; continue; fi
        echo "aws s3 cp $encrypted s3://$S3_BUCKET/$dep/terraform.tfstate.age"
        aws s3 cp "$encrypted" "s3://$S3_BUCKET/$dep/terraform.tfstate.age"
    done
}


if [[ "$1" == "changes" ]]; then
  for dep in $DEPLOYMENTS; do
    echo "Checking $dep for changes...."
    output=$(terraform -chdir=$dep plan -detailed-exitcode 2>&1)
    exit_code=$?
    if [ $exit_code -eq 2 ]; then
      echo "=== $dep ==="
      echo "$output" | grep -A 2 '# \|Plan:'
      echo ""
    elif [ $exit_code -ne 0 ]; then
      echo "=== $dep === ERROR"
      echo "$output"
      echo ""
    fi
  done
  exit 0
fi

case $1 in
  "encrypt")
    echo "Encrypting locally..."
    encrypt
  ;;
  "decrypt")
    echo "Decrypting locally..."
    decrypt
  ;;
  "pull")
    export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
    pull
    ;;
  "restore")
    export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
    restore
    ;;
  "backup")
    export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
    backup
    ;;
  *)
    ENVS="$HOME/Playground/private/envs/homelab"
    if [[ "$DEPLOYMENT_DIR" == "all" ]]; then
        for dep in $DEPLOYMENTS; do
            echo "=== $dep ==="
            echo terraform -chdir=$dep $@
            terraform -chdir=$dep $@
            echo ""
        done
    elif [[ "$1" == "init" ]]; then
        echo terraform -chdir=$DEPLOYMENT_DIR init -backend-config="path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate" "${@:2}"
        terraform -chdir=$DEPLOYMENT_DIR init -backend-config="path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate" "${@:2}"
    else
        echo terraform -chdir=$DEPLOYMENT_DIR $@
        terraform -chdir=$DEPLOYMENT_DIR $@
    fi
    ;;
esac
