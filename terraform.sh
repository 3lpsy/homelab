#!/bin/bash
if [[ ! -f .env ]];then
    echo "Requires .env"
    exit
fi

source .env

DEPLOYMENT_DIR=$1
shift

if [[ ! -d $DEPLOYMENT_DIR ]]; then
    echo "Could not find environment folder: $DEPLOYMENT_DIR"
    exit 1
fi

# This script is not intended for multi party use at the same time.
# Just a useful way to backup state in s3 and restore in on a second system later if need be

# function encrypt() {
#     echo "Encrypting $DEPLOYMENT_DIR/$STATE_FILE to $ENCRYPTED_STATE_FILE"
#     age -e -R "$AGE_ENCRYPTION_KEY_PATH" -o "$ENCRYPTED_STATE_FILE" "$DEPLOYMENT_DIR/$STATE_FILE"
# }
# function decrypt() {
#     echo "Decrypting $ENCRYPTED_STATE_FILE to restored.$STATE_FILE"
#     age -d -i "$AGE_DECRYPTION_KEY_PATH" -o "restored.$STATE_FILE" "$ENCRYPTED_STATE_FILE"
# }

# function pull() {
#     echo "Pulling encrypted state from s3://$S3_BUCKET/$DEPLOYMENT_DIR/$ENCRYPTED_STATE_FILE to $ENCRYPTED_STATE_FILE..."
#     aws s3 cp s3://$S3_BUCKET/$DEPLOYMENT_DIR/$ENCRYPTED_STATE_FILE $ENCRYPTED_STATE_FILE
# }
# function restore() {
#     pull
#     decrypt
# }
# function backup(){
#     encrypt
#     echo "Copying $ENCRYPTED_STATE_FILE to s3://$S3_BUCKET/$DEPLOYMENT_DIR/$ENCRYPTED_STATE_FILE"
#     aws s3 cp $ENCRYPTED_STATE_FILE  s3://$S3_BUCKET/$DEPLOYMENT_DIR/$ENCRYPTED_STATE_FILE
# }


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
    if [[ "$1" == "init" ]]; then
        echo terraform -chdir=$DEPLOYMENT_DIR init -backend-config="path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate" "${@:2}"
        terraform -chdir=$DEPLOYMENT_DIR init -backend-config="path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate" "${@:2}"
    else
        echo terraform -chdir=$DEPLOYMENT_DIR $@
        terraform -chdir=$DEPLOYMENT_DIR $@
    fi
    ;;
esac
