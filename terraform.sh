#!/bin/bash
if [[ ! -f .env ]];then
    echo "Requires .env"
    exit
fi

source .env
# This script is not intended for multi party use at the same time.
# Just a useful way to backup state in s3 and restore in on a second system later if need be

function encrypt() {
    openssl enc -aes-256-cbc -salt -in $STATE_FILE -out $ENCRYPTED_STATE_FILE -pass file:$KEY_FILE
}
function decrypt() {
    openssl enc -aes-256-cbc -d -in $ENCRYPTED_STATE_FILE -out $STATE_FILE -pass file:$KEY_FILE
}
function pull() {
    echo "Backing up $ENCRYPTED_STATE_FILE to $ENCRYPTED_STATE_FILE.backup..."
    cp $ENCRYPTED_STATE_FILE $ENCRYPTED_STATE_FILE.backup
    echo "Pulling encrypted state from s3..."
    aws s3 cp s3://$S3_BUCKET/$ENCRYPTED_STATE_FILE $ENCRYPTED_STATE_FILE
    echo "Backing up state  $STATE_FILE $STATE_FILE.backup2"
    cp $STATE_FILE $STATE_FILE.backup2
    echo "Decrypting $ENCRYPTED_STATE_FILE to $STATE_FILE"
    decrypt
}
function push(){
    encrypt
    aws s3 cp $ENCRYPTED_STATE_FILE s3://$S3_BUCKET/$ENCRYPTED_STATE_FILE
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
    terraform $@
    ;;
esac
