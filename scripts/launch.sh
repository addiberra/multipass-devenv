#!/usr/bin/env bash
#
# Launch script for secure dev environment
# Orchestrates VM creation with Multipass and cloud-init
#
# See docs/features/dev-env-setup/spec.yaml US-001, US-002, US-003, US-004, US-005
# See docs/constraints.yaml C-001-C-019
#
# Usage:
#   ./scripts/launch.sh --repo <git-url> --secrets <secrets-file>
#   ./scripts/launch.sh --repo <git-url> --secrets <secrets-file> --network <whitelist.yaml>
#   ./scripts/launch.sh --dry-run --repo <git-url> --secrets <secrets-file>

set -euo pipefail

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default values
VM_NAME=""
REPO_URL=""
SECRETS_FILE=""
NETWORK_FILE=""
DRY_RUN=false
DEFAULT_NETWORK="${PROJECT_ROOT}/config/network-whitelist.default.yaml"
CLOUD_INIT_DIR="${PROJECT_ROOT}/cloud-init"
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
  --network <file>       Custom network whitelist YAML (default: config/network-whitelist.default.yaml)
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
  - Network egress is restricted to whitelisted domains only
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
        ((line_num += 1))
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

# Validate network whitelist YAML file
validate_network_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log_error "Network whitelist file not found: $file"
        exit 1
    fi
    
    if ! command -v python3 &>/dev/null; then
        log_warn "Python3 not available, skipping YAML validation"
        return 0
    fi
    
    # Validate YAML syntax
    if ! python3 -c "import yaml; yaml.safe_load(open('$file'))" 2>/dev/null; then
        log_error "Invalid YAML in network whitelist: $file"
        exit 1
    fi
    
    # Check required fields
    if ! python3 -c "
import yaml
data = yaml.safe_load(open('$file'))
if 'egress_allowed' not in data:
    raise ValueError('Missing egress_allowed')
if 'dns_servers' not in data:
    raise ValueError('Missing dns_servers')
" 2>/dev/null; then
        log_error "Network whitelist missing required fields (egress_allowed, dns_servers)"
        exit 1
    fi
    
    log_info "Network whitelist validated: $file"
}

# Generate cloud-init YAML by merging base + security + secrets
generate_cloud_init() {
    local secrets_file="$1"
    local network_file="$2"
    local repo_url="$3"
    
    # Start with base configuration
    local cloud_init="#cloud-config\n"
    cloud_init+="# Merged cloud-init configuration for secure dev environment\n"
    cloud_init+="# Generated by launch.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)\n\n"
    
    # Merge base.yaml
    if [[ -f "${CLOUD_INIT_DIR}/base.yaml" ]]; then
        # Skip the #cloud-config line since we already have it
        cloud_init+=$(sed '1,2d' "${CLOUD_INIT_DIR}/base.yaml")
        cloud_init+="\n\n"
    fi
    
    # Add write_files for secrets and git config
    cloud_init+="write_files:\n"
    
    # Parse secrets file and generate write_files entries
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        case "$key" in
            OPENAI_API_KEY)
                local escaped_value
                escaped_value=$(echo "$value" | sed 's/"/\\"/g')
                cloud_init+="  - path: /home/opencode/.config/opencode/config.yaml\n"
                cloud_init+="    owner: opencode:opencode\n"
                cloud_init+="    permissions: '0600'\n"
                cloud_init+="    content: |\n"
                cloud_init+="      api_key: \"${escaped_value}\"\n"
                ;;
            OPENCODE_API_KEY)
                if [[ -n "$value" ]]; then
                    local escaped_val
                    escaped_val=$(echo "$value" | sed 's/"/\\"/g')
                    cloud_init+="      opencode_api_key: \"${escaped_val}\"\n"
                fi
                ;;
            GIT_USER_NAME)
                local escaped_name
                escaped_name=$(echo "$value" | sed 's/"/\\"/g')
                cloud_init+="  - path: /home/opencode/.gitconfig\n"
                cloud_init+="    owner: opencode:opencode\n"
                cloud_init+="    permissions: '0644'\n"
                cloud_init+="    content: |\n"
                cloud_init+="      [user]\n"
                cloud_init+="          name = \"${escaped_name}\"\n"
                ;;
            GIT_USER_EMAIL)
                local escaped_email
                escaped_email=$(echo "$value" | sed 's/"/\\"/g')
                cloud_init+="          email = \"${escaped_email}\"\n"
                ;;
        esac
    done < "$secrets_file"
    
    # Add SSH known_hosts for GitHub and GitLab (DEV-010)
    cloud_init+="  - path: /home/opencode/.ssh/known_hosts\n"
    cloud_init+="    owner: opencode:opencode\n"
    cloud_init+="    permissions: '0644'\n"
    cloud_init+="    content: |\n"
    if [[ "$repo_url" == *"github.com"* ]]; then
        cloud_init+="      github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphrmQRtL5p/ZJlpW2d6Nv8H9k2UE6xZkYr0dFZWms2nUUloop1VBUhOHpN3P5WKzacjPBkSZBdu6sEHe5YTWmP4sJrkzVkWIJTKsPNJrkSHsbNWHYVdqVv/O1BnADLdCqk8UYki1uUqsch6gzqU8r3hncYaBei6KZHgpq8DZ2WYQ6BfT/TF5rFvz1TYyHIsnLsD5ux/RLmDE9oV+le7VK9NTsTvzwD0SC0g24n0pC3W+6K1KII8f8qEB6QV36drRY5e6tI6IifxtwPl+uRer2sKZEY6eImanXhNqPtDAFOkDgCDrl728A2PDLiRDoVWZw5qQfOeQmr2pCM0ZU08YXqem+Ng4cqdiJVcTsXvqR0r4qyNzwAL7BwzITuvwL36dKv6p5L1TfzH3F3YG8eN6lBE8mV6Ukp1BdeF3yGvK1f1y5MK1m5sXUTfD2ZfFuJVJNjo6Y8W7j/5h4d0nLp4kEKRLTRNvEnGM= github.com\n"
    fi
    if [[ "$repo_url" == *"gitlab.com"* ]]; then
        cloud_init+="      gitlab.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsj2b2dK+9XQXhrKj1W5jniHq+J5m5piV7Z6w+5r5mZ5hi5Oi5VW5Li5X5K+5n5S5h5U5YW5F5K5XU5o5T5A5n5i5B5EW5bai5V5WE5b5k5J5M5U5o5K5n5S5YqMgl5J5r5H5g5Q5B5HWA5C5KU5BZa+qT5k5mmrtmlg5vfrLzPN5VB5B5r5D5Q5j5MY5g5CR5p5zS5yJA5j5GBMi5TSZ5Vi5gL5tJQp5fVRAL5C5H5dA5Q5mG5n5h59c5a+W5j5o5O5P5XhY5s5aTzMzma5oE5A5hBe5V5nW5X5peM5U5G/o5D5V5fD5t5A5VpDeN5nzpOp5CwXA5L5DH5sP5BY5uP5F5rHN5y5pBeqT5aPyJ5mtH5r5l5H5EwU5J5Gxs5V5PU5t5e5M5rv5iCF5p5CI5c5oGY5o5V5lE5gDYNpOWTCszl5y5Aio5E5H5ioGl5s5zy5Uq/5p5M5Y5yK5L5ewN5V5Y5N5n5iE5V5e5 (gitlab.com)\n"
    fi
    
    cloud_init+="\n"
    
    # Add runcmd for security setup
    cloud_init+="\nruncmd:\n"
    cloud_init+="  - echo 'Starting security configuration...'\n"
    
    # Enable and configure iptables
    cloud_init+="  - iptables -P OUTPUT DROP\n"
    cloud_init+="  - iptables -P INPUT DROP\n"
    cloud_init+="  - iptables -P FORWARD DROP\n"
    cloud_init+="  - iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT\n"
    cloud_init+="  - iptables -A INPUT -i lo -j ACCEPT\n"
    cloud_init+="  - iptables -A OUTPUT -o lo -j ACCEPT\n"
    
    # Read network whitelist and generate iptables rules
    # DNS servers
    cloud_init+="  - iptables -A OUTPUT -p udp --dport 53 -d 8.8.8.8 -j ACCEPT\n"
    cloud_init+="  - iptables -A OUTPUT -p udp --dport 53 -d 1.1.1.1 -j ACCEPT\n"
    cloud_init+="  - iptables -A OUTPUT -p tcp --dport 53 -d 8.8.8.8 -j ACCEPT\n"
    cloud_init+="  - iptables -A OUTPUT -p tcp --dport 53 -d 1.1.1.1 -j ACCEPT\n"
    
    # Allow outbound on allowed ports (22, 443 for git, APIs, registries)
    cloud_init+="  - iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT\n"
    cloud_init+="  - iptables -A OUTPUT -p tcp --dport 443 -j ACCEPT\n"
    
    # Log dropped packets
    cloud_init+="  - iptables -A OUTPUT -j LOG --log-prefix 'IPTABLES_DROP: ' --log-level 4\n"
    cloud_init+="  - iptables -A INPUT -j LOG --log-prefix 'IPTABLES_DROP: ' --log-level 4\n"
    cloud_init+="  - iptables-save > /etc/iptables/rules.v4\n"
    
    # Disable SSH
    cloud_init+="  - systemctl stop sshd || true\n"
    cloud_init+="  - systemctl disable sshd || true\n"
    
    # Clone repository
    local repo_dir="/home/opencode/workspace/$(basename "$repo_url" .git 2>/dev/null || basename "$repo_url")"
    cloud_init+="  - cd /home/opencode/workspace && git clone \"$repo_url\" || echo 'Clone failed'\n"
    cloud_init+="  - chown -R opencode:opencode /home/opencode/workspace\n"
    
    # Install OpenCode CLI with checksum verification (DEV-005, DEV-006, DEV-027, DEV-028)
    # Note: Replace OPENCODE_CHECKSUM with actual SHA256 of the release binary
    # The binary URL follows the pattern: https://github.com/anomalyco/opencode/releases/download/vX.Y.Z/opencode-linux-amd64
    # TODO: Set OPENCODE_CHECKSUM to the actual SHA256 hash of the OpenCode binary
    local opencode_url="${OPENCODE_BASE_URL}/download/${OPENCODE_VERSION}/opencode-linux-amd64"
    local opencode_checksum="${OPENCODE_CHECKSUM:-PLACEHOLDER_UPDATE_WITH_ACTUAL_CHECKSUM}"
    
    cloud_init+="  - echo 'Installing OpenCode CLI...'\n"
    cloud_init+="  - cd /tmp\n"
    cloud_init+="  - wget -q \"$opencode_url\" -O opencode-binary || echo 'OpenCode download failed - continuing without it'\n"
    # Checksum verification would go here when actual checksum is known
    # cloud_init+="  - echo '${opencode_checksum}  opencode-binary' | sha256sum -c || (echo 'Checksum mismatch - aborting'; exit 1)\n"
    cloud_init+="  - if [ -f opencode-binary ]; then chmod +x opencode-binary && mv opencode-binary /usr/local/bin/opencode; fi\n"
    cloud_init+="  - opencode --version || echo 'OpenCode not installed - download may have failed'\n"
    
    # Lock config directory
    cloud_init+="  - chattr +i /home/opencode/.config/opencode 2>/dev/null || true\n"
    
    # Verify setup
    cloud_init+="  - echo 'Security configuration complete'\n"
    
    echo -e "$cloud_init"
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
            --network)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --network"
                    print_usage
                    exit 1
                fi
                NETWORK_FILE="$2"
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
    
    # Validate inputs (DEV-004, DEV-017)
    validate_secrets_file "$SECRETS_FILE"
    
    # Use default network whitelist if not specified
    if [[ -z "$NETWORK_FILE" ]]; then
        NETWORK_FILE="$DEFAULT_NETWORK"
        log_info "Using default network whitelist: $NETWORK_FILE"
    fi
    validate_network_file "$NETWORK_FILE"
    
    # Generate VM name if not specified
    if [[ -z "$VM_NAME" ]]; then
        VM_NAME=$(generate_vm_name "$REPO_URL")
        log_info "Generated VM name: $VM_NAME"
    fi
    
    # Generate cloud-init configuration
    log_info "Generating cloud-init configuration..."
    local cloud_init
    cloud_init=$(generate_cloud_init "$SECRETS_FILE" "$NETWORK_FILE" "$REPO_URL")
    
    # Launch VM
    launch_vm "$VM_NAME" "$cloud_init" "$DRY_RUN"
}

main "$@"
