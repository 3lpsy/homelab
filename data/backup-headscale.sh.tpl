#!/bin/bash
set -e;
# set -x # un-comment to see what's going on when you run the script

# Create a temporary directory and store its name in a variable.
TEMPD=$(mktemp -d)
# Exit if the temp directory wasn't created successfully.
if [ ! -e "$TEMPD" ]; then
    >&2 echo "Failed to create temp directory"
    exit 1
fi

cd $TEMPD

# Variables
FILE_TO_BACKUP="/var/lib/headscale/db.sqlite"
SSH_PUBLIC_KEY="${ssh_pub_key_path}"
S3_BUCKET="s3://${backup_bucket_name}"
S3_FOLDER="$S3_BUCKET/headscale"

# Generate a timestamp for the backup filename
DATE=$(date '+%Y-%m-%d_%H-%M-%S')
BACKUP_FILENAME="db.sqlite.$DATE.age"


# Encrypt the file using 'age' and the SSH public key
age -R "$SSH_PUBLIC_KEY" -o "$BACKUP_FILENAME" "$FILE_TO_BACKUP"

# Upload the encrypted file to the S3 bucket
aws s3 cp "$BACKUP_FILENAME" "$S3_FOLDER/$BACKUP_FILENAME"

# Remove the local encrypted backup file
rm "$BACKUP_FILENAME"


# Make sure the temp directory gets removed on script exit.
trap "exit 1"           HUP INT PIPE QUIT TERM
trap 'rm -rf "$TEMPD"'  EXIT
