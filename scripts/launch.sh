#!/usr/bin/env bash
#
# Launch script for secure dev environment
# Orchestrates VM creation with Multipass and cloud-init
#
# See docs/features/dev-env-setup/spec.yaml US-001, US-002, US-003, US-004, US-005, US-006
# See docs/constraints.yaml C-001 through C-016
#
# Usage:
#   ./scripts/launch.sh --repo <git-url> --secrets <secrets-file>
#   ./scripts/launch.sh --dry-run --repo <git-url> --secrets <secrets-file>

set -euo pipefail

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default values
VM_NAME=""
REPO_URL=""
SECRETS_FILE=""
DRY_RUN=false
CLOUD_INIT_DIR="${PROJECT_ROOT}/cloud-init"
# shellcheck disable=SC2034  # TEMPLATES_DIR used by inject-secrets.sh
TEMPLATES_DIR="${PROJECT_ROOT}/templates"
OPENCODE_VERSION="latest"
OPENCODE_CHECKSUM=""  # Will be set to verify download integrity
VM_IMAGE="24.04"

# OpenCode CLI download URL (official source)
OPENCODE_BASE_URL="https://github.com/anomalyco/opencode/releases"

print_usage() {
    cat <<'EOF'
Usage: ./scripts/launch.sh [OPTIONS]

Required:
  --repo <url>           Git repository URL to clone inside VM
  --secrets <file>       Path to secrets.env file with API keys and git config

Optional:
  --name <name>          VM name (default: auto-generated from repo)
  --dry-run              Show configuration without creating VM
  --help                 Show this help message

Examples:
  ./scripts/launch.sh --repo https://github.com/user/repo.git --secrets secrets.env
  ./scripts/launch.sh --repo git@github.com:user/repo.git --secrets secrets.env --name my-project
  ./scripts/launch.sh --dry-run --repo https://github.com/user/repo.git --secrets secrets.env

Secrets file format (secrets.env):
  OPENAI_API_KEY=sk-...
  OPENCODE_API_KEY=...  (optional)
  GIT_USER_NAME=Your Name
  GIT_USER_EMAIL=your@email.com

Security notes:
  - Secrets are injected via cloud-init, not environment variables
  - SSH access is disabled; use 'multipass shell <name>' instead
  - Network egress is restricted via UFW (ports 443, 22, 53 only)
EOF
}

log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warn() {
    echo "[WARN] $1" >&2
}

# Generate a default VM name from the repository URL
generate_vm_name() {
    local url="$1"
    local name
    # Extract repo name from URL
    name=$(basename "$url" .git 2>/dev/null || basename "$url")
    # Sanitize for VM name
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')
    # Add timestamp suffix for uniqueness
    echo "${name:-dev}-$(date +%Y%m%d%H%M%S)"
}

# Validate secrets file exists and has proper format
validate_secrets_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "Secrets file not found: $file"
        log_info "Create a secrets.env file with the following format:"
        log_info "  OPENAI_API_KEY=sk-..."
        log_info "  GIT_USER_NAME=Your Name"
        log_info "  GIT_USER_EMAIL=your@email.com"
        exit 1
    fi

    if [[ ! -r "$file" ]]; then
        log_error "Cannot read secrets file: $file"
        exit 1
    fi

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Check for valid KEY=value format
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            log_error "Invalid format at line $line_num in $file"
            log_error "Expected KEY=value, got: $line"
            exit 1
        fi
    done < "$file"

    # Check for required keys
    if ! grep -q "^OPENAI_API_KEY=" "$file" 2>/dev/null; then
        log_error "OPENAI_API_KEY is required in secrets file"
        exit 1
    fi
    if ! grep -q "^GIT_USER_NAME=" "$file" 2>/dev/null; then
        log_error "GIT_USER_NAME is required in secrets file"
        exit 1
    fi
    if ! grep -q "^GIT_USER_EMAIL=" "$file" 2>/dev/null; then
        log_error "GIT_USER_EMAIL is required in secrets file"
        exit 1
    fi

    log_info "Secrets file validated: $file"
}

# Extract a YAML list section from a cloud-init file.
# Reads all lines belonging to the given top-level key (e.g., runcmd, packages).
# Outputs the list items without the key header.
extract_yaml_list() {
    local file="$1"
    local key="$2"
    local in_section=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^${key}: ]]; then
            in_section=true
            continue
        fi
        # A non-indented, non-comment, non-blank line ends the section
        if $in_section && [[ "$line" =~ ^[^[:space:]#] ]]; then
            break
        fi
        if $in_section; then
            echo "$line"
        fi
    done < "$file"
}

# Extract non-list YAML sections (everything except known list keys).
# This captures scalar keys like package_update, package_upgrade and
# mapping keys like users.
extract_yaml_scalars_and_mappings() {
    local file="$1"
    local skip_keys=("runcmd" "packages" "write_files" "bootcmd")
    local in_list=false
    local current_key=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip cloud-config header and comments at the top
        [[ "$line" =~ ^#cloud-config ]] && continue
        [[ "$line" =~ ^#  ]] && continue
        [[ -z "$line" ]] && { $in_list || echo; continue; }

        # Detect top-level keys
        if [[ "$line" =~ ^([a-z_]+): ]]; then
            current_key="${BASH_REMATCH[1]}"
            in_list=false
            for skip in "${skip_keys[@]}"; do
                if [[ "$current_key" == "$skip" ]]; then
                    in_list=true
                    break
                fi
            done
            $in_list && continue
            echo "$line"
            continue
        fi

        # Print continuation lines for non-skipped sections
        $in_list || echo "$line"
    done < "$file"
}

# Generate write_files entries for secrets injection
generate_write_files() {
    local secrets_file="$1"
    local repo_url="$2"
    local result=""

    result+="write_files:\n"

    # Parse secrets for OpenCode config
    local api_key="" opencode_key="" git_name="" git_email=""
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        key=$(echo "$key" | xargs)
        case "$key" in
            OPENAI_API_KEY)  api_key="${value//\"/\\\"}" ;;
            OPENCODE_API_KEY) opencode_key="${value//\"/\\\"}" ;;
            GIT_USER_NAME)   git_name="${value//\"/\\\"}" ;;
            GIT_USER_EMAIL)  git_email="${value//\"/\\\"}" ;;
        esac
    done < "$secrets_file"

    # OpenCode config
    result+="  - path: /home/opencode/.config/opencode/config.yaml\n"
    result+="    owner: opencode:opencode\n"
    result+="    permissions: '0600'\n"
    result+="    content: |\n"
    result+="      api_key: \"${api_key}\"\n"
    if [[ -n "$opencode_key" ]]; then
        result+="      opencode_api_key: \"${opencode_key}\"\n"
    fi

    # Git config
    result+="  - path: /home/opencode/.gitconfig\n"
    result+="    owner: opencode:opencode\n"
    result+="    permissions: '0644'\n"
    result+="    content: |\n"
    result+="      [user]\n"
    result+="          name = \"${git_name}\"\n"
    result+="          email = \"${git_email}\"\n"

    # SSH known_hosts (DEV-010)
    result+="  - path: /home/opencode/.ssh/known_hosts\n"
    result+="    owner: opencode:opencode\n"
    result+="    permissions: '0644'\n"
    result+="    content: |\n"
    result+="      github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZBkn48cTga1gQ0LyKDMTY1NuV3SpO/w7DAoH+UrF+0j5HSGldk2RKHFHJ9hL6S72y+Q+UNR3pJXSlp2L8ABGbhLaRL6fCJRLOJQReL/u1BhnLXtSjE2TVPVMBKF3P/v5rxYCRmkv1FR7F/hLWRiTcMnPnzB3j1WUmhKvP/iG+grsHhJAcCwpzK0QVpvz47DMFSZqIJb1WGUKm0K0sHuF3nrMZ/oU5cL0kkBklcHQEH/TdL4MYiyXpIN6rqYrRMdxAcMdX0DH6riP6HH0E8YXEfFB8BkDlxCH0pvDdKMJq/kMcEyS9FyDJM+M/N3PXf5eFUZ3/GZ3d/Z3JN0OSHgRf+5JB7+d5LBGmkPKFlI/w5HEW7i0sJB7+S+0gRnUWOK+AScW0DzVJjK5xmRAAERkGSrAfCGLNnMfBehBHGeJJL+KGZx5Q0cBekM=\n"
    if [[ "$repo_url" == *"gitlab.com"* ]]; then
        result+="      gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2bNKTBSpIYDEGk9KxsGh3mySTRgMtXL583qmBpzeQ+jqCMRgBqB98u3z++J1sKlXHWfM9dyhSevkMwSbhoR8XIq/HpRqgBNRp7WX1eQV4M8S4UZxfl/73a7a8L+N/J5eSBcF0H4O6oGbAyYF+CeZvPSTGAEkIRZ0X+cdiHlJNa1b5mD2xJBLcojMvJZR7LM2YN3RW1vx8zFJaPJqD+8+R7GjACmK8FP8rCRw9CprLBLm7btNjl84hX8Wf/qlaI2Q9g9N5XsUAgWCuFb9BLOvl/zjGLJtUODfY7q5GMSs+PuN2XPWKoJ+tB0O8r6BhAl5kro1L4S4cN8KOf\n"
    fi

    echo -e "$result"
}

# Generate cloud-init YAML by reading and merging base.yaml + security.yaml + secrets
generate_cloud_init() {
    local secrets_file="$1"
    local repo_url="$2"

    local base_file="${CLOUD_INIT_DIR}/base.yaml"
    local security_file="${CLOUD_INIT_DIR}/security.yaml"

    if [[ ! -f "$base_file" ]]; then
        log_error "Missing cloud-init base config: $base_file"
        exit 1
    fi
    if [[ ! -f "$security_file" ]]; then
        log_error "Missing cloud-init security config: $security_file"
        exit 1
    fi

    local output="#cloud-config\n"
    output+="# Merged cloud-init configuration for secure dev environment\n"
    output+="# Generated by launch.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)\n\n"

    # --- Scalars and mappings from base.yaml (package_update, users, etc.) ---
    output+="$(extract_yaml_scalars_and_mappings "$base_file")\n\n"

    # --- Merged packages list ---
    local base_packages security_packages
    base_packages=$(extract_yaml_list "$base_file" "packages")
    security_packages=$(extract_yaml_list "$security_file" "packages")
    output+="packages:\n"
    [[ -n "$base_packages" ]] && output+="${base_packages}\n"
    [[ -n "$security_packages" && "$security_packages" != *"[]"* ]] && output+="${security_packages}\n"
    output+="\n"

    # --- write_files from secrets injection ---
    output+="$(generate_write_files "$secrets_file" "$repo_url")\n"

    # --- Merged runcmd ---
    local base_runcmd security_runcmd
    base_runcmd=$(extract_yaml_list "$base_file" "runcmd")
    security_runcmd=$(extract_yaml_list "$security_file" "runcmd")

    output+="runcmd:\n"
    output+="  - echo 'Starting cloud-init configuration...'\n"

    # Base runcmd (directory creation, package cleanup)
    [[ -n "$base_runcmd" ]] && output+="${base_runcmd}\n"

    # Security runcmd (UFW setup, SSH disable, config lock)
    [[ -n "$security_runcmd" ]] && output+="${security_runcmd}\n"

    # Clone repository
    output+="  - cd /home/opencode/workspace && git clone \"$repo_url\" || echo 'Clone failed'\n"
    output+="  - chown -R opencode:opencode /home/opencode/workspace\n"

    # Install OpenCode CLI (DEV-005, DEV-006, DEV-020, DEV-021)
    local opencode_url="${OPENCODE_BASE_URL}/download/${OPENCODE_VERSION}/opencode-linux-amd64"
    output+="  - echo 'Installing OpenCode CLI...'\n"
    output+="  - cd /tmp\n"
    output+="  - wget -q \"$opencode_url\" -O opencode-binary || echo 'OpenCode download failed - continuing without it'\n"
    if [[ -n "${OPENCODE_CHECKSUM:-}" ]]; then
        output+="  - echo '${OPENCODE_CHECKSUM}  opencode-binary' | sha256sum -c || (echo 'Checksum mismatch - aborting'; exit 1)\n"
    fi
    output+="  - if [ -f opencode-binary ]; then chmod +x opencode-binary && mv opencode-binary /usr/local/bin/opencode; fi\n"
    output+="  - opencode --version || echo 'OpenCode not installed - download may have failed'\n"

    # Revoke sudo from opencode user after all setup is complete (DEV-022)
    output+="  - deluser opencode sudo || true\n"
    output+="  - echo 'Cloud-init configuration complete'\n"

    echo -e "$output"
}

# Launch VM with Multipass
launch_vm() {
    local name="$1"
    local cloud_init="$2"
    local dry_run="$3"

    if [[ "$dry_run" == "true" ]]; then
        log_info "=== DRY RUN MODE ==="
        log_info "VM Name: $name"
        log_info "Image: Ubuntu $VM_IMAGE"
        log_info ""
        log_info "=== Cloud-init Configuration ==="
        echo "$cloud_init"
        log_info ""
        log_info "To create this VM, run without --dry-run"
        exit 0
    fi

    # Create temporary file for cloud-init
    local temp_file
    temp_file=$(mktemp /tmp/cloud-init.XXXXXX.yaml)
    echo "$cloud_init" > "$temp_file"

    log_info "Creating VM: $name"
    log_info "Using Ubuntu $VM_IMAGE image"

    # Launch VM
    if ! multipass launch "$VM_IMAGE" \
        --name "$name" \
        --cpus 4 \
        --memory 8G \
        --disk 32G \
        --cloud-init "$temp_file"; then
        log_error "Failed to launch VM"
        rm -f "$temp_file"
        exit 1
    fi

    rm -f "$temp_file"

    # Wait for VM to be ready
    log_info "Waiting for VM to initialize..."
    sleep 10

    # Verify VM is running
    if ! multipass info "$name" &>/dev/null; then
        log_error "VM creation failed"
        exit 1
    fi

    log_success "VM '$name' created successfully"
    log_info ""
    log_info "Access the VM with: multipass shell $name"
    log_info "Work directory: /home/opencode/workspace"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --repo"
                    print_usage
                    exit 1
                fi
                REPO_URL="$2"
                shift 2
                ;;
            --secrets)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --secrets"
                    print_usage
                    exit 1
                fi
                SECRETS_FILE="$2"
                shift 2
                ;;
            --name)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --name"
                    print_usage
                    exit 1
                fi
                VM_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$REPO_URL" ]]; then
        log_error "Missing required argument: --repo"
        print_usage
        exit 1
    fi

    if [[ -z "$SECRETS_FILE" ]]; then
        log_error "Missing required argument: --secrets"
        print_usage
        exit 1
    fi
}

main() {
    parse_args "$@"

    log_info "=== Secure Dev Environment Launcher ==="
    log_info ""

    # Validate inputs (DEV-004)
    validate_secrets_file "$SECRETS_FILE"

    # Generate VM name if not specified
    if [[ -z "$VM_NAME" ]]; then
        VM_NAME=$(generate_vm_name "$REPO_URL")
        log_info "Generated VM name: $VM_NAME"
    fi

    # Generate cloud-init configuration
    log_info "Generating cloud-init configuration..."
    local cloud_init
    cloud_init=$(generate_cloud_init "$SECRETS_FILE" "$REPO_URL")

    # Launch VM
    launch_vm "$VM_NAME" "$cloud_init" "$DRY_RUN"
}

main "$@"
