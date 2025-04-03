#!/bin/bash

# Redirect all output to both terminal and start.log
exec > >(tee start.log) 2>&1

# Enable debugging output
set +x

echo "Script started at $(date)"
start_time=$(date +%s)

# Function to load .env variables
load_env() {
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Remove trailing carriage return (for Windows line endings)
        key=$(echo "$key" | tr -d '\r')
        value=$(echo "$value" | tr -d '\r')

        # Skip comments, empty lines, or lines with only spaces
        [[ "$key" =~ ^# ]] && continue
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^[[:space:]]*$ ]] && continue

        # Remove leading/trailing spaces from key and value
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')

        # Skip if key is empty after trimming
        [[ -z "$key" ]] && continue

        # Evaluate the value to handle variable substitution (e.g., ${APP_NAME})
        eval "value=\"$value\""

        # Export the variable
        export "$key=$value"
    done < .env
}

# Load .env variables
if [ -f ".env" ]; then
    echo "Loading .env file..."
    load_env
else
    echo "Error: .env file not found."
    exit 1
fi

# Compute derived variables
export APP_HOSTNAME="${APP_NAME}.local"
export BASE_URL="${APP_HOSTNAME}:${APP_PORT}"
export DB_CONTAINER="${APP_NAME}-db"
export DB_NAME="${APP_NAME}"
export ADMINER_HOSTNAME="${APP_NAME}-db.local"
export ADMINER_URL="${ADMINER_HOSTNAME}:${ADMINER_PORT}"
export NGINX_SERVER_NAME="${APP_HOSTNAME}"
export API_END="http://${BASE_URL}/wp-json/wc/v3/products"

# Check if required variables are set and identify the missing one
missing_vars=""
for var in DB_USER DB_USER_ID DB_PASSWORD SQL_FILE CONSUMER_KEY CONSUMER_SECRET WOO_FILE_NAME WOO_VER APP_PORT ADMINER_PORT APP_NAME; do
    if [ -z "${!var}" ]; then
        missing_vars+="$var "
    fi
done

if [ -n "$missing_vars" ]; then
    echo "Error: Missing required variables in .env file: $missing_vars"
    exit 1
fi

# Function to update the hosts file
update_hosts_file() {
    local app_hostname="$APP_HOSTNAME"
    local adminer_hostname="$ADMINER_HOSTNAME"
    local hosts_file=""
    local os_type=""

    # Detect the operating system
    if [[ "$OSTYPE" == "darwin"* ]]; then
        os_type="macOS"
        hosts_file="/etc/hosts"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        os_type="Linux"
        hosts_file="/etc/hosts"
    elif [[ -n "$COMSPEC" ]] || [[ "$OS" == "Windows_NT" ]]; then
        os_type="Windows"
        hosts_file="/c/Windows/System32/drivers/etc/hosts"
    else
        echo "Error: Unsupported operating system."
        exit 1
    fi

    echo "Detected operating system: $os_type"

    # Check if the hosts file exists
    if [ ! -f "$hosts_file" ]; then
        echo "Error: Hosts file not found at $hosts_file."
        exit 1
    fi

    # Check if the hostnames already exist in the hosts file
    if grep -q "127.0.0.1[[:space:]]*$app_hostname" "$hosts_file" && grep -q "127.0.0.1[[:space:]]*$adminer_hostname" "$hosts_file"; then
        echo "Hostnames $app_hostname and $adminer_hostname already exist in $hosts_file. Skipping update."
        return 0
    fi

    # Prepare the entries to add
    local entries=""
    if ! grep -q "127.0.0.1[[:space:]]*$app_hostname" "$hosts_file"; then
        entries+="127.0.0.1 $app_hostname\n"
    fi
    if ! grep -q "127.0.0.1[[:space:]]*$adminer_hostname" "$hosts_file"; then
        entries+="127.0.0.1 $adminer_hostname\n"
    fi

    # If no entries need to be added, exit early
    if [ -z "$entries" ]; then
        echo "No new host entries to add."
        return 0
    fi

    # Update the hosts file based on the operating system
    if [ "$os_type" = "macOS" ] || [ "$os_type" = "Linux" ]; then
        # macOS/Linux: Use sudo to append to the hosts file
        echo "Updating hosts file at $hosts_file..."
        echo "You may be prompted for your sudo password to modify the hosts file."
        echo -e "$entries" | sudo tee -a "$hosts_file" > /dev/null || { echo "Error: Failed to update hosts file."; exit 1; }
        echo "Hosts file updated successfully."
    elif [ "$os_type" = "Windows" ]; then
        # Windows: Check if running in an elevated context
        echo "On Windows, modifying the hosts file requires elevated privileges."
        echo "Please ensure you are running this script in an elevated terminal (e.g., PowerShell as Administrator)."

        # Check if we have permission to write to the hosts file
        touch "$hosts_file" 2>/dev/null
        if [ $? -ne 0 ]; then
            echo "Error: No permission to modify $hosts_file. Please run this script in an elevated terminal."
            echo "To run in PowerShell as Administrator:"
            echo "1. Open PowerShell as Administrator."
            echo "2. Navigate to this directory: cd $(pwd)"
            echo "3. Run the script: bash start.sh"
            exit 1
        fi

        # Append the entries to the hosts file
        echo "Updating hosts file at $hosts_file..."
        echo -e "$entries" >> "$hosts_file" || { echo "Error: Failed to update hosts file."; exit 1; }
        echo "Hosts file updated successfully."
    fi
}

# Check if required commands are available
for cmd in curl docker docker-compose tar; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "Error: $cmd is not installed or not in PATH."
        exit 1
    else
        echo "$cmd is available: $($cmd --version)"
    fi
done

# Update the hosts file with APP_HOSTNAME and ADMINER_HOSTNAME
update_hosts_file

# Check if WordPress is already present by looking for key files/directories
wordpress_present=true
for wp_item in wp-config-sample.php wp-content wp-admin wp-includes; do
    if [ ! -e "$wp_item" ]; then
        wordpress_present=false
        break
    fi
done

# Check if $WP_FILE_NAME exists
wordpress_tar_exists=false
if [ -f "$WP_FILE_NAME" ]; then
    wordpress_tar_exists=true
    echo "$WP_FILE_NAME already exists in the working directory."
fi

# Download and/or extract WordPress only if it's not present
if [ "$wordpress_present" = false ]; then
    if [ "$wordpress_tar_exists" = false ]; then
        echo "WordPress not detected and $WP_FILE_NAME not found. Downloading now..."
        curl -O https://wordpress.org/wordpress-6.7.2.tar.gz || { echo "Error downloading WordPress"; exit 1; }
    else
        echo "WordPress not detected, but $WP_FILE_NAME found. Skipping download."
    fi
    echo "Extracting WordPress files directly to current directory..."
    tar -xzf $WP_FILE_NAME -C . --strip-components=1 || { echo "Error extracting WordPress"; exit 1; }
    echo "WordPress files extracted to the working directory."
else
    echo "WordPress files already present in the working directory. Skipping download and extraction."
fi

# Remove all running & build new containers
echo "Stopping and removing existing containers..."
docker-compose down || { echo "Error stopping containers"; exit 1; }
echo "Building containers..."
docker-compose build --no-cache || { echo "Error building containers"; exit 1; }
echo "Starting containers..."
docker-compose up -d || { echo "Error starting containers"; exit 1; }

echo "Waiting for MySQL to be ready from PHP container..."
until docker exec -i woouirebuild-php-app mysqladmin ping -hdb -u"$DB_USER" -p"$DB_PASSWORD" --silent; do
    echo "MySQL is unavailable from PHP container - waiting..."
    sleep 3
done
echo "MySQL is ready from PHP container!"

# Create wp-config.php if it doesn’t exist
if [ ! -f "wp-config.php" ]; then
    echo "Creating wp-config.php..."
    docker exec -i woouirebuild-php-app wp config create --dbname="$DB_NAME" --dbuser="$DB_USER_ID" --dbpass="$DB_PASSWORD" --dbhost="db" --allow-root || { echo "Error creating wp-config.php"; exit 1; }
    # Add FS_METHOD to bypass FTP prompt for manual installs
    docker exec -i woouirebuild-php-app wp config set FS_METHOD direct --type=constant --allow-root || { echo "Error setting FS_METHOD"; exit 1; }
else
    echo "wp-config.php already exists, skipping creation."
fi

# Ensure database connection from PHP container
echo "Verifying database connection from PHP container..."
docker exec -i woouirebuild-php-app wp db check --allow-root || { echo "Error: PHP container cannot connect to database"; exit 1; }

# Check if WordPress is already installed
echo "Checking if WordPress is already installed..."
if docker exec -i woouirebuild-php-app wp core is-installed --allow-root 2>/dev/null; then
    echo "WordPress is already installed, updating URLs..."
    docker exec -i woouirebuild-php-app wp option update siteurl "http://$BASE_URL" --allow-root || { echo "Error updating siteurl"; exit 1; }
    docker exec -i woouirebuild-php-app wp option update home "http://$BASE_URL" --allow-root || { echo "Error updating home"; exit 1; }
else
    echo "Installing WordPress..."
    docker exec -i woouirebuild-php-app wp core install --url="http://$BASE_URL" --title="woouirebuild" --admin_user="adminuser" --admin_password="adminpw" --admin_email="adminuser@localhost.com" --allow-root || { echo "Error installing WordPress"; exit 1; }
fi

# Verify WordPress installation
docker exec -i woouirebuild-php-app wp core is-installed --allow-root || { echo "WordPress installation failed verification"; exit 1; }

# Wait briefly to ensure WordPress is fully initialized
echo "Waiting for WordPress to stabilize..."
sleep 5

# Fix permissions for wp-content/plugins to allow WP-CLI to write
echo "Fixing permissions for wp-content/plugins..."
docker exec -i woouirebuild-php-app bash -c "chown -R www-data:www-data /var/www/html/wp-content/plugins" || { echo "Error fixing permissions for plugins directory"; exit 1; }
docker exec -i woouirebuild-php-app bash -c "chmod -R 775 /var/www/html/wp-content/plugins" || { echo "Error setting permissions for plugins directory"; exit 1; }

# Check if WooCommerce ZIP file exists
woocommerce_zip_exists=false
if [ -f "$WOO_FILE_NAME" ]; then
    woocommerce_zip_exists=true
    echo "$WOO_FILE_NAME already exists in the working directory."
fi

# Install and activate WooCommerce
echo "Installing and activating WooCommerce $WOO_VER..."
if [ "$woocommerce_zip_exists" = true ]; then
    echo "Using existing $WOO_FILE_NAME for installation..."
    docker exec -i woouirebuild-php-app bash -c "wp plugin install /var/www/html/$WOO_FILE_NAME --activate --allow-root" || { echo "Error installing WooCommerce from local file"; exit 1; }
else
    echo "$WOO_FILE_NAME not found, downloading and installing WooCommerce $WOO_VER..."
    docker exec -i woouirebuild-php-app wp plugin install woocommerce --version="$WOO_VER" --activate --allow-root || { echo "Error downloading and installing WooCommerce $WOO_VER"; exit 1; }
fi

# Verify WooCommerce installation and activation
docker exec -i woouirebuild-php-app wp plugin list --name=woocommerce --allow-root | grep "active" || { echo "WooCommerce $WOO_VER not activated"; exit 1; }
docker exec -i woouirebuild-php-app wp plugin list --name=woocommerce --allow-root | grep "$WOO_VER" || { echo "WooCommerce version $WOO_VER not installed correctly"; exit 1; }

# Run database migration script
echo "Running database migration script ($SQL_FILE)..."
docker exec -i "$DB_CONTAINER" mysql -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$SQL_FILE" || { echo "Error running migration script $SQL_FILE"; exit 1; }

# Output URLs
app_url="http://$BASE_URL"
db_url="http://$ADMINER_URL"

echo "Go to $app_url for the app"
echo "Go to $db_url for the db"

echo "Setup complete at $(date)!"
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
hours=$((elapsed_time / 3600))
minutes=$(((elapsed_time % 3600) / 60))
seconds=$((elapsed_time % 60))
printf "Elapsed time: %02d:%02d:%02d\n" $hours $minutes $seconds

# Keep the terminal open to see output
echo "Press any key to exit..."

# Countdown timer before closing
echo "Closing in..."
for i in {60..1}; do
    echo -ne "\033[31m$i\033[0m seconds remaining...\r"
    sleep 1
done

read -n 1 -s
