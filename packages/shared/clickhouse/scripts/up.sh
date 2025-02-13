#!/bin/bash
set -eo pipefail

# Load environment variables
[ -f ../../.env ] && source ../../.env

# Check if CLICKHOUSE_URL is configured
if [ -z "${CLICKHOUSE_URL}" ]; then
  echo "Info: CLICKHOUSE_URL not configured, skipping migration."
  exit 0
fi

# Check if golang-migrate is installed
if ! command -v migrate &> /dev/null; then
    echo "Error: golang-migrate is not installed or not in PATH."
    echo "Install via: brew install golang-migrate"
    echo "Or see: https://github.com/golang-migrate/migrate"
    exit 1
fi

# Set default values
export CLICKHOUSE_DB=${CLICKHOUSE_DB:-"default"}
export CLICKHOUSE_CLUSTER_NAME=${CLICKHOUSE_CLUSTER_NAME:-"default"}
TEMP_DIR=$(mktemp -d)

# Template processing function
process_templates() {
  local source_dir=$1
  local target_dir=$TEMP_DIR/$(basename $source_dir)

  mkdir -p "$target_dir"

  find "$source_dir" -name '*.template.sql' | while read -r template; do
    filename=$(basename "$template" .template.sql).sql
    sed -e "s|STORAGE_POLICY_PLACEHOLDER|${CLICKHOUSE_STORAGE_POLICY:+SETTINGS storage_policy = '$CLICKHOUSE_STORAGE_POLICY'}|" \
        "$template" > "$target_dir/$filename"
  done
}

# Cleanup function
cleanup() {
  rm -rf "$TEMP_DIR"
  exit
}
trap cleanup EXIT

# Database URL construction
if [ "$CLICKHOUSE_CLUSTER_ENABLED" == "false" ]; then
  MIGRATION_SOURCE="unclustered"
  process_templates "clickhouse/migrations/unclustered"

  SSL_PARAMS=""
  if [ "$CLICKHOUSE_MIGRATION_SSL" = true ]; then
    SSL_PARAMS="&secure=true&skip_verify=true"
  fi

  DATABASE_URL="${CLICKHOUSE_MIGRATION_URL}?username=${CLICKHOUSE_USER}&password=${CLICKHOUSE_PASSWORD}&database=${CLICKHOUSE_DB}${SSL_PARAMS}&x-multi-statement=true&x-migrations-table-engine=MergeTree"
else
  MIGRATION_SOURCE="clustered"
  process_templates "clickhouse/migrations/clustered"

  SSL_PARAMS=""
  if [ "$CLICKHOUSE_MIGRATION_SSL" = true ]; then
    SSL_PARAMS="&secure=true&skip_verify=true"
  fi

  DATABASE_URL="${CLICKHOUSE_MIGRATION_URL}?username=${CLICKHOUSE_USER}&password=${CLICKHOUSE_PASSWORD}&database=${CLICKHOUSE_DB}${SSL_PARAMS}&x-multi-statement=true&x-cluster-name=${CLICKHOUSE_CLUSTER_NAME}&x-migrations-table-engine=ReplicatedMergeTree"
fi

# Execute migration
migrate -source "file://$TEMP_DIR/$MIGRATION_SOURCE" -database "$DATABASE_URL" up

# Cleanup temporary files
cleanup
