#!/usr/bin/env bash
#
# Secrets injection helper script
# Processes secrets.env file and generates cloud-init write_files directives
#
# See docs/features/dev-env-setup/spec.yaml US-002
# See docs/constraints.yaml C-003, C-008
#
# Usage:
#   ./scripts/inject-secrets.sh <secrets-file>
#
# Input: secrets file in KEY=value format
# Output: cloud-init write_files YAML snippet to stdout

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

if [[ $# -lt 1 ]]; then
    echo "Usage: $SCRIPT_NAME <secrets-file>" >&2
    exit 1
fi

SECRETS_FILE="$1"

if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "Error: Secrets file not found: $SECRETS_FILE" >&2
    exit 1
fi

log_info() {
    echo "# $1" >&2
}

log_error() {
    echo "Error: $1" >&2
}

# Escape special characters for YAML embedding
# Handles quotes, backslashes, colons, and newlines
escape_yaml_string() {
    local str="$1"
    # Escape backslashes first, then quotes
    str="${str//\\/\\\\}"str="${str//\"/\\\"}"
    # Replace newlines with literal \n for cloud-init
    str="${str//$'\n'/\\n}"
    echo "$str"
}

# Read secrets file and generate write_files entries
# Format: KEY=value (one per line, # for comments)
generate_write_files() {
    local secrets_file="$1"
    local _opencode_config="/home/opencode/config/opencode/appconfig.yaml"
    local _gitconfig="/home/opencode/.gitconfig"
    local _ssh_dir="/home/opencode/.ssh"
    
    # Initialize variables for known secrets
    local OPENAI_API_KEY=""
    local OPENCODE_API_KEY=""
    local GIT_USER_NAME=""
    local GIT_USER_EMAIL=""
    local additional_secrets=""
    
    # Parse secrets file
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Capture known secrets
        case "$key" in
            OPENAI_API_KEY)
                OPENAI_API_KEY="$value"
                ;;
            OPENCODE_API_KEY)
                OPENCODE_API_KEY="$value"
                ;;
            GIT_USER_NAME)
                GIT_USER_NAME="$value"
                ;;
            GIT_USER_EMAIL)
                GIT_USER_EMAIL="$value"
                ;;
            *)
                # Store additional secrets for env file
                additional_secrets="${additional_secrets}${key}=${value}"$'\n'
                ;;
        esac
    done < "$secrets_file"
    
    # Generate OpenCode config YAML (C-007)
    # This is written via cloud-init write_files
    echo "write_files:"
    
    # Write OpenCode configuration
    if [[ -n "$OPENAI_API_KEY" ]]; then
        local escaped_key
        escaped_key=$(escape_yaml_string "$OPENAI_API_KEY")
        cat <<EOF
  - path: /home/opencode/.config/opencode/config.yaml
    owner: opencode:opencode
    permissions: '0600'
    content: |
      # OpenCode CLI configuration
      # Generated from secrets.env by launch.sh
      api_key: "${escaped_key}"
EOF
        if [[ -n "$OPENCODE_API_KEY" ]]; then
            local escaped_opencode_key
            escaped_opencode_key=$(escape_yaml_string "$OPENCODE_API_KEY")
            echo "      opencode_api_key: \"${escaped_opencode_key}\""
        fi
    fi
    
    # Write gitconfig (DEV-011)
    if [[ -n "$GIT_USER_NAME" && -n "$GIT_USER_EMAIL" ]]; then
        local escaped_name escaped_email
        escaped_name=$(escape_yaml_string "$GIT_USER_NAME")
        escaped_email=$(escape_yaml_string "$GIT_USER_EMAIL")
        cat <<EOF
  - path: /home/opencode/.gitconfig
    owner: opencode:opencode
    permissions: '0644'
    content: |
      [user]
          name = "${escaped_name}"
          email = "${escaped_email}"
EOF
    fi
    
    # Write any additional secrets as environment file
    if [[ -n "$additional_secrets" ]]; then
        cat <<EOF
  - path: /home/opencode/.config/opencode/secrets.env
    owner: opencode:opencode
    permissions: '0600'
    content: |
EOF
        echo "$additional_secrets" | while read -r line; do
            [[ -z "$line" ]] && continue
            echo "      $line"
        done
    fi
    
    # Write SSH known_hosts for GitHub and GitLab (DEV-010)
    cat <<EOF
  - path: /home/opencode/.ssh/known_hosts
    owner: opencode:opencode
    permissions: '0644'
    content: |
      # GitHub SSH host keys
      github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphrmQRtL5p/ZJlpW2d6Nv8H9k2UE6xZkYr0dFZWms2nUUloop1VBUhOHpN3P5WKzacjPBkSZBdu6sEHe5YTWmP4sJrkzVkWIJTKsPNJrkSHsbNWHYVdqVv/O1BnADLdCqk8UYki1uUqsch6gzqU8r3hncYaBei6KZHgpq8DZ2WYQ6BfT/TF5rFvz1TYyHIsnLsD5ux/RLmDE9oV+le7VK9NTsTvzwD0SC0g24n0pC3W+6K1KII8f8qEB6QV36drRY5e6tI6IifxtwPl+uRer2sKZEY6eImanXhNqPtDAFOkDgCDrl728A2PDLiRDoVWZw5qQfOeQmr2pCM0ZU08YXqem+Ng4c6qdiJVcTsXvqR0r4qyNzwAL7BwzITuvwL36dKv6p5L1TfzH3F3YG8eN6lBE8mV6Ukp1BdeF3yGvK1f1y5MK1m5sXUTfD2ZfFuJVJNjo6Y8W7j/5h4d0nLp4kEKRLTRNvEnGM= github.com
      github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLNoaXlL2Kb5+WG8Y8PzR9VZu7T8I6/TfXzM4V9VZu3Wx9LbqN8X5F2x5TjzAixD7
      # GitLab SSH host keys
      gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bQB2hmpL5W6Nu5DxO5PZ1aO5Piz5TR5B5W5Z5O5Pi5TR5B5
EOF
}

# Validate secrets file format
validate_secrets() {
    local secrets_file="$1"
    local line_num=0
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        # Check for valid KEY=value format
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            log_error "Invalid format at line $line_num: $line"
            log_error "Expected KEY=value format"
            exit 1
        fi
    done < "$secrets_file"
}

# Main execution
main() {
    log_info "Processing secrets from: $SECRETS_FILE"
    validate_secrets "$SECRETS_FILE"
    generate_write_files "$SECRETS_FILE"
    log_info "Successfully generated cloud-init write_files directives" >&2
}

main
