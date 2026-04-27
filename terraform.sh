#!/bin/bash
set -euo pipefail

# Minimum size of a healthy terraform.tfstate. Anything smaller is almost
# certainly a truncation / partial write and must not be backed up or encrypted.
MIN_STATE_BYTES=${MIN_STATE_BYTES:-1024}

# How many *pre-command* local snapshots to keep per deployment before pruning.
# S3 history is separate (see tf_backup()).
SNAPSHOT_KEEP=${SNAPSHOT_KEEP:-20}

# Let SIGINT propagate naturally to the foreground terraform child; terraform
# has its own SIGINT handler that performs an atomic state save. The previous
# `trap 'exit 130' INT` could detach the wrapper while terraform was mid-write.
trap - INT

# ---- selftest (safe to run at any time) -----------------------------------

selftest() {
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '$tmpdir'" RETURN

    # Empty file: must fail
    : > "$tmpdir/empty.tfstate"
    if sanity_check_state "$tmpdir/empty.tfstate" 2>/dev/null; then
        echo "selftest FAIL: empty state passed sanity_check_state"; return 1
    fi

    # Small file: must fail
    head -c 200 /dev/urandom > "$tmpdir/small.tfstate"
    if sanity_check_state "$tmpdir/small.tfstate" 2>/dev/null; then
        echo "selftest FAIL: 200-byte state passed sanity_check_state"; return 1
    fi

    # Big non-tfstate: must fail (missing terraform_version)
    head -c 4096 /dev/urandom > "$tmpdir/bigrandom.tfstate"
    if sanity_check_state "$tmpdir/bigrandom.tfstate" 2>/dev/null; then
        echo "selftest FAIL: random 4k state passed sanity_check_state"; return 1
    fi

    # Fake-valid state: must pass
    python3 - "$tmpdir/good.tfstate" <<'PY'
import json, sys
out = {"version": 4, "terraform_version": "1.6.0", "serial": 1,
       "lineage": "x", "outputs": {}, "resources": [{"k": "v"}]*50}
# Pad out to >= MIN_STATE_BYTES with a comment-like extra field
out["_pad"] = "x" * 4000
open(sys.argv[1], "w").write(json.dumps(out))
PY
    if ! sanity_check_state "$tmpdir/good.tfstate"; then
        echo "selftest FAIL: good state rejected"; return 1
    fi

    # rotate_age: non-existent target is a no-op
    rotate_age "$tmpdir/does-not-exist.age"

    # rotate_age: existing target gets moved aside
    echo "old" > "$tmpdir/rot.age"
    rotate_age "$tmpdir/rot.age"
    if [[ -f "$tmpdir/rot.age" ]]; then
        echo "selftest FAIL: rot.age still present after rotation"; return 1
    fi
    if ! ls "$tmpdir"/rot.age.* >/dev/null 2>&1; then
        echo "selftest FAIL: rotated file not created"; return 1
    fi

    echo "selftest OK"
}

# ---- shared helpers -------------------------------------------------------

ts() { date +%Y%m%d-%H%M%S; }

sanity_check_state() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        echo "ERROR: state file missing: $f" >&2
        return 1
    fi
    local size
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
    if (( size < MIN_STATE_BYTES )); then
        echo "ERROR: state $f is only ${size} bytes (min ${MIN_STATE_BYTES}) — refusing" >&2
        return 1
    fi
    if ! grep -q '"terraform_version"' "$f"; then
        echo "ERROR: state $f missing terraform_version — refusing" >&2
        return 1
    fi
}

rotate_age() {
    # Move an existing .age backup aside with a timestamp suffix before we
    # overwrite it. Never clobber the only copy of a known-good backup.
    local path="$1"
    if [[ -f "$path" ]]; then
        local rotated="${path}.$(ts)"
        echo "Rotating existing backup: $path -> $rotated"
        mv "$path" "$rotated"
    fi
}

prune_snapshots() {
    # Keep the most recent $SNAPSHOT_KEEP local pre-command snapshots per dep.
    # Runs after each fresh snapshot is written.
    local dep="$1"
    local dir="$STATE_DIRS/$dep"
    # shellcheck disable=SC2012
    ls -1t "$dir"/terraform.tfstate.pre-*.age 2>/dev/null \
        | awk -v keep="$SNAPSHOT_KEEP" 'NR>keep' \
        | xargs -r rm -f
}

snapshot_state() {
    # Pre-command encrypted snapshot, local only (S3 is tf_backup()'s job).
    # Fails loudly — caller should abort the command if snapshot can't happen.
    # First apply for a brand-new deployment is the one exception: no state
    # file yet AND no terraform.tfstate.backup means there's literally nothing
    # to lose, so skip with a visible note instead of aborting.
    local dep="$1"
    local label="$2"
    local state_file="$STATE_DIRS/$dep/terraform.tfstate"
    if [[ ! -f "$state_file" && ! -f "${state_file}.backup" ]]; then
        echo "Skip snapshot: no state at $state_file (first apply for $dep — nothing to lose)"
        return 0
    fi
    sanity_check_state "$state_file" || return 1
    local out="${state_file}.${label}.$(ts).age"
    echo "Snapshot -> $out"
    age -e -R "$AGE_ENCRYPTION_KEY_PATH" -o "$out" "$state_file"
    prune_snapshots "$dep"
}

acquire_lock() {
    # Per-deployment flock. Held for the lifetime of this shell.
    # Exits non-zero if another terraform.sh process already holds it.
    local dep="$1"
    local lockfile="$STATE_DIRS/$dep/.tf.lock"
    mkdir -p "$(dirname "$lockfile")"
    exec {LOCK_FD}>"$lockfile"
    if ! flock -n -x "$LOCK_FD"; then
        echo "ERROR: another terraform.sh process holds the lock on $lockfile" >&2
        return 1
    fi
}

# Commands that mutate state. snapshot + lock gate only these.
needs_guard() {
    case "${1:-}" in
        apply|destroy|refresh|import|state|taint|untaint|replace) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- argv parsing ---------------------------------------------------------

# selftest runs on the functions alone; no .env / AWS / age-key required.
if [[ "${1:-}" == "selftest" ]]; then
    selftest
    exit $?
fi

if [[ ! -f .env ]]; then
    echo "Requires .env"
    exit 1
fi

source .env

if [[ ! -d "${STATE_DIRS:-}" ]]; then
    echo "Could not find state folder: ${STATE_DIRS:-<unset>}"
    exit 1
fi

DEPLOYMENTS="homelab cluster vault vault-conf nextcloud monitoring monitoring-conf backup"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <deployment|all|subcommand> [args...]"
    echo "Subcommands: changes | encrypt | decrypt | pull | restore | tf-backup | selftest"
    exit 1
fi

DEPLOYMENT_DIR=$1
shift

if [[ "$DEPLOYMENT_DIR" != "all" \
   && "$DEPLOYMENT_DIR" != "changes" \
   && "$DEPLOYMENT_DIR" != "encrypt" \
   && "$DEPLOYMENT_DIR" != "decrypt" \
   && "$DEPLOYMENT_DIR" != "pull" \
   && "$DEPLOYMENT_DIR" != "restore" \
   && "$DEPLOYMENT_DIR" != "tf-backup" \
   && ! -d "$DEPLOYMENT_DIR" ]]; then
    echo "Could not find environment folder: $DEPLOYMENT_DIR"
    exit 1
fi

# ---- state-backup / restore functions -------------------------------------
# `tf_backup` ships encrypted state to S3. Renamed from `backup` to avoid a
# subcommand collision with the `backup/` deployment directory (Velero).

function encrypt() {
    for dep in $DEPLOYMENTS; do
        local state_file="$STATE_DIRS/$dep/terraform.tfstate"
        local age_file="${state_file}.age"
        if [[ ! -f "$state_file" ]]; then
            echo "Skipping $dep: $state_file not found"
            continue
        fi
        if ! sanity_check_state "$state_file"; then
            echo "Skipping $dep: refusing to encrypt unhealthy state"
            continue
        fi
        rotate_age "$age_file"
        echo "age -e -R $AGE_ENCRYPTION_KEY_PATH -o $age_file $state_file"
        age -e -R "$AGE_ENCRYPTION_KEY_PATH" -o "$age_file" "$state_file"
    done
}

function decrypt() {
    for dep in $DEPLOYMENTS; do
        local encrypted="$STATE_DIRS/$dep/terraform.tfstate.age"
        local state_file="$STATE_DIRS/$dep/terraform.tfstate"
        if [[ ! -f "$encrypted" ]]; then
            echo "Skipping $dep: $encrypted not found"
            continue
        fi
        if [[ -f "$state_file" ]]; then
            local preserved="${state_file}.pre-decrypt.$(ts)"
            echo "Preserving existing state: $state_file -> $preserved"
            mv "$state_file" "$preserved"
        fi
        echo "age -d -i $AGE_DECRYPTION_KEY_PATH -o $state_file $encrypted"
        age -d -i "$AGE_DECRYPTION_KEY_PATH" -o "$state_file" "$encrypted"
        if ! sanity_check_state "$state_file"; then
            echo "WARNING: decrypted $state_file fails sanity check"
        fi
    done
}

function pull() {
    for dep in $DEPLOYMENTS; do
        local remote="s3://$S3_BUCKET/$dep/terraform.tfstate.age"
        local local_path="$STATE_DIRS/$dep/terraform.tfstate.age"
        if [[ -f "$local_path" ]]; then
            mv "$local_path" "${local_path}.pre-pull.$(ts)"
        fi
        echo "aws s3 cp $remote $local_path"
        aws s3 cp "$remote" "$local_path"
    done
}

function restore() {
    pull
    decrypt
}

function tf_backup() {
    # Re-encrypt from live state (with sanity checks) then push to both a
    # rolling S3 key and a timestamped history key, so S3 retains a versioned
    # tail even without bucket versioning enabled.
    encrypt
    local stamp
    stamp=$(ts)
    for dep in $DEPLOYMENTS; do
        local encrypted="$STATE_DIRS/$dep/terraform.tfstate.age"
        if [[ ! -f "$encrypted" ]]; then
            echo "Skipping $dep: $encrypted not found"
            continue
        fi
        local rolling="s3://$S3_BUCKET/$dep/terraform.tfstate.age"
        local history="s3://$S3_BUCKET/$dep/history/terraform.tfstate.${stamp}.age"
        echo "aws s3 cp $encrypted $rolling"
        aws s3 cp "$encrypted" "$rolling"
        echo "aws s3 cp $encrypted $history"
        aws s3 cp "$encrypted" "$history"
    done
}

# ---- dispatch -------------------------------------------------------------

if [[ "$DEPLOYMENT_DIR" == "changes" ]]; then
    for dep in $DEPLOYMENTS; do
        echo "Checking $dep for changes..."
        local_exit=0
        output=$(terraform -chdir="$dep" plan -detailed-exitcode 2>&1) || local_exit=$?
        if [[ $local_exit -eq 2 ]]; then
            echo "=== $dep ==="
            echo "$output" | grep -A 2 '# \|Plan:'
            echo ""
        elif [[ $local_exit -ne 0 ]]; then
            echo "=== $dep === ERROR (exit $local_exit)"
            echo "$output"
            echo ""
        fi
    done
    exit 0
fi

case "$DEPLOYMENT_DIR" in
    "encrypt")
        echo "Encrypting locally..."
        encrypt
        exit 0
        ;;
    "decrypt")
        echo "Decrypting locally..."
        decrypt
        exit 0
        ;;
    "pull")
        export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
        export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
        pull
        exit 0
        ;;
    "restore")
        export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
        export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
        restore
        exit 0
        ;;
    "tf-backup")
        export AWS_ACCESS_KEY_ID=$TF_VAR_aws_access_key
        export AWS_SECRET_ACCESS_KEY=$TF_VAR_aws_secret_key
        tf_backup
        exit 0
        ;;
esac

ENVS="$HOME/Playground/private/envs/homelab"

if [[ "$DEPLOYMENT_DIR" == "all" ]]; then
    for dep in $DEPLOYMENTS; do
        echo "=== $dep ==="
        if needs_guard "${1:-}"; then
            if ! snapshot_state "$dep" "pre-$1"; then
                echo "ABORT: could not snapshot $dep before '$1'"
                exit 1
            fi
            acquire_lock "$dep" || exit 1
        fi
        echo "terraform -chdir=$dep $*"
        terraform -chdir="$dep" "$@"
        # Release the lock between deployments so next dep can grab it cleanly.
        if [[ -n "${LOCK_FD:-}" ]]; then
            flock -u "$LOCK_FD" 2>/dev/null || true
            exec {LOCK_FD}>&-
            unset LOCK_FD
        fi
        echo ""
    done
elif [[ "${1:-}" == "init" ]]; then
    echo "terraform -chdir=$DEPLOYMENT_DIR init -backend-config=path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate ${*:2}"
    terraform -chdir="$DEPLOYMENT_DIR" init \
        -backend-config="path=$ENVS/$DEPLOYMENT_DIR/terraform.tfstate" "${@:2}"
else
    if needs_guard "${1:-}"; then
        if ! snapshot_state "$DEPLOYMENT_DIR" "pre-$1"; then
            echo "ABORT: could not snapshot $DEPLOYMENT_DIR before '$1'"
            exit 1
        fi
        acquire_lock "$DEPLOYMENT_DIR" || exit 1
    fi
    echo "terraform -chdir=$DEPLOYMENT_DIR $*"
    terraform -chdir="$DEPLOYMENT_DIR" "$@"
fi
