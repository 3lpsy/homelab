#!/bin/bash
if [[ ! -f .env ]];then
    echo "Requires .env"
    exit
fi

source .env

ENV_DIR=$1
shift

if [[ ! -d $ENV_DIR ]]; then
    echo "Could not find environment folder: $ENV_DIR"
    exit 1
fi

# This script is not intended for multi party use at the same time.
# Just a useful way to backup state in s3 and restore in on a second system later if need be

function encrypt() {
    openssl enc -aes-256-cbc -salt -in $ENV_DIR/$STATE_FILE -out data/$ENV_DIR/$ENCRYPTED_STATE_FILE -pass file:$KEY_FILE
}
function decrypt() {
    openssl enc -aes-256-cbc -d -in data/$ENV_DIR/$ENCRYPTED_STATE_FILE -out $ENV_DIR/$STATE_FILE -pass file:$KEY_FILE
}

function pull() {
    if [[ ! -f data/$ENV_DIR ]]; then mkdir -p data/$ENV_DIR; fi
    echo "Backing up $ENV_DIR/$ENCRYPTED_STATE_FILE to data/$ENV_DIR/$ENCRYPTED_STATE_FILE.backup..."
    cp $ENV_DIR/$ENCRYPTED_STATE_FILE data/$ENV_DIR/$ENCRYPTED_STATE_FILE.backup

    echo "Pulling encrypted state from s3://$S3_BUCKET/$ENV_DIR/$ENCRYPTED_STATE_FILE to data/$ENV_DIR/$ENCRYPTED_STATE_FILE..."
    aws s3 cp s3://$S3_BUCKET/$ENV_DIR/$ENCRYPTED_STATE_FILE data/$ENV_DIR/$ENCRYPTED_STATE_FILE

    echo "Backing up state $ENV_DIR/$STATE_FILE data/$ENV_DIR/$STATE_FILE.backup"
    cp $ENV_DIR/$STATE_FILE data/$ENV_DIR/$STATE_FILE.backup

    echo "Decrypting data/$ENV_DIR/$ENCRYPTED_STATE_FILE to $ENV_DIR/$STATE_FILE"
    decrypt
}
function push(){
    encrypt
    echo "Copying data/$ENV_DIR/$ENCRYPTED_STATE_FILE to s3://$S3_BUCKET/$ENV_DIR/$ENCRYPTED_STATE_FILE"
    aws s3 cp data/$ENV_DIR/$ENCRYPTED_STATE_FILE s3://$S3_BUCKET/$ENV_DIR/$ENCRYPTED_STATE_FILE
}


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
    echo "Downloading and decrypting state file..."
    export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
    pull
    ;;
  "push")
    echo "Encrypting and uploading state file..."
    export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
    push
    ;;
  *)
    terraform -chdir=$ENV_DIR $@
    ;;
esac
