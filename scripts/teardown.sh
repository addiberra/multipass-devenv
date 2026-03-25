#!/usr/bin/env bash
#
# Teardown script for secure dev environment
# Destroys Multipass VM and all associated data
#
# See docs/features/dev-env-setup/spec.yaml US-006
# See docs/constraints.yaml C-006
#
# Usage:
#   ./scripts/teardown.sh --name <vm-name>
#   ./scripts/teardown.sh --name <vm-name> --force

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VM_NAME=""
FORCE=false

print_usage() {
    cat <<'EOF'
Usage: ./scripts/teardown.sh --name <vm-name> [--force]

Options:
  --name <vm-name>  Name of the Multipass VM to destroy (required)
  --force           Skip confirmation prompt
  --help            Show this help message

Examples:
  ./scripts/teardown.sh --name my-project-dev
  ./scripts/teardown.sh --name my-project-dev --force
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

validate_vm_exists() {
    local name="$1"
    if ! multipass info "$name" &>/dev/null; then
        log_error "VM '$name' does not exist"
        log_info "Available VMs:"
        multipass list --format csv | tail -n +2 | while IFS=',' read -r vm_name _; do
            echo "  - $vm_name"
        done
        exit 1
    fi
}

confirm_destroy() {
    local name="$1"
    
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    echo ""
    echo "=========================================="
    echo "WARNING: This action cannot be undone!"
    echo "=========================================="
    echo "VM Name: $name"
    echo ""
    echo "This will permanently delete:"
    echo "  - All files in the VM"
    echo "  - All cloned repositories"
    echo "  - All credentials and configurations"
    echo ""
    
    read -r -p "Destroy VM '$name'? [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log_info "Operation cancelled"
            exit 0
            ;;
    esac
}

destroy_vm() {
    local name="$1"
    
    log_info "Stopping VM '$name'..."
    if multipass stop "$name" 2>/dev/null; then
        log_info "VM stopped"
    else
        log_info "VM was not running (continuing anyway)"
    fi
    
    log_info "Deleting VM '$name'..."
    if ! multipass delete --purge "$name" 2>&1; then
        log_error "Failed to delete VM '$name'"
        exit 1
    fi
    
    log_success "VM '$name' has been destroyed"
}

verify_destruction() {
    local name="$1"
    
    if multipass info "$name" &>/dev/null; then
        log_error "VM '$name' still exists after deletion attempt"
        exit 1
    fi
    
    log_info "Verified: VM '$name' no longer exists"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --name"
                    print_usage
                    exit 1
                fi
                VM_NAME="$2"
                shift 2
                ;;
            --force)
                FORCE=true
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
    
    if [[ -z "$VM_NAME" ]]; then
        log_error "Missing required argument: --name"
        print_usage
        exit 1
    fi
}

main() {
    parse_args "$@"
    
    log_info "Starting teardown for VM: $VM_NAME"
    
    validate_vm_exists "$VM_NAME"
    confirm_destroy "$VM_NAME"
    destroy_vm "$VM_NAME"
    verify_destruction "$VM_NAME"
    
    echo ""
    log_success "Teardown complete. All traces of '$VM_NAME' have been removed."
}

main "$@"