#!/bin/sh

# Source the centralized configuration file
source ./config.sh

# Function to print a warning
warn() {
    echo "WARNING: $1"
}

# Function to print and exit on error
exit_on_error() {
    echo "$1"
    exit 1
}

# Check if connected to the internet
ping -c 1 google.com > /dev/null 2>&1
if [ $? -ne 0 ]; then
    exit_on_error "No internet connection. Please download the necessary packages manually."
else
    echo "Internet connection verified."
fi

# Check if Moonraker is already running
if ps aux | grep '[m]oonraker' > /dev/null; then
    echo "Moonraker is already running. Configuring Fluidd and Mainsail with the existing Moonraker service."

    # Ensure scripts are executable
    chmod +x "$SCRIPTS_DIR/setup_nginx.sh"

    # Trigger Nginx setup script
    $SCRIPTS_DIR/setup_nginx.sh || exit_on_error "Failed to configure Nginx"
    exit 0
fi

echo "Moonraker is not running. Proceeding with full installation."

# Ensure necessary directories exist
mkdir -p "$PACKAGES_DIR/python" "$PACKAGES_DIR/ipk" "$FLUIDD_KLIPPER_CFG_DIR" "$TMPDIR"

# Verify that the 'python' and 'ipk' directories exist under 'packages'
if [ ! -d "$PACKAGES_DIR/python" ]; then
    exit_on_error "The directory $PACKAGES_DIR/python does not exist."
fi

if [ ! -d "$PACKAGES_DIR/ipk" ]; then
    exit_on_error "The directory $PACKAGES_DIR/ipk does not exist."
fi

# Check for Python version compatibility
echo "Checking Python version..."
python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
required_python_version="3.6"
if [ "$(printf '%s\n' "$required_python_version" "$python_version" | sort -V | head -n1)" != "$required_python_version" ]; then
    echo "Python version is less than $required_python_version. Upgrading Python..."
    opkg install python3 || exit_on_error "Failed to upgrade Python"
else
    echo "Python version is $python_version, which is compatible."
fi

# Function to check if a Python package is installed
is_python_package_installed() {
    pip3 show "$1" > /dev/null 2>&1
    return $?
}

# Function to check if an IPK package is installed
is_ipk_package_installed() {
    opkg list-installed | grep -q "$1"
    return $?
}

# Install necessary .whl files
install_whl_files() {
    for file in "$@"; do
        package_name=$(echo "$file" | sed 's/-[0-9].*//')
        if [ ! -f "$PACKAGES_DIR/python/$file" ]; then
            if is_python_package_installed "$package_name"; then
                echo "$package_name is already installed."
            else
                warn "Required file $file not found in $PACKAGES_DIR/python and $package_name is not installed. Attempting to download and install..."
                pip3 install "$package_name" || exit_on_error "Failed to install $package_name from PyPI"
            fi
        else
            pip3 install "$PACKAGES_DIR/python/$file" || exit_on_error "Failed to install $file from local file"
        fi
    done
}

install_whl_files \
    "zipp-3.18.1-py3-none-any.whl" \
    "typing_extensions-4.11.0-py3-none-any.whl" \
    "tomli-2.0.1-py3-none-any.whl" \
    "setuptools_scm-8.1.0-py3-none-any.whl" \
    "importlib_metadata-7.1.0-py3-none-any.whl" \
    "Markdown-3.6-py3-none-any.whl" \
    "mkdocs-1.6.0-py3-none-any.whl" \
    "mergedeep-1.3.4-py3-none-any.whl" \
    "packaging-24.0-py3-none-any.whl" \
    "jinja2-3.1.4-py3-none-any.whl" \
    "watchdog-2.1.9-py3-none-manylinux2014_armv7l.whl" \
    "lmdb-1.4.1-cp38-cp38-manylinux2014_x86_64.whl"

# Ensure necessary system libraries are installed
install_system_libraries() {
    echo "Installing necessary system libraries..."
    opkg update
    opkg install libsodium libjpeg zlib || exit_on_error "Failed to install necessary system libraries"
}

install_system_libraries

# Install required dependencies from source or alternative methods
install_from_source_or_alternative() {
    echo "Attempting to install $1 from source or alternative method..."
    case "$1" in
        python3-virtualenv)
            pip3 install virtualenv || exit_on_error "Failed to install virtualenv"
            ;;
        python3-dev)
            echo "Skipping python3-dev as it's not installable via pip"
            ;;
        liblmdb-dev)
            pip3 install lmdb || exit_on_error "Failed to install lmdb"
            ;;
        libopenjp2-7)
            pip3 install pillow || exit_on_error "Failed to install pillow (includes support for openjp2)"
            ;;
        libsodium-dev)
            pip3 install libnacl || warn "Failed to install libnacl, this might impact functionality depending on its usage"
            ;;
        zlib1g-dev)
            python3 -c "import zlib" || exit_on_error "zlib not available in Python standard library"
            ;;
        libjpeg-dev)
            pip3 install pillow || exit_on_error "Failed to install pillow (includes support for libjpeg)"
            ;;
        packagekit)
            echo "Skipping packagekit as there's no direct equivalent"
            ;;
        wireless-tools)
            echo "Skipping wireless-tools as there's no direct equivalent"
            ;;
        curl)
            opkg install curl || exit_on_error "Failed to install curl"
            ;;
        *)
            warn "No alternative installation method for $1"
            ;;
    esac
}

# List of required dependencies to install from source or alternative methods
required_dependencies="python3-virtualenv python3-dev liblmdb-dev libopenjp2-7 libsodium-dev zlib1g-dev libjpeg-dev packagekit wireless-tools curl"

# Install the required dependencies
for dep in $required_dependencies; do
    if ! is_python_package_installed "$dep" && ! is_ipk_package_installed "$dep"; then
        install_from_source_or_alternative "$dep"
    fi
done

# Backup existing printer.cfg
if [ -f "$PRINTER_CFG" ]; then
    echo "Backing up existing printer.cfg to $BACKUP_PRINTER_CFG"
    cp "$PRINTER_CFG" "$BACKUP_PRINTER_CFG" || exit_on_error "Failed to backup printer.cfg"
else
    echo "No existing printer.cfg found to backup."
fi

# Ensure printer.cfg is accessible
if [ ! -d "$FLUIDD_KLIPPER_CFG_DIR" ]; then
    echo "Creating directory $FLUIDD_KLIPPER_CFG_DIR"
    mkdir -p "$FLUIDD_KLIPPER_CFG_DIR" || exit_on_error "Failed to create directory $FLUIDD_KLIPPER_CFG_DIR"
fi

# Copy or create a symlink for the printer.cfg file
if [ -f "$PRINTER_CFG" ]; then
    echo "Copying printer.cfg to $FLUIDD_KLIPPER_CFG_DIR"
    cp "$PRINTER_CFG" "$FLUIDD_KLIPPER_CFG_DIR/printer.cfg" || exit_on_error "Failed to copy printer.cfg"
else
    exit_on_error "No printer.cfg found to copy."
fi

# Ensure scripts are executable
chmod +x "$SCRIPTS_DIR/install_moonraker.sh"
chmod +x "$SCRIPTS_DIR/setup_nginx.sh"

# Ensure moonrakeruser has ownership of the /usr/data directory
chown -R moonrakeruser:moonrakeruser /usr/data

# Function to verify if moonrakeruser has necessary permissions
verify_moonrakeruser_permissions() {
    su - moonrakeruser << 'EOF'
    # Set PATH to include Entware binaries
    export PATH=$PATH:/opt/bin:/opt/sbin

    # Ensure bash is installed
    BASH_PATH=$(which bash)
    if [ -z "$BASH_PATH" ]; then
        echo "Bash is not installed. Installing bash..."
        opkg install bash || exit_on_error "Failed to install bash"
    fi

    # Check if sudo is installed
    SUDO_PATH=$(which sudo)
    if [ -z "$SUDO_PATH" ]; then
        echo "Sudo is not installed. Installing sudo..."
        opkg install sudo || exit_on_error "Failed to install sudo"
    fi

    # Verify sudo permissions
    echo "Verifying sudo permissions for moonrakeruser..."
    echo "moonrakeruser ALL=(ALL) NOPASSWD: ALL" | sudo EDITOR='tee -a' visudo

    # Verify sudo and bash installations
    sudo bash -c "echo 'Sudo and Bash are working for moonrakeruser'"
EOF
}

# Fix sudo ownership and permissions
chown root:root /opt/bin/sudo
chmod 4755 /opt/bin/sudo

# Verify moonrakeruser permissions
verify_moonrakeruser_permissions || exit_on_error "Failed to verify moonrakeruser permissions"

# Switch to moonrakeruser and run the install_moonraker.sh script
su - moonrakeruser << 'EOF'
# Set PATH to include Entware binaries
export PATH=$PATH:/opt/bin:/opt/sbin

# Run the Moonraker installation script
sh /usr/data/creality-k1-setup/scripts/install_moonraker.sh
EOF

# Check if Nginx is installed
NGINX_PATH="/opt/sbin/nginx"
if [ -z "$NGINX_PATH" ]; then
    # Trigger Nginx setup script
    $SCRIPTS_DIR/setup_nginx.sh || exit_on_error "Failed to configure Nginx"
else
    echo "Nginx is already installed. Configuring existing Nginx..."
    cat <<EOF > /opt/etc/nginx/nginx.conf
server {
    listen 80;
    server_name _;

    location /fluidd {
        alias /usr/data/fluidd;
        try_files \$uri \$uri/ /index.html;
    }

    location /mainsail {
        alias /usr/data/mainsail;
        try_files \$uri \$uri/ /index.html;
    }

    location /moonraker {
        proxy_pass http://localhost:7125;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

    # Restart Nginx
    /opt/etc/init.d/S80nginx restart || exit_on_error "Failed to restart Nginx"
fi

echo "Installation complete! Mainsail is running on port 80, and Fluidd is running on port 80 under /fluidd."
