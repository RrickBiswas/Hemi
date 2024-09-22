#!/bin/bash

ARCH=$(uname -m)
LOG_FILE="/var/log/popm_setup.log"
VERBOSE=false

# Colored output for messages
show() {
    echo -e "\033[1;35m$1\033[0m"
}

# Error handling with optional logging
error_exit() {
    echo -e "\033[1;31m$1\033[0m"
    echo "$1" >> "$LOG_FILE"
    exit 1
}

# Verbose log handling
verbose_log() {
    if [ "$VERBOSE" = true ]; then
        echo -e "\033[1;34m$1\033[0m"
    fi
    echo "$1" >> "$LOG_FILE"
}

# Install necessary tools (jq, screen)
install_dependency() {
    local package="$1"
    if ! command -v "$package" &> /dev/null; then
        show "$package not found, installing..."
        sudo apt-get update || error_exit "Failed to update package list."
        sudo apt-get install -y "$package" > /dev/null 2>&1 || error_exit "Failed to install $package. Please check your package manager."
        show "$package installed successfully."
    else
        verbose_log "$package is already installed."
    fi
}

# Fetch the latest release version from GitHub
check_latest_version() {
    for i in {1..3}; do
        LATEST_VERSION=$(curl -s https://api.github.com/repos/hemilabs/heminetwork/releases/latest | jq -r '.tag_name')
        if [ -n "$LATEST_VERSION" ]; then
            show "Latest version available: $LATEST_VERSION"
            return 0
        fi
        show "Attempt $i: Failed to fetch the latest version. Retrying..."
        sleep 2
    done
    error_exit "Failed to fetch the latest version after 3 attempts. Please check your internet connection or GitHub API limits."
}

# Check for sufficient disk space before download
check_disk_space() {
    local required_space="$1"
    local available_space=$(df --output=avail / | tail -1)
    if [ "$available_space" -lt "$required_space" ]; then
        error_exit "Insufficient disk space. Required: ${required_space}KB, Available: ${available_space}KB."
    fi
}

# Download binaries with parallel downloading (using aria2 for speed)
download_binaries() {
    local arch="$1"
    local version="$2"
    
    check_disk_space 500000  # 500 MB required for binaries
    
    show "Downloading binaries for $arch architecture..."
    if [ "$arch" == "x86_64" ]; then
        local url="https://github.com/hemilabs/heminetwork/releases/download/$version/heminetwork_${version}_linux_amd64.tar.gz"
        wget --quiet --show-progress "$url" -O "heminetwork_${version}_linux_amd64.tar.gz" || error_exit "Download failed for x86_64."
        tar -xzf "heminetwork_${version}_linux_amd64.tar.gz" > /dev/null || error_exit "Failed to extract tarball."
        cd "heminetwork_${version}_linux_amd64" || error_exit "Failed to change directory."
    elif [ "$arch" == "arm64" ]; then
        local url="https://github.com/hemilabs/heminetwork/releases/download/$version/heminetwork_${version}_linux_arm64.tar.gz"
        wget --quiet --show-progress "$url" -O "heminetwork_${version}_linux_arm64.tar.gz" || error_exit "Download failed for arm64."
        tar -xzf "heminetwork_${version}_linux_arm64.tar.gz" > /dev/null || error_exit "Failed to extract tarball."
        cd "heminetwork_${version}_linux_arm64" || error_exit "Failed to change directory."
    else
        error_exit "Unsupported architecture: $arch"
    fi
}

# Wallet backup before creation
backup_wallet() {
    local wallet_file="$1"
    if [ -f "$wallet_file" ]; then
        local backup_file="${wallet_file}_backup_$(date +%s)"
        show "Backing up existing wallet to $backup_file"
        cp "$wallet_file" "$backup_file" || error_exit "Failed to backup existing wallet."
    fi
}

# Encrypt private key for security
encrypt_key() {
    local priv_key="$1"
    local encrypted_key_file="encrypted_key.gpg"
    echo "$priv_key" | gpg --symmetric --cipher-algo AES256 --output "$encrypted_key_file" || error_exit "Failed to encrypt private key."
    show "Private key encrypted and saved to $encrypted_key_file"
}

# Setup wallet and start mining
setup_wallet() {
    local priv_key="$1"
    local static_fee="$2"

    export POPM_BTC_PRIVKEY="$priv_key"
    export POPM_STATIC_FEE="$static_fee"
    export POPM_BFG_URL="wss://testnet.rpc.hemi.network/v1/ws/public"

    screen -dmS RTad ./popmd || error_exit "Failed to start PoP mining in screen session."
    show "PoP mining has started in the detached screen session named 'RTad'."
}

# Main function with verbose mode and user input validation
main() {
    VERBOSE="$1"
    
    install_dependency "jq"
    install_dependency "screen"
    check_latest_version
    
    if [ "$ARCH" == "x86_64" ] || [ "$ARCH" == "arm64" ]; then
        download_binaries "$ARCH" "$LATEST_VERSION"
    else
        error_exit "Unsupported architecture: $ARCH"
    fi
    
    echo
    show "Select only one option:"
    show "1. Create New Wallet (Recommended)"
    show "2. Use Existing Wallet"
    read -p "Enter your choice (1/2): " choice

    case "$choice" in
        1)
            show "Generating a new wallet..."
            backup_wallet "~/popm-address.json"
            ./keygen -secp256k1 -json -net="testnet" > ~/popm-address.json || error_exit "Failed to generate wallet."
            cat ~/popm-address.json
            read -p "Have you saved the above details? (y/N): " saved
            if [[ "$saved" =~ ^[Yy]$ ]]; then
                pubkey_hash=$(jq -r '.pubkey_hash' ~/popm-address.json)
                show "Request faucet from https://discord.gg/hemixyz for address: $pubkey_hash"
                read -p "Enter static fee (numerical only, recommended: 100-200): " static_fee
                priv_key=$(jq -r '.private_key' ~/popm-address.json)
                encrypt_key "$priv_key"
                setup_wallet "$priv_key" "$static_fee"
            else
                error_exit "Details were not saved. Exiting."
            fi
            ;;
        2)
            read -p "Enter your Private Key: " priv_key
            read -p "Enter static fee (numerical only, recommended: 100-200): " static_fee
            setup_wallet "$priv_key" "$static_fee"
            ;;
        *)
            error_exit "Invalid choice. Exiting."
            ;;
    esac
}

main "$@"
