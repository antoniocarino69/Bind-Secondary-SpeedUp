#!/bin/bash

# Function to display logos in nerd style
display_logos() {
  cat << "EOF"
  
########  #### ##    ## ########      ######  ########  ######   #######  ##    ## ########     ###    ########  ##    ##     ######  ########  ######## ######## ########     ##     ## ########  
##     ##  ##  ###   ## ##     ##    ##    ## ##       ##    ## ##     ## ###   ## ##     ##   ## ##   ##     ##  ##  ##     ##    ## ##     ## ##       ##       ##     ##    ##     ## ##     ## 
##     ##  ##  ####  ## ##     ##    ##       ##       ##       ##     ## ####  ## ##     ##  ##   ##  ##     ##   ####      ##       ##     ## ##       ##       ##     ##    ##     ## ##     ## 
########   ##  ## ## ## ##     ##     ######  ######   ##       ##     ## ## ## ## ##     ## ##     ## ########     ##        ######  ########  ######   ######   ##     ##    ##     ## ########  
##     ##  ##  ##  #### ##     ##          ## ##       ##       ##     ## ##  #### ##     ## ######### ##   ##      ##             ## ##        ##       ##       ##     ##    ##     ## ##        
##     ##  ##  ##   ### ##     ##    ##    ## ##       ##    ## ##     ## ##   ### ##     ## ##     ## ##    ##     ##       ##    ## ##        ##       ##       ##     ##    ##     ## ##        
########  #### ##    ## ########      ######  ########  ######   #######  ##    ## ########  ##     ## ##     ##    ##        ######  ##        ######## ######## ########      #######  ##         

EOF
  echo
}

# Function to check if the user is root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
  fi
}

# Function to temporarily configure DNS
configure_temporary_dns() {
  echo "Temporarily configuring DNS..."
  cp /etc/resolv.conf /etc/resolv.conf.bak || { echo "Backup of /etc/resolv.conf failed"; exit 1; }
  echo "nameserver 8.8.8.8" > /etc/resolv.conf
}

# Function to update the system
update_system() {
  echo "Updating the system..."
  dnf update -y && dnf upgrade -y || { echo "System update failed"; exit 1; }
}

# Function to gather information from the user with validation
gather_information() {
  echo "Gathering information for BIND configuration..."

  while true; do
    read -p "Enter the primary server address: " primary_server
    if [[ $primary_server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      break
    else
      echo "Invalid IP address. Please try again."
    fi
  done

  while true; do
    read -p "Enter the subnet for listening (e.g. 192.168.1.0/24): " listening_subnet
    if [[ $listening_subnet =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
      break
    else
      echo "Invalid subnet. Please try again."
    fi
  done

  while true; do
    read -p "Enter the computer name: " computer_name
    if [[ ! -z "$computer_name" ]]; then
      break
    else
      echo "Computer name cannot be empty. Please try again."
    fi
  done

  zones=()
  while true; do
    read -p "Do you want to configure a zone? (y/n): " configure_zone
    if [[ $configure_zone =~ ^[Yy]$ ]]; then
      read -p "Enter the zone name: " zone_name
      if [[ ! -z "$zone_name" ]]; then
        zones+=("$zone_name")
      else
        echo "Zone name cannot be empty. Please try again."
      fi
    else
      break
    fi
  done

  echo "Collected information:"
  echo "Primary server: $primary_server"
  echo "Listening subnet: $listening_subnet"
  echo "Computer name: $computer_name"
  echo "Configured zones: ${zones[*]}"
}

# Function to restore the original DNS configuration
restore_dns() {
  echo "Restoring original DNS configuration..."
  if [[ -f /etc/resolv.conf.bak ]]; then
    mv /etc/resolv.conf.bak /etc/resolv.conf || { echo "Restoration of /etc/resolv.conf failed"; exit 1; }
  else
    echo "No backup found for /etc/resolv.conf"
  fi
}

# Function to set the BIND server as DNS
set_self_as_dns() {
  echo "Setting the BIND server as its own DNS..."
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

# Function to install BIND and bind-chroot
install_bind() {
  echo "Installing BIND and bind-chroot..."
  dnf install -y bind bind-utils bind-chroot || { echo "Installation failed"; exit 1; }

  echo "Configuring the chroot environment..."
  /usr/libexec/setup-named-chroot.sh /var/named/chroot on || { echo "Chroot configuration failed"; exit 1; }
}

# Function to configure BIND as DNS server
configure_bind() {
  echo "Configuring BIND..."

  # Configure named.conf
  cat <<EOL > /etc/named.conf
options {
  directory "/var/named";
  pid-file "/run/named/named.pid";
  session-keyfile "/run/named/session.key";
  recursion yes;
  allow-query { $listening_subnet; };
  allow-transfer { none; };
  dnssec-enable yes;
  dnssec-validation yes;
  listen-on port 53 { $listening_subnet; };
  listen-on-v6 { none; };
  forwarders {
    8.8.8.8;
  };
};

logging {
  channel default_debug {
    file "data/named.run";
    severity dynamic;
  };
};

include "/etc/named.rfc1912.zones";
EOL

  # Add zones to named.rfc1912.zones
  for zone_name in "${zones[@]}"; do
    cat <<EOL >> /etc/named.rfc1912.zones
zone "$zone_name" {
  type slave;
  file "/var/named/slaves/$zone_name.zone";
  masters { $primary_server; };
};
EOL
  done

  # Configure chroot
  mkdir -p /var/named/chroot/var/named/slaves /var/named/chroot/var/named/data /var/named/chroot/var/named/dynamic
  chown -R named:named /var/named/chroot/var/named

  # Copy configuration files to chroot
  cp /etc/named.conf /var/named/chroot/etc/named.conf
  cp /etc/named.rfc1912.zones /var/named/chroot/etc/named.rfc1912.zones

  # Check configuration file syntax
  named-checkconf /etc/named.conf || { echo "Syntax error in named.conf"; exit 1; }

  # Start and enable named and named-chroot services
  systemctl enable --now named || { echo "Unable to enable named"; exit 1; }
  systemctl enable --now named-chroot || { echo "Unable to enable named-chroot"; exit 1; }
  systemctl restart named || { echo "Unable to restart named"; exit 1; }
  systemctl restart named-chroot || { echo "Unable to restart named-chroot"; exit 1; }

  echo "BIND has been configured and started successfully."
}

# Function to configure the firewall
configure_firewall() {
  echo "Configuring the firewall..."
  firewall-cmd --zone=public --add-service=dns --permanent || { echo "Unable to configure the firewall"; exit 1; }
  firewall-cmd --zone=public --add-service=ssh --permanent || { echo "Unable to configure the firewall"; exit 1; }
  firewall-cmd --reload || { echo "Unable to reload firewall rules"; exit 1; }
}

# Function to configure SELinux
configure_selinux() {
  echo "Checking SELinux status..."
  if sestatus | grep -q "SELinux status:.*enabled"; then
    echo "SELinux is enabled."
  else
    echo "SELinux is disabled. Enabling..."
    sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
    setenforce 1 || { echo "Unable to enable SELinux"; exit 1; }
    echo "SELinux has been enabled."
  fi
}

# Function to check the status of the firewall and SELinux
check_status() {
  echo "Checking the status of the firewall and SELinux..."

  echo -e "\nFirewall status:"
  firewall-cmd --list-all || { echo "Unable to get the firewall status"; exit 1; }

  echo -e "\nSELinux status:"
  sestatus || { echo "Unable to get the SELinux status"; exit 1; }
}

# Main function
main() {
  display_logos
  check_root
  configure_temporary_dns
  update_system
  gather_information
  install_bind
  restore_dns
  configure_bind
  set_self_as_dns
  configure_firewall
  configure_selinux
  check_status
}

main
