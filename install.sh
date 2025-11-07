#!/bin/bash

# Enhanced Nginx Reverse Proxy Installation Script
# Version: 2.0
# This script provides comprehensive error handling, detailed logging, and safety features

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log file
LOG_FILE="/var/log/nginx-reverse-proxy-installer.log"
BACKUP_DIR="/var/backups/nginx-reverse-proxy"
ERROR_COUNT=0

# Initialize log file and backup directory
init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
}

# Enhanced logging function with error codes (logs to file only)
log_message() {
    local level="$1"
    local message="$2"
    local error_code="${3:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ -n "$error_code" ]]; then
        echo -e "[$timestamp] [$level] [CODE:$error_code] $message" >> "$LOG_FILE"
    else
        echo -e "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Enhanced print status with error codes (clean console output, detailed logs)
print_status() {
    local status="$1"
    local message="$2"
    local error_code="${3:-}"
    
    # Log full details to file
    log_message "$(echo "$status" | tr '[:lower:]' '[:upper:]')" "$message" "$error_code"
    
    # Clean console output
    case $status in
        "success") 
            echo -e "  ${GREEN}✓${NC} ${message}"
            ;;
        "error") 
            echo -e "  ${RED}✗${NC} ${message}"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            ;;
        "warning") 
            echo -e "  ${YELLOW}⚠${NC} ${message}"
            ;;
        "info") 
            echo -e "  ${BLUE}→${NC} ${message}"
            ;;
    esac
}

# Function to validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [[ $i -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    elif [[ "$ip" == "localhost" ]] || [[ "$ip" == "127.0.0.1" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate backend address (IP or domain)
validate_backend_address() {
    local address="$1"
    # Accept IP addresses, localhost, or domain names
    if validate_ip "$address"; then
        return 0
    elif validate_domain "$address"; then
        return 0
    elif [[ "$address" == "localhost" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate domain name format
validate_domain() {
    local domain="$1"
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check DNS resolution
check_dns_resolution() {
    local domain="$1"
    print_status "info" "Checking DNS resolution for $domain..." "DNS001"
    
    # Try to resolve domain
    if command -v dig &> /dev/null; then
        if dig +short "$domain" @8.8.8.8 | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            print_status "success" "DNS resolution successful for $domain" "DNS002"
            return 0
        fi
    elif command -v nslookup &> /dev/null; then
        if nslookup "$domain" 2>/dev/null | grep -qE 'Address:.*[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'; then
            print_status "success" "DNS resolution successful for $domain" "DNS002"
            return 0
        fi
    elif command -v host &> /dev/null; then
        if host "$domain" 2>/dev/null | grep -qE 'has address.*[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'; then
            print_status "success" "DNS resolution successful for $domain" "DNS002"
            return 0
        fi
    fi
    
    print_status "warning" "Could not verify DNS resolution. Make sure your domain points to this server." "DNS003"
    return 1
}

# Function to check backend connectivity
check_backend_connectivity() {
    local ip="$1"
    local port="$2"
    
    print_status "info" "Checking backend server connectivity at $ip:$port..." "CONN001"
    
    # Use timeout to prevent hanging
    if command -v timeout &> /dev/null; then
        if timeout 5 bash -c "echo > /dev/tcp/$ip/$port" 2>/dev/null; then
            print_status "success" "Backend server is reachable at $ip:$port" "CONN002"
            return 0
        else
            print_status "warning" "Cannot connect to backend server at $ip:$port. Make sure it's running." "CONN003"
            return 1
        fi
    else
        # Fallback: try nc if available
        if command -v nc &> /dev/null; then
            if nc -z -w 5 "$ip" "$port" 2>/dev/null; then
                print_status "success" "Backend server is reachable at $ip:$port" "CONN002"
                return 0
            else
                print_status "warning" "Cannot connect to backend server at $ip:$port. Make sure it's running." "CONN003"
                return 1
            fi
        else
            print_status "warning" "Cannot verify backend connectivity. Please ensure the server is running." "CONN004"
            return 1
        fi
    fi
}

# Function to validate yes/no input
validate_yes_no() {
    local input="$1"
    local default="$2"
    
    input_lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    
    if [[ -z "$input" && -n "$default" ]]; then
        echo "$default"
        return 0
    fi
    
    case "$input_lower" in
        "yes"|"y") echo "yes"; return 0 ;;
        "no"|"n") echo "no"; return 0 ;;
        *) return 1 ;;
    esac
}

# Function to validate email format
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to extract IP from URL
extract_ip() {
    local input="$1"
    echo "$input" | sed -e 's|^[^/]*//||' -e 's|[:/].*$||' -e 's|^.*@||' | sed 's|^www\.||'
}

# Function to extract port from URL
extract_port() {
    local input="$1"
    if echo "$input" | grep -q ':'; then
        echo "$input" | sed 's/^.*://' | sed 's/[^0-9].*$//'
    else
        echo "$input"
    fi
}

# Function to create backup
create_backup() {
    local backup_name="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="$BACKUP_DIR/${backup_name}_${timestamp}"
    
    print_status "info" "Creating backup: $backup_path" "BACKUP001"
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_DIR" 2>/dev/null || {
        print_status "error" "Failed to create backup base directory: $BACKUP_DIR" "BACKUP002A"
        return 1
    }
    
    mkdir -p "$backup_path" 2>/dev/null || {
        print_status "error" "Failed to create backup directory: $backup_path" "BACKUP002"
        return 1
    }
    
    # Backup nginx config files if nginx directory exists
    if [[ -d "/etc/nginx" ]]; then
        # Backup nginx.conf specifically first (most important)
        if [[ -f "/etc/nginx/nginx.conf" ]]; then
            cp /etc/nginx/nginx.conf "$backup_path/nginx.conf.original" 2>/dev/null || {
                print_status "warning" "Could not backup nginx.conf" "BACKUP003A"
            }
        fi
        
        # Backup sites-available if it exists
        if [[ -d "/etc/nginx/sites-available" ]]; then
            cp -r /etc/nginx/sites-available "$backup_path/" 2>/dev/null || {
                print_status "warning" "Could not backup sites-available" "BACKUP003B"
            }
        fi
        
        # Backup sites-enabled if it exists
        if [[ -d "/etc/nginx/sites-enabled" ]]; then
            cp -r /etc/nginx/sites-enabled "$backup_path/" 2>/dev/null || {
                print_status "warning" "Could not backup sites-enabled" "BACKUP003C"
            }
        fi
        
        # Try to backup other important files
        cp -r /etc/nginx/* "$backup_path/" 2>/dev/null || {
            print_status "warning" "Some files could not be backed up" "BACKUP003"
        }
    else
        print_status "warning" "/etc/nginx directory does not exist yet (nginx may not be installed)" "BACKUP003D"
        # Create an empty marker file so we know backup was attempted
        touch "$backup_path/.backup_marker" 2>/dev/null || true
    fi
    
    print_status "success" "Backup created successfully at: $backup_path" "BACKUP004"
    echo "$backup_path"
    return 0
}

# Function to restore from backup
restore_backup() {
    local backup_path="$1"
    
    if [[ ! -d "$backup_path" ]]; then
        print_status "error" "Backup directory not found: $backup_path" "RESTORE001"
        return 1
    fi
    
    print_status "info" "Restoring from backup: $backup_path" "RESTORE002"
    
    # Restore nginx.conf if it exists in backup
    if [[ -f "$backup_path/nginx.conf.original" ]]; then
        cp "$backup_path/nginx.conf.original" /etc/nginx/nginx.conf 2>/dev/null || {
            print_status "error" "Failed to restore nginx.conf" "RESTORE003"
            return 1
        }
    fi
    
    print_status "success" "Backup restored successfully" "RESTORE004"
    return 0
}

# Function to rollback installation on failure
rollback_installation() {
    local backup_path="$1"
    local domain="$2"
    
    print_status "error" "Installation failed. Rolling back changes..." "ROLLBACK001"
    
    # Remove the configuration file if it was created
    if [[ -n "$domain" ]]; then
        if [[ -f "/etc/nginx/sites-available/$domain" ]]; then
            rm -f "/etc/nginx/sites-available/$domain" 2>/dev/null || true
            print_status "info" "Removed configuration file: /etc/nginx/sites-available/$domain" "ROLLBACK002"
        fi
        
        # Remove the symlink if it was created
        if [[ -L "/etc/nginx/sites-enabled/$domain" ]]; then
            rm -f "/etc/nginx/sites-enabled/$domain" 2>/dev/null || true
            print_status "info" "Removed symlink: /etc/nginx/sites-enabled/$domain" "ROLLBACK003"
        fi
        
        # Remove any temporary files
        rm -f "/etc/nginx/sites-available/$domain.tmp" 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/$domain.backup"* 2>/dev/null || true
        rm -f "/etc/nginx/sites-available/${domain}.pre-certbot" 2>/dev/null || true
    fi
    
    # Restore from backup if available
    if [[ -n "$backup_path" ]] && [[ -d "$backup_path" ]]; then
        print_status "info" "Restoring nginx configuration from backup..." "ROLLBACK004"
        
        # Restore nginx.conf if it was modified
        if [[ -f "$backup_path/nginx.conf.original" ]]; then
            cp "$backup_path/nginx.conf.original" /etc/nginx/nginx.conf 2>/dev/null && {
                print_status "success" "Restored nginx.conf from backup" "ROLLBACK005"
            } || {
                print_status "warning" "Could not restore nginx.conf from backup" "ROLLBACK006"
            }
        fi
        
        # Test nginx configuration
        if nginx -t >> "$LOG_FILE" 2>&1; then
            # Try to reload nginx to apply restored config
            systemctl reload nginx >> "$LOG_FILE" 2>&1 || {
                systemctl restart nginx >> "$LOG_FILE" 2>&1 || true
            }
            print_status "success" "Nginx configuration restored and reloaded" "ROLLBACK007"
        else
            print_status "warning" "Nginx configuration test failed after rollback. Manual intervention may be required." "ROLLBACK008"
        fi
    else
        print_status "warning" "No backup available to restore from" "ROLLBACK009"
    fi
    
    print_status "info" "Rollback completed. System should be in the state before installation started." "ROLLBACK010"
}

# Function to check if configuration already exists
check_existing_config() {
    local domain="$1"
    local config_file="/etc/nginx/sites-available/$domain"
    
    if [[ -f "$config_file" ]]; then
        print_status "warning" "Configuration already exists for $domain" "CONFIG001"
        read -p "Do you want to overwrite it? (yes/no): " OVERWRITE
        
        if ! validate_yes_no "$OVERWRITE" "no" | grep -q "yes"; then
            print_status "info" "Operation cancelled by user" "CONFIG002"
            return 1
        fi
        
        # Create backup of existing config
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        print_status "info" "Existing configuration backed up" "CONFIG003"
    fi
    
    return 0
}

# Function to check if nginx is running
check_nginx_status() {
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        print_status "warning" "Nginx is not running. Attempting to start..." "NGINX001"
        if systemctl start nginx >> "$LOG_FILE" 2>&1; then
            print_status "success" "Nginx started successfully" "NGINX002"
            sleep 2
        else
            print_status "error" "Failed to start Nginx. Please check system logs." "NGINX003"
            return 1
        fi
    fi
    return 0
}

# Function to show main menu
show_menu() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║     NGINX Reverse Proxy Manager           ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo "  1. Install Reverse Proxy"
    echo "  2. Renew Reverse Proxy"
    echo "  3. Remove Reverse Proxy"
    echo "  4. View Logs"
    echo "  5. Exit"
    echo ""
    read -p "  Select an option (1-5): " MENU_CHOICE
}

# Function to calculate days until certificate expiration
calculate_days_until_expiry() {
    local cert_file="$1"
    if [[ ! -f "$cert_file" ]]; then
        echo "0"
        return
    fi
    
    # Get expiration date from certificate (format: notAfter=Mon Jan 15 12:00:00 2024 GMT)
    local expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry_date" ]]; then
        echo "0"
        return
    fi
    
    # Convert to epoch timestamp
    local expiry_epoch=0
    if command -v date &> /dev/null; then
        # Try Linux date format first (GNU date)
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null)
        
        # If that failed, try BSD/macOS date format
        if [[ -z "$expiry_epoch" ]] || [[ "$expiry_epoch" == "0" ]]; then
            # Parse the date string (e.g., "Mon Jan 15 12:00:00 2024 GMT")
            # Remove GMT and try to parse
            local date_part=$(echo "$expiry_date" | sed 's/ GMT$//')
            expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y" "$date_part" +%s 2>/dev/null || echo "0")
        fi
    fi
    
    if [[ -z "$expiry_epoch" ]] || [[ "$expiry_epoch" == "0" ]]; then
        echo "0"
        return
    fi
    
    # Get current epoch
    local current_epoch=$(date +%s 2>/dev/null || echo "0")
    if [[ "$current_epoch" == "0" ]]; then
        echo "0"
        return
    fi
    
    # Calculate days difference
    local diff_seconds=$((expiry_epoch - current_epoch))
    local diff_days=$((diff_seconds / 86400))
    
    echo "$diff_days"
}

# Function to renew reverse proxy certificate
renew_reverse_proxy() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║      Renew Reverse Proxy Certificate       ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    # Check if certbot is installed
    if ! command -v certbot &> /dev/null; then
        print_status "error" "Certbot is not installed. Cannot renew certificates." "RENEW001"
        return 1
    fi
    
    # Check if Let's Encrypt directory exists
    if [[ ! -d "/etc/letsencrypt/live" ]]; then
        print_status "info" "No SSL certificates found." "RENEW002"
        return 0
    fi
    
    # Get list of certificates
    local certs=($(ls -d /etc/letsencrypt/live/*/ 2>/dev/null | grep -v "README" | xargs -n1 basename))
    
    if [[ ${#certs[@]} -eq 0 ]]; then
        print_status "info" "No SSL certificates found." "RENEW002"
        return 0
    fi
    
    echo "  Available certificates:"
    echo ""
    
    local cert_list=()
    local i=1
    for cert in "${certs[@]}"; do
        local cert_path="/etc/letsencrypt/live/$cert/fullchain.pem"
        if [[ -f "$cert_path" ]]; then
            local days_left=$(calculate_days_until_expiry "$cert_path")
            
            if [[ "$days_left" -lt 0 ]]; then
                echo -e "    ${i}. ${cert} ${RED}(EXPIRED ${days_left#-} days ago)${NC}"
            elif [[ "$days_left" -lt 30 ]]; then
                echo -e "    ${i}. ${cert} ${YELLOW}($days_left days until expiry)${NC}"
            else
                echo -e "    ${i}. ${cert} ${GREEN}($days_left days until expiry)${NC}"
            fi
            
            cert_list+=("$cert")
            i=$((i + 1))
        fi
    done
    
    echo ""
    read -p "  Enter the number of the certificate to renew: " RENEW_CHOICE
    
    if [[ ! "$RENEW_CHOICE" =~ ^[0-9]+$ ]] || [ "$RENEW_CHOICE" -lt 1 ] || [ "$RENEW_CHOICE" -gt ${#cert_list[@]} ]; then
        print_status "error" "Invalid selection." "RENEW003"
        return 1
    fi
    
    local selected_cert="${cert_list[$((RENEW_CHOICE-1))]}"
    
    echo ""
    print_status "info" "Renewing certificate for: $selected_cert" "RENEW004"
    echo ""
    
    # Renew the certificate
    if certbot renew --cert-name "$selected_cert" --force-renewal >> "$LOG_FILE" 2>&1; then
        print_status "success" "Certificate renewed successfully for $selected_cert" "RENEW005"
        
        # Reload nginx to use the new certificate
        if nginx -t >> "$LOG_FILE" 2>&1; then
            if systemctl reload nginx >> "$LOG_FILE" 2>&1; then
                print_status "success" "Nginx reloaded with new certificate" "RENEW006"
            else
                print_status "warning" "Certificate renewed but nginx reload failed. Please reload manually." "RENEW007"
            fi
        else
            print_status "warning" "Certificate renewed but nginx configuration test failed." "RENEW008"
        fi
        
        return 0
    else
        print_status "error" "Failed to renew certificate for $selected_cert" "RENEW009"
        print_status "info" "Check logs for details: $LOG_FILE" "RENEW010"
        return 1
    fi
}

# Function to remove reverse proxy
remove_reverse_proxy() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║      Remove Reverse Proxy Configuration    ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    # Create backup before removal
    create_backup "pre_removal_$(date +%Y%m%d_%H%M%S)" > /dev/null 2>&1
    
    if [[ ! -d "/etc/nginx/sites-available" ]]; then
        print_status "info" "No reverse proxy configurations found." "REMOVE001"
        return 0
    fi
    
    local sites=($(ls /etc/nginx/sites-available/ 2>/dev/null | grep -v "default" | grep -v "^$"))
    if [[ ${#sites[@]} -eq 0 ]]; then
        print_status "info" "No reverse proxy configurations found." "REMOVE001"
        return 0
    fi
    
    echo "  Available configurations:"
    for i in "${!sites[@]}"; do
        echo "    $((i+1)). ${sites[$i]}"
    done
    echo ""
    
    read -p "  Enter the number of the configuration to remove: " REMOVE_CHOICE
    
    if [[ ! "$REMOVE_CHOICE" =~ ^[0-9]+$ ]] || [ "$REMOVE_CHOICE" -lt 1 ] || [ "$REMOVE_CHOICE" -gt ${#sites[@]} ]; then
        print_status "error" "Invalid selection." "REMOVE002"
        return 1
    fi
    
    local selected_site="${sites[$((REMOVE_CHOICE-1))]}"
    
    read -p "  Are you sure you want to remove '$selected_site'? (yes/no): " CONFIRM_REMOVE
    if ! validate_yes_no "$CONFIRM_REMOVE" "no" | grep -q "yes"; then
        print_status "info" "Removal cancelled." "REMOVE003"
        return 0
    fi
    
    print_status "info" "Removing configuration for $selected_site..." "REMOVE004"
    
    # Remove from sites-enabled
    if [[ -f "/etc/nginx/sites-enabled/$selected_site" ]]; then
        rm -f "/etc/nginx/sites-enabled/$selected_site" || {
            print_status "error" "Failed to remove symlink" "REMOVE005"
            return 1
        }
    fi
    
    # Remove from sites-available
    if [[ -f "/etc/nginx/sites-available/$selected_site" ]]; then
        rm -f "/etc/nginx/sites-available/$selected_site" || {
            print_status "error" "Failed to remove configuration file" "REMOVE006"
            return 1
        }
    fi
    
    # Test configuration
    if nginx -t >> "$LOG_FILE" 2>&1; then
        if systemctl reload nginx >> "$LOG_FILE" 2>&1; then
            print_status "success" "Reverse proxy configuration for '$selected_site' removed successfully." "REMOVE007"
            return 0
        else
            print_status "error" "Failed to reload NGINX. Configuration was removed but NGINX needs manual reload." "REMOVE008"
            return 1
        fi
    else
        print_status "error" "Configuration test failed after removal. Please check NGINX configuration manually." "REMOVE009"
        return 1
    fi
}

# Function to show welcome message
show_welcome() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║  NGINX Reverse Proxy Configuration Wizard  ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo -e "  ${YELLOW}⚠ IMPORTANT: Before continuing, make sure you have:${NC}"
    echo ""
    echo "  1. Created an A record in your DNS for your domain"
    echo "     pointing to this server's IP"
    echo "  2. Allowed time for DNS propagation"
    echo "     (can take up to 24 hours)"
    echo "  3. Your backend application is running and accessible"
    echo ""
    read -p "  Press Enter to continue once your DNS is configured... " 
    echo ""
    log_message "INFO" "Starting NGINX Reverse Proxy installation" "WELCOME001"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_status "error" "This script must be run as root. Please use: sudo $0" "ROOT001"
        exit 1
    fi
}

# Function to check dependencies
check_dependencies() {
    local missing_deps=()
    
    if ! command -v nginx &> /dev/null; then
        missing_deps+=("nginx")
    fi
    
    if [[ "$ENABLE_SSL" == "yes" ]] && ! command -v certbot &> /dev/null; then
        missing_deps+=("certbot")
    fi
    
    if [[ ${#missing_deps[@]} -ne 0 ]]; then
        print_status "info" "Missing dependencies detected: ${missing_deps[*]}" "DEPS001"
        return 1
    fi
    
    return 0
}

# Function to install dependencies
install_dependencies() {
    print_status "info" "Installing required packages..." "INSTALL001"
    
    local nginx_installed=0
    local certbot_installed=0
    
    if command -v apt &> /dev/null; then
        # Always install nginx if missing
        if ! command -v nginx &> /dev/null; then
            print_status "info" "Installing nginx..." "INSTALL001A"
            if apt update >> "$LOG_FILE" 2>&1 && apt install -y nginx >> "$LOG_FILE" 2>&1; then
                nginx_installed=1
                print_status "success" "Nginx installed successfully" "INSTALL001B"
            else
                print_status "error" "Failed to install nginx" "INSTALL001C"
                return 1
            fi
        else
            nginx_installed=1
            print_status "info" "Nginx is already installed" "INSTALL001D"
        fi
        
        # Install certbot if SSL is enabled and certbot is missing
        if [[ "$ENABLE_SSL" == "yes" ]] && ! command -v certbot &> /dev/null; then
            print_status "info" "Installing certbot..." "INSTALL001E"
            if apt install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1; then
                certbot_installed=1
                print_status "success" "Certbot installed successfully" "INSTALL001F"
            else
                print_status "warning" "Certbot installation had issues. SSL may not work." "INSTALL002"
            fi
        elif [[ "$ENABLE_SSL" == "yes" ]]; then
            certbot_installed=1
            print_status "info" "Certbot is already installed" "INSTALL001G"
        fi
        
    elif command -v yum &> /dev/null; then
        # Always install nginx if missing
        if ! command -v nginx &> /dev/null; then
            print_status "info" "Installing nginx..." "INSTALL001A"
            if yum install -y epel-release >> "$LOG_FILE" 2>&1 && yum install -y nginx >> "$LOG_FILE" 2>&1; then
                nginx_installed=1
                print_status "success" "Nginx installed successfully" "INSTALL001B"
            else
                print_status "error" "Failed to install nginx" "INSTALL001C"
                return 1
            fi
        else
            nginx_installed=1
            print_status "info" "Nginx is already installed" "INSTALL001D"
        fi
        
        # Install certbot if SSL is enabled and certbot is missing
        if [[ "$ENABLE_SSL" == "yes" ]] && ! command -v certbot &> /dev/null; then
            print_status "info" "Installing certbot..." "INSTALL001E"
            if yum install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1; then
                certbot_installed=1
                print_status "success" "Certbot installed successfully" "INSTALL001F"
            else
                print_status "warning" "Certbot installation had issues. SSL may not work." "INSTALL002"
            fi
        elif [[ "$ENABLE_SSL" == "yes" ]]; then
            certbot_installed=1
            print_status "info" "Certbot is already installed" "INSTALL001G"
        fi
        
    elif command -v dnf &> /dev/null; then
        # Always install nginx if missing
        if ! command -v nginx &> /dev/null; then
            print_status "info" "Installing nginx..." "INSTALL001A"
            if dnf install -y nginx >> "$LOG_FILE" 2>&1; then
                nginx_installed=1
                print_status "success" "Nginx installed successfully" "INSTALL001B"
            else
                print_status "error" "Failed to install nginx" "INSTALL001C"
                return 1
            fi
        else
            nginx_installed=1
            print_status "info" "Nginx is already installed" "INSTALL001D"
        fi
        
        # Install certbot if SSL is enabled and certbot is missing
        if [[ "$ENABLE_SSL" == "yes" ]] && ! command -v certbot &> /dev/null; then
            print_status "info" "Installing certbot..." "INSTALL001E"
            if dnf install -y certbot python3-certbot-nginx >> "$LOG_FILE" 2>&1; then
                certbot_installed=1
                print_status "success" "Certbot installed successfully" "INSTALL001F"
            else
                print_status "warning" "Certbot installation had issues. SSL may not work." "INSTALL002"
            fi
        elif [[ "$ENABLE_SSL" == "yes" ]]; then
            certbot_installed=1
            print_status "info" "Certbot is already installed" "INSTALL001G"
        fi
        
    else
        print_status "error" "Unsupported package manager. Please install NGINX manually first." "INSTALL003"
        return 1
    fi
    
    if [[ $nginx_installed -eq 1 ]]; then
        print_status "success" "All required packages are installed" "INSTALL004"
        return 0
    else
        print_status "error" "Failed to install required packages" "INSTALL005"
        return 1
    fi
}

# Function to get user input with validation
get_user_input() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║         Configuration Input                ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    # Get backend server details
    local port_provided=false
    while true; do
        read -p "Enter the backend server IP address / domain or hostname (e.g., 127.0.0.1, localhost, or node01.domain.com): " BACKEND_IP_INPUT
        if [[ -n "$BACKEND_IP_INPUT" ]]; then
            # Check if port is included in the input (contains colon followed by numbers)
            if echo "$BACKEND_IP_INPUT" | grep -qE ':[0-9]+'; then
                # Extract IP/domain and port separately
                BACKEND_IP=$(extract_ip "$BACKEND_IP_INPUT")
                BACKEND_PORT=$(extract_port "$BACKEND_IP_INPUT")
                port_provided=true
                
                # Validate the extracted port
                if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ]; then
                    # Validate the backend address
                    if validate_backend_address "$BACKEND_IP"; then
                        print_status "info" "Detected port $BACKEND_PORT in input. Skipping port question." "INPUT000"
                        break
                    else
                        print_status "error" "Invalid backend address format. Please try again." "INPUT001"
                        port_provided=false
                    fi
                else
                    print_status "error" "Invalid port number in input. Please try again." "INPUT001A"
                    port_provided=false
                fi
            else
                # No port in input, just extract the address
                BACKEND_IP=$(extract_ip "$BACKEND_IP_INPUT")
                if [[ -n "$BACKEND_IP" ]]; then
                    # Validate IP, domain, or localhost
                    if validate_backend_address "$BACKEND_IP"; then
                        break
                    else
                        print_status "error" "Invalid IP address or hostname format. Please try again." "INPUT001"
                    fi
                else
                    print_status "error" "Could not extract valid address. Please try again." "INPUT002"
                fi
            fi
        else
            print_status "error" "Backend server address is required. Please try again." "INPUT003"
        fi
    done
    
    # Only ask for port if it wasn't provided in the address input
    if [[ "$port_provided" == "false" ]]; then
        while true; do
            read -p "Enter the backend server port (e.g., 3000, 8080, etc.): " BACKEND_PORT_INPUT
            if [[ -n "$BACKEND_PORT_INPUT" ]]; then
                BACKEND_PORT=$(extract_port "$BACKEND_PORT_INPUT")
                if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] && [ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ]; then
                    # Check if port is already in use by nginx
                    if [[ "$BACKEND_PORT" -eq 80 ]] || [[ "$BACKEND_PORT" -eq 443 ]]; then
                        print_status "warning" "Port $BACKEND_PORT is typically used by Nginx itself. Continue anyway? (yes/no): " "INPUT004"
                        read -p "" CONTINUE_PORT
                        if validate_yes_no "$CONTINUE_PORT" "no" | grep -q "yes"; then
                            break
                        fi
                    else
                        break
                    fi
                else
                    print_status "error" "Port must be a valid number between 1 and 65535. Please try again." "INPUT005"
                fi
            else
                print_status "error" "Backend server port is required. Please try again." "INPUT006"
            fi
        done
    fi
    
    # Get domain name with validation
    while true; do
        read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" ]]; then
            DOMAIN_NAME=$(echo "$DOMAIN_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/^www\.//')
            if validate_domain "$DOMAIN_NAME"; then
                break
            else
                print_status "error" "Invalid domain name format. Please try again." "INPUT007"
            fi
        else
            print_status "error" "Domain name is required. Please try again." "INPUT008"
        fi
    done
    
    # SSL configuration
    while true; do
        read -p "Enable HTTPS/SSL? (yes/no) [yes]: " SSL_INPUT
        ENABLE_SSL=$(validate_yes_no "$SSL_INPUT" "yes")
        if [[ $? -eq 0 ]]; then
            break
        else
            print_status "error" "Please enter 'yes' or 'no'. Please try again." "INPUT009"
        fi
    done
    
    if [[ "$ENABLE_SSL" == "yes" ]]; then
        while true; do
            read -p "Enter your email for SSL certificate (for renewal notices): " SSL_EMAIL
            if validate_email "$SSL_EMAIL"; then
                break
            else
                print_status "error" "Invalid email format. Please enter a valid email address." "INPUT010"
            fi
        done
        
        while true; do
            read -p "Force HTTPS redirect? (yes/no) [yes]: " HTTPS_INPUT
            FORCE_HTTPS=$(validate_yes_no "$HTTPS_INPUT" "yes")
            if [[ $? -eq 0 ]]; then
                break
            else
                print_status "error" "Please enter 'yes' or 'no'. Please try again." "INPUT011"
            fi
        done
    fi
    
    echo ""
}

# Function to validate all input
validate_input() {
    if [[ -z "$BACKEND_IP" || -z "$BACKEND_PORT" || -z "$DOMAIN_NAME" ]]; then
        print_status "error" "Error: All fields are required. Please provide all information." "VALID001"
        return 1
    fi
    
    if ! [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || [ "$BACKEND_PORT" -lt 1 ] || [ "$BACKEND_PORT" -gt 65535 ]; then
        print_status "error" "Error: Port must be a valid number between 1 and 65535" "VALID002"
        return 1
    fi
    
    if [[ "$ENABLE_SSL" == "yes" && -z "$SSL_EMAIL" ]]; then
        print_status "error" "Error: Email address is required for SSL certificate registration" "VALID003"
        return 1
    fi
    
    if ! validate_domain "$DOMAIN_NAME"; then
        print_status "error" "Error: Invalid domain name format" "VALID004"
        return 1
    fi
    
    return 0
}

# Function to create NGINX configuration file safely
create_nginx_config() {
    local config_file="/etc/nginx/sites-available/$DOMAIN_NAME"
    local temp_file="${config_file}.tmp"
    
    # Create config directory if it doesn't exist
    mkdir -p /etc/nginx/sites-available 2>/dev/null || {
        print_status "error" "Failed to create sites-available directory" "CONFIG004"
        return 1
    }
    mkdir -p /etc/nginx/sites-enabled 2>/dev/null || {
        print_status "error" "Failed to create sites-enabled directory" "CONFIG005"
        return 1
    }
    
    print_status "info" "Creating reverse proxy configuration..." "CONFIG006"
    
    # Build access log configuration
    local access_log_config="access_log off;"
    
    # Build redirect configuration (only if HTTPS will be enabled later)
    local redirect_config=""
    # Note: Redirect will be added after SSL certificate is obtained if FORCE_HTTPS is yes
    
    # Create the configuration file
    cat > "$temp_file" << EOF
# Reverse Proxy Configuration for $DOMAIN_NAME
# Generated on $(date)
# Backend: $BACKEND_IP:$BACKEND_PORT

server {
    listen 80;
    server_name $DOMAIN_NAME;
    
    # Logging
    $access_log_config
    
    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Proxy settings
    location / {
        proxy_pass http://$BACKEND_IP:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;
    }
    
    # Block common vulnerabilities
    location ~* /\.(env|git) {
        deny all;
        return 404;
    }
}
EOF

    # Validate the temp file was created
    if [[ ! -f "$temp_file" ]]; then
        print_status "error" "Failed to create configuration file" "CONFIG007"
        return 1
    fi
    
    # Move temp file to final location
    mv "$temp_file" "$config_file" || {
        print_status "error" "Failed to move configuration file to final location" "CONFIG008"
        rm -f "$temp_file"
        return 1
    }
    
    # Enable the site (create symlink)
    if [[ -L "/etc/nginx/sites-enabled/$DOMAIN_NAME" ]]; then
        rm -f "/etc/nginx/sites-enabled/$DOMAIN_NAME" || {
            print_status "warning" "Could not remove existing symlink" "CONFIG010"
        }
    fi
    
    ln -sf "$config_file" "/etc/nginx/sites-enabled/$DOMAIN_NAME" || {
        print_status "error" "Failed to create symlink in sites-enabled" "CONFIG011"
        rm -f "$config_file"
        return 1
    }
    
    # Now test the full nginx configuration (can't test single file in isolation)
    print_status "info" "Validating nginx configuration..." "CONFIG012"
    if nginx -t >> "$LOG_FILE" 2>&1; then
        print_status "success" "Configuration file created and validated successfully" "CONFIG013"
        return 0
    else
        print_status "error" "Configuration file syntax is invalid. Removing file." "CONFIG009"
        # Get error details
        local nginx_test_output=$(nginx -t 2>&1)
        echo "$nginx_test_output" >> "$LOG_FILE"
        print_status "error" "Nginx test output: $nginx_test_output" "CONFIG009A"
        
        # Clean up the files we created
        rm -f "/etc/nginx/sites-enabled/$DOMAIN_NAME"
        rm -f "$config_file"
        return 1
    fi
}

# Function to obtain SSL certificate with better error handling
obtain_ssl_certificate() {
    if [[ "$ENABLE_SSL" != "yes" ]]; then
        return 0
    fi
    
    print_status "info" "Requesting SSL certificate from Let's Encrypt..." "SSL001"
    
    # Check if certificate already exists
    if [[ -f "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem" ]]; then
        print_status "info" "SSL certificate already exists for $DOMAIN_NAME" "SSL002"
        read -p "Do you want to renew it? (yes/no): " RENEW_CERT
        if validate_yes_no "$RENEW_CERT" "no" | grep -q "yes"; then
            certbot renew --cert-name "$DOMAIN_NAME" --force-renewal >> "$LOG_FILE" 2>&1 || {
                print_status "warning" "Certificate renewal failed, but continuing with existing certificate" "SSL003"
            }
        fi
        add_https_configuration
        return 0
    fi
    
    # First ensure nginx is running and config is valid
    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        print_status "error" "Nginx configuration is invalid. Cannot obtain SSL certificate." "SSL004"
        return 1
    fi
    
    if ! systemctl reload nginx >> "$LOG_FILE" 2>&1; then
        print_status "error" "Failed to reload Nginx. Cannot obtain SSL certificate." "SSL005"
        return 1
    fi
    
    # Wait a moment for nginx to be ready
    sleep 2
    
    # Try standalone method first (most reliable)
    print_status "info" "Attempting to obtain certificate using standalone method..." "SSL006"
    
    # Temporarily stop nginx for standalone method
    systemctl stop nginx >> "$LOG_FILE" 2>&1 || true
    
    if certbot certonly --standalone --non-interactive --agree-tos \
        --email "$SSL_EMAIL" -d "$DOMAIN_NAME" \
        --preferred-challenges http >> "$LOG_FILE" 2>&1; then
        print_status "success" "SSL certificate obtained successfully using standalone method" "SSL007"
        systemctl start nginx >> "$LOG_FILE" 2>&1 || true
        add_https_configuration
        return 0
    fi
    
    # If standalone fails, start nginx and try nginx method
    systemctl start nginx >> "$LOG_FILE" 2>&1 || true
    sleep 2
    
    print_status "info" "Standalone method failed, trying nginx method..." "SSL008"
    
    # Create backup before certbot modifies config
    local config_backup="/etc/nginx/sites-available/${DOMAIN_NAME}.pre-certbot"
    cp "/etc/nginx/sites-available/$DOMAIN_NAME" "$config_backup" 2>/dev/null || true
    
    if certbot --nginx --non-interactive --agree-tos \
        --email "$SSL_EMAIL" -d "$DOMAIN_NAME" >> "$LOG_FILE" 2>&1; then
        print_status "success" "SSL certificate obtained successfully using nginx method" "SSL009"
        
        # Restore proxy settings if certbot modified them
        restore_proxy_settings_after_certbot "$config_backup"
        return 0
    else
        print_status "error" "Failed to obtain SSL certificate using both methods" "SSL010"
        print_status "warning" "Common causes: DNS not pointing to server, port 80 blocked, or rate limit reached" "SSL011"
        print_status "info" "You can manually obtain a certificate later with: sudo certbot --nginx -d $DOMAIN_NAME" "SSL012"
        ENABLE_SSL="no"
        return 1
    fi
}

# Improved function to restore proxy settings after Certbot
restore_proxy_settings_after_certbot() {
    local backup_file="$1"
    local config_file="/etc/nginx/sites-available/$DOMAIN_NAME"
    
    print_status "info" "Checking if proxy settings need restoration..." "RESTORE005"
    
    # Check if certbot added a root directive (which means it replaced our proxy)
    if grep -q "root /var/www/html" "$config_file"; then
        print_status "info" "Restoring proxy settings after Certbot modification..." "RESTORE006"
        
        # Create a proper location block replacement
        local proxy_block="        proxy_pass http://$BACKEND_IP:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;"
        
        # Use sed to replace the location block content
        # This is safer than the previous method
        local temp_config=$(mktemp)
        
        # Read the file and replace location blocks
        awk -v proxy="$proxy_block" '
        /location \/ {/ {
            print
            getline
            # Skip until we find the closing brace
            while (!/^[[:space:]]*}/) {
                getline
            }
            # Print our proxy block with proper indentation
            gsub(/^/, "        ", proxy)
            print proxy
            print "    }"
            next
        }
        { print }
        ' "$config_file" > "$temp_config"
        
        # Test the new config
        if nginx -t -c "$temp_config" >> "$LOG_FILE" 2>&1; then
            mv "$temp_config" "$config_file" || {
                print_status "error" "Failed to restore proxy settings" "RESTORE007"
                if [[ -f "$backup_file" ]]; then
                    cp "$backup_file" "$config_file"
                    print_status "info" "Restored from backup" "RESTORE008"
                fi
                return 1
            }
            
            if nginx -t >> "$LOG_FILE" 2>&1 && systemctl reload nginx >> "$LOG_FILE" 2>&1; then
                print_status "success" "Proxy settings restored and NGINX reloaded successfully" "RESTORE009"
                return 0
            else
                print_status "error" "Configuration test failed after restoring proxy settings" "RESTORE010"
                if [[ -f "$backup_file" ]]; then
                    cp "$backup_file" "$config_file"
                    print_status "info" "Restored from backup" "RESTORE011"
                fi
                return 1
            fi
        else
            print_status "error" "Restored configuration is invalid" "RESTORE012"
            if [[ -f "$backup_file" ]]; then
                cp "$backup_file" "$config_file"
                print_status "info" "Restored from backup" "RESTORE013"
            fi
            rm -f "$temp_config"
            return 1
        fi
    else
        print_status "info" "Proxy settings appear to be intact" "RESTORE014"
        return 0
    fi
}

# Function to add HTTPS configuration
add_https_configuration() {
    local config_file="/etc/nginx/sites-available/$DOMAIN_NAME"
    
    # Check if HTTPS block already exists
    if grep -q "listen 443" "$config_file"; then
        print_status "info" "HTTPS configuration already exists" "HTTPS001"
        return 0
    fi
    
    print_status "info" "Adding HTTPS configuration..." "HTTPS002"
    
    # Check if certificate files exist
    if [[ ! -f "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem" ]]; then
        print_status "error" "SSL certificate not found. Cannot add HTTPS configuration." "HTTPS003"
        return 1
    fi
    
    # Build access log configuration
    local access_log_config="access_log off;"
    
    # Append HTTPS server block
    cat >> "$config_file" << SSL_EOF

# HTTPS Server
server {
    listen 443 ssl http2;
    server_name $DOMAIN_NAME;
    
    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    # ssl_stapling only works if OCSP responder URL is in certificate
    # Disabled by default to avoid warnings
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Logging
    $access_log_config
    
    # Proxy settings
    location / {
        proxy_pass http://$BACKEND_IP:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        proxy_busy_buffers_size 8k;
    }
    
    # Block common vulnerabilities
    location ~* /\.(env|git) {
        deny all;
        return 404;
    }
}
SSL_EOF

    # Add HTTPS redirect if enabled (must be in HTTP block only, replacing location block)
    if [[ "$FORCE_HTTPS" == "yes" ]]; then
        print_status "info" "Adding HTTP to HTTPS redirect..." "HTTPS004B"
        
        # Use awk to replace the location block in HTTP server block with redirect
        local temp_config=$(mktemp)
        
        awk -v domain="$DOMAIN_NAME" '
        BEGIN {
            in_http_block = 0
            in_location_block = 0
            location_replaced = 0
            brace_count = 0
        }
        /^server {/ {
            in_http_block = 0
            in_location_block = 0
            location_replaced = 0
            brace_count = 0
        }
        /listen 80/ {
            in_http_block = 1
        }
        /listen 443/ {
            in_http_block = 0
        }
        /location \/ {/ {
            if (in_http_block == 1 && location_replaced == 0) {
                # Replace location block with redirect in HTTP block
                print "    # Redirect HTTP to HTTPS"
                print "    return 301 https://$host$request_uri;"
                in_location_block = 1
                location_replaced = 1
                brace_count = 1
                next
            }
        }
        in_location_block == 1 {
            # Skip lines until we find the closing brace
            if (/{/) brace_count++
            if (/}/) {
                brace_count--
                if (brace_count == 0) {
                    in_location_block = 0
                }
            }
            next
        }
        { print }
        ' "$config_file" > "$temp_config"
        
        # Verify the redirect was added correctly
        # Check that HTTP block (listen 80) has redirect and HTTPS block (listen 443) has location
        local http_has_redirect=$(grep -A15 "listen 80" "$temp_config" 2>/dev/null | grep -c "return 301 https" 2>/dev/null || echo "0")
        local https_has_location=$(grep -A15 "listen 443" "$temp_config" 2>/dev/null | grep -c "location /" 2>/dev/null || echo "0")
        local http_has_location=$(grep -A15 "listen 80" "$temp_config" 2>/dev/null | grep -c "location /" 2>/dev/null || echo "0")
        
        # Ensure we have clean numeric values
        http_has_redirect=$(echo "$http_has_redirect" | tr -d '[:space:]')
        https_has_location=$(echo "$https_has_location" | tr -d '[:space:]')
        http_has_location=$(echo "$http_has_location" | tr -d '[:space:]')
        
        # Default to 0 if empty
        [[ -z "$http_has_redirect" ]] && http_has_redirect="0"
        [[ -z "$https_has_location" ]] && https_has_location="0"
        [[ -z "$http_has_location" ]] && http_has_location="0"
        
        if [[ "$http_has_redirect" -gt 0 ]] && [[ "$https_has_location" -gt 0 ]] && [[ "$http_has_location" -eq 0 ]]; then
            # Perfect: HTTP has redirect, HTTPS has location, HTTP doesn't have location
            mv "$temp_config" "$config_file" || {
                print_status "warning" "Could not update config with redirect" "HTTPS004A"
                rm -f "$temp_config"
            }
        elif [[ "$http_has_redirect" -gt 0 ]]; then
            # Redirect was added, but verification is uncertain - use it anyway
            mv "$temp_config" "$config_file" || {
                print_status "warning" "Could not update config with redirect" "HTTPS004A"
                rm -f "$temp_config"
            }
        else
            # Fallback: simpler method - add redirect right after server_name in HTTP block
            rm -f "$temp_config"
            # Find HTTP block and add redirect right after server_name
            sed -i "0,/listen 80;/,/location \/ {/ {
                /server_name $DOMAIN_NAME;/a \    # Redirect HTTP to HTTPS
                /server_name $DOMAIN_NAME;/a \    return 301 https://\$host\$request_uri;
            }" "$config_file" 2>/dev/null || {
                # Even simpler: just add after server_name in first occurrence
                sed -i "/listen 80;/,/^}/ {
                    /server_name $DOMAIN_NAME;/a \    # Redirect HTTP to HTTPS
                    /server_name $DOMAIN_NAME;/a \    return 301 https://\$host\$request_uri;
                }" "$config_file" 2>/dev/null || {
                    print_status "warning" "Could not add HTTPS redirect automatically. You may need to add it manually." "HTTPS004"
                }
            }
        fi
    fi
    
    # Test configuration
    if nginx -t >> "$LOG_FILE" 2>&1; then
        print_status "success" "HTTPS configuration added successfully" "HTTPS005"
        return 0
    else
        print_status "error" "HTTPS configuration test failed. Please check the configuration manually." "HTTPS006"
        return 1
    fi
}

# Function to configure firewall
configure_firewall() {
    print_status "info" "Configuring firewall rules..." "FW001"
    
    local fw_success=0
    
    if command -v ufw &> /dev/null; then
        ufw allow 80/tcp >> "$LOG_FILE" 2>&1 && fw_success=1
        if [[ "$ENABLE_SSL" == "yes" ]]; then
            ufw allow 443/tcp >> "$LOG_FILE" 2>&1 || fw_success=0
        fi
        ufw reload >> "$LOG_FILE" 2>&1 || fw_success=0
        
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=80/tcp >> "$LOG_FILE" 2>&1 && fw_success=1
        if [[ "$ENABLE_SSL" == "yes" ]]; then
            firewall-cmd --permanent --add-port=443/tcp >> "$LOG_FILE" 2>&1 || fw_success=0
        fi
        firewall-cmd --reload >> "$LOG_FILE" 2>&1 || fw_success=0
        
    else
        print_status "warning" "No supported firewall manager found. Please ensure these ports are open:" "FW002"
        print_status "info" "Port 80 (HTTP) must be open" "FW003"
        if [[ "$ENABLE_SSL" == "yes" ]]; then
            print_status "info" "Port 443 (HTTPS) must be open" "FW004"
        fi
        return 1
    fi
    
    if [[ $fw_success -eq 1 ]]; then
        print_status "success" "Firewall configured successfully" "FW005"
        return 0
    else
        print_status "warning" "Firewall configuration had issues. Please check manually." "FW006"
        return 1
    fi
}

# Function to test NGINX configuration
test_nginx_config() {
    print_status "info" "Testing configuration for errors..." "TEST001"
    
    local test_output=$(nginx -t 2>&1)
    local test_result=$?
    
    echo "$test_output" >> "$LOG_FILE"
    
    if [[ $test_result -eq 0 ]]; then
        print_status "success" "Configuration test passed" "TEST002"
        return 0
    else
        print_status "error" "Configuration test failed. Details logged." "TEST003"
        echo "$test_output"
        return 1
    fi
}

# Function to restart NGINX safely
restart_nginx_safely() {
    print_status "info" "Applying configuration changes..." "RESTART001"
    
    # Test configuration first
    if ! nginx -t >> "$LOG_FILE" 2>&1; then
        print_status "error" "Configuration test failed. Cannot restart NGINX." "RESTART002"
        return 1
    fi
    
    # Try reload first (safer)
    if systemctl reload nginx >> "$LOG_FILE" 2>&1; then
        print_status "success" "NGINX reloaded successfully" "RESTART003"
        sleep 1
        # Verify it's still running
        if systemctl is-active --quiet nginx; then
            return 0
        else
            print_status "error" "NGINX stopped after reload. Attempting restart..." "RESTART004"
        fi
    fi
    
    # If reload failed or nginx stopped, try restart
    if systemctl restart nginx >> "$LOG_FILE" 2>&1; then
        sleep 2
        if systemctl is-active --quiet nginx; then
            print_status "success" "NGINX restarted successfully" "RESTART005"
            return 0
        else
            print_status "error" "NGINX failed to start after restart" "RESTART006"
        fi
    else
        print_status "error" "Failed to restart NGINX" "RESTART007"
    fi
    
    # Emergency: remove problematic config
    print_status "warning" "Attempting emergency recovery..." "RESTART008"
    if [[ -f "/etc/nginx/sites-enabled/$DOMAIN_NAME" ]]; then
        rm -f "/etc/nginx/sites-enabled/$DOMAIN_NAME"
        if systemctl restart nginx >> "$LOG_FILE" 2>&1; then
            print_status "warning" "NGINX restarted after removing problematic configuration. Please check your settings." "RESTART009"
        else
            print_status "error" "Critical: NGINX failed to restart even after reverting changes." "RESTART010"
            print_status "info" "Check system status with: systemctl status nginx" "RESTART011"
            print_status "info" "Check logs with: journalctl -xe" "RESTART012"
        fi
    fi
    
    return 1
}

# Function to display summary
display_summary() {
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║         INSTALLATION COMPLETE               ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo -e "  ${GREEN}✓ Your reverse proxy has been successfully configured!${NC}"
    echo ""
    echo "  Configuration Summary:"
    echo "  ──────────────────────"
    echo -e "  Backend Server:  ${BLUE}$BACKEND_IP:$BACKEND_PORT${NC}"
    echo -e "  Domain Name:    ${BLUE}$DOMAIN_NAME${NC}"
    if [[ "$ENABLE_SSL" == "yes" ]]; then
        echo -e "  HTTPS/SSL:      ${GREEN}Enabled${NC}"
        local force_https_status
        if [[ "$FORCE_HTTPS" == "yes" ]]; then
            force_https_status="${GREEN}Enabled${NC}"
        else
            force_https_status="${YELLOW}Disabled${NC}"
        fi
        echo -e "  Force HTTPS:    ${force_https_status}"
    else
        echo -e "  HTTPS/SSL:      ${YELLOW}Disabled${NC}"
    fi
    echo ""
    echo "  Next Steps:"
    echo "  ───────────"
    echo "  1. Ensure your DNS A record for $DOMAIN_NAME"
    echo "     points to this server's IP"
    echo "  2. Allow up to 24 hours for DNS propagation"
    echo "     if you just created the record"
    
    local step_num=3
    if [[ "$ENABLE_SSL" != "yes" ]]; then
        echo "  $step_num. Enable SSL later with:"
        echo -e "     ${BLUE}sudo certbot --nginx -d $DOMAIN_NAME${NC}"
        step_num=$((step_num + 1))
    fi
    
    echo -e "  $step_num. Config file: ${BLUE}/etc/nginx/sites-available/$DOMAIN_NAME${NC}"
    echo ""
    echo "  Test your setup:"
    if [[ "$ENABLE_SSL" == "yes" ]]; then
        echo -e "  ${GREEN}https://$DOMAIN_NAME${NC}"
    else
        echo -e "  ${BLUE}http://$DOMAIN_NAME${NC}"
    fi
    echo ""
    if [[ $ERROR_COUNT -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠ Warning: $ERROR_COUNT errors were encountered.${NC}"
        echo -e "  Check logs for details: ${BLUE}$LOG_FILE${NC}"
    else
        echo -e "  ${GREEN}✓ All operations completed successfully!${NC}"
    fi
    echo ""
}

# Function to view logs (shows only last installation attempt)
view_logs() {
    if [[ -f "$LOG_FILE" ]]; then
        echo ""
        echo "╔════════════════════════════════════════════╗"
        echo "║      Last Installation Attempt Logs       ║"
        echo "╚════════════════════════════════════════════╝"
        echo ""
        
        # Find the last occurrence of "Starting NGINX Reverse Proxy installation" (MAIN001)
        # and show everything from that point forward
        local last_start_line=$(grep -n "\[CODE:MAIN001\]" "$LOG_FILE" 2>/dev/null | tail -1 | cut -d: -f1)
        
        if [[ -n "$last_start_line" ]]; then
            # Show from the last installation start to the end of the file
            sed -n "${last_start_line},\$p" "$LOG_FILE"
        else
            # If no MAIN001 found, just show last 50 lines as fallback
            print_status "info" "No installation start marker found. Showing last 50 lines:" "LOGS002"
            echo ""
            tail -50 "$LOG_FILE"
        fi
        
        echo ""
        read -p "  Press Enter to continue... "
    else
        print_status "info" "No log file found." "LOGS001"
        read -p "  Press Enter to continue... "
    fi
}

# Main installation function
install_reverse_proxy() {
    local backup_path=""
    local domain_name=""
    local installation_failed=false
    
    # Show welcome message
    show_welcome
    
    # Initialize logging
    init_logging
    log_message "INFO" "Starting NGINX Reverse Proxy installation" "MAIN001"
    
    # Create backup before making changes
    echo ""
    echo -e "  ${BLUE}→${NC} Creating backup..."
    backup_path=$(create_backup "pre_installation")
    if [[ -z "$backup_path" ]]; then
        print_status "warning" "Backup creation had issues, but continuing..." "MAIN002"
    fi
    
    # Get user input
    get_user_input
    
    # Validate input
    if ! validate_input; then
        print_status "error" "Please fix the errors above and run the script again." "MAIN003"
        rollback_installation "$backup_path" ""
        return 1
    fi
    
    # Store domain name for rollback
    domain_name="$DOMAIN_NAME"
    
    # Check for existing configuration
    if ! check_existing_config "$DOMAIN_NAME"; then
        rollback_installation "$backup_path" "$domain_name"
        return 1
    fi
    
    # Installation steps
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "║         Installation Progress             ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    
    # Check DNS (non-blocking)
    check_dns_resolution "$DOMAIN_NAME" || true
    
    # Check backend connectivity (non-blocking)
    check_backend_connectivity "$BACKEND_IP" "$BACKEND_PORT" || true
    
    # Check and install dependencies (nginx will be installed if missing)
    if ! check_dependencies; then
        if ! install_dependencies; then
            print_status "error" "Failed to install dependencies" "MAIN004"
            rollback_installation "$backup_path" "$domain_name"
            return 1
        fi
    fi
    
    # Ensure nginx is running
    if ! check_nginx_status; then
        print_status "error" "Nginx is not running and could not be started" "MAIN005"
        rollback_installation "$backup_path" "$domain_name"
        return 1
    fi
    
    # Create NGINX configuration
    if ! create_nginx_config; then
        print_status "error" "Failed to create NGINX configuration" "MAIN006"
        rollback_installation "$backup_path" "$domain_name"
        return 1
    fi
    
    # Configure firewall
    configure_firewall || true  # Non-blocking
    
    # Test configuration
    if ! test_nginx_config; then
        print_status "error" "Configuration test failed. Not proceeding with restart." "MAIN008"
        rollback_installation "$backup_path" "$domain_name"
        return 1
    fi
    
    # Restart NGINX safely
    if ! restart_nginx_safely; then
        print_status "error" "Failed to restart NGINX. Installation incomplete." "MAIN009"
        rollback_installation "$backup_path" "$domain_name"
        return 1
    fi
    
    # Obtain SSL certificate if enabled
    if [[ "$ENABLE_SSL" == "yes" ]]; then
        echo ""
        echo -e "  ${BLUE}→${NC} SSL Certificate Setup"
        echo ""
        if ! obtain_ssl_certificate; then
            print_status "warning" "SSL certificate setup had issues, but HTTP proxy is working" "MAIN010"
            # Don't rollback for SSL failures, HTTP proxy is still working
        fi
        
        # Reload nginx after SSL setup
        if [[ "$ENABLE_SSL" == "yes" ]]; then
            test_nginx_config && restart_nginx_safely || {
                print_status "warning" "Nginx reload after SSL setup had issues" "MAIN010A"
            }
        fi
    fi
    
    # Display summary
    display_summary
    
    log_message "INFO" "Installation completed successfully" "MAIN011"
    return 0
}

# Main execution
main() {
    check_root
    init_logging
    
    while true; do
        show_menu
        
        case $MENU_CHOICE in
            1)
                ERROR_COUNT=0
                if install_reverse_proxy; then
                    read -p "  Press Enter to continue... "
                else
                    print_status "error" "Installation failed. Check $LOG_FILE for details." "MAIN012"
                    read -p "  Press Enter to continue... "
                fi
                ;;
            2)
                renew_reverse_proxy
                read -p "  Press Enter to continue... "
                ;;
            3)
                remove_reverse_proxy
                read -p "  Press Enter to continue... "
                ;;
            4)
                view_logs
                ;;
            5)
                echo ""
                echo -e "  ${GREEN}Goodbye!${NC}"
                echo ""
                exit 0
                ;;
            *)
                print_status "error" "Invalid option. Please try again." "MAIN013"
                sleep 2
                ;;
        esac
    done
}

# Handle script interruption with cleanup
cleanup_on_exit() {
    echo -e "\n  ${RED}✗ Operation interrupted by user${NC}"
    log_message "WARNING" "Script interrupted by user" "CLEANUP001"
    exit 1
}

trap cleanup_on_exit INT TERM

# Run main function
main "$@"
