#!/usr/bin/env bash
source <(curl -s https://raw.githubusercontent.com/AlbertSmit/ProxmoxScripts/main/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Adapted for Samba Alpine LXC setup by User & AI Assistant
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# --- App Specific Variables ---
APP="Samba File Server"
var_tags="${var_tags:-alpine;smb;samba;fileserver}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}" # Increased default RAM for Samba
var_disk="${var_disk:-4}"  # Disk for OS, Samba, logs (share data ideally on bind mount)
var_os="${var_os:-alpine}"
var_version="${var_version:-3.19}" # Or latest stable, e.g., 3.20. build.func will find the template.
var_unprivileged="${var_unprivileged:-1}" # Default to unprivileged (recommended)

# --- Samba Specific Configuration ---
# These can be overridden by exporting them before running the script, e.g., export var_samba_share_name="MyData"
var_samba_share_name="${var_samba_share_name:-Samba}"            # Name of the Samba share
var_host_share_path="${var_host_share_path:-}"                   # IMPORTANT: ABSOLUTE path on Proxmox HOST for bind mount data.
                                                                 # Example: /mnt/pve/my_shared_drive
                                                                 # LEAVE EMPTY to store share data inside the LXC's own disk.
var_lxc_share_path="${var_lxc_share_path:-/shared_data/samba_share}" # ABSOLUTE path INSIDE LXC for the share.
                                                                 # If var_host_share_path is set, this is the bind mount target.
                                                                 # If var_host_share_path is empty, this directory is created inside LXC.
var_samba_guest_ok="${var_samba_guest_ok:-yes}"                  # "yes" or "no" for guest access
var_samba_writable="${var_samba_writable:-yes}"                  # "yes" or "no" for writable share (if guest_ok=yes)

# --- Script Header and Initialization ---
header_info "$APP"
variables # This function from build.func might list defined variables.
color
catch_errors

# --- Custom Samba Setup Function ---
function setup_samba() {
  msg_info "Starting Samba Configuration for CT ${CTID}..."

  # 1. Configure Bind Mount (if var_host_share_path is set)
  if [ -n "${var_host_share_path}" ]; then
    if [ ! -d "${var_host_share_path}" ]; then
      # Attempt to create host path if it doesn't exist.
      # User should ideally pre-create and set permissions on this.
      warn "Host share path '${var_host_share_path}' does not exist. Attempting to create."
      if mkdir -p "${var_host_share_path}"; then
        msg_ok "Host path '${var_host_share_path}' created. YOU MUST SET PERMISSIONS ON IT MANUALLY."
      else
        err "Failed to create host path '${var_host_share_path}'. Please create it manually and set permissions."
        # Decide if you want to exit or continue with an internal LXC path
        # For now, we'll assume if it fails, the share will be internal
        var_host_share_path="" # Clear it so internal path logic takes over
        warn "Proceeding with internal LXC storage for the share at '${var_lxc_share_path}'."
      fi
    fi

    if [ -n "${var_host_share_path}" ]; then # Re-check in case creation failed and it was cleared
      msg_info "Configuring bind mount: Host '${var_host_share_path}' to LXC '${var_lxc_share_path}'"
      # Proxmox typically creates the mount point directory inside the LXC if it doesn't exist
      if pct set $CTID -mp0 "${var_host_share_path},mp=${var_lxc_share_path}"; then
        msg_ok "Bind mount configured successfully."
        # Restarting the container ensures the mount point is active.
        # build_container usually leaves the container running.
        msg_info "Restarting CT ${CTID} to activate bind mount..."
        pct_action "stop" || true # allow failure if already stopped
        pct_action "start"
        sleep 5 # Give it a moment to settle after restart
      else
        err "Failed to configure bind mount. Ensure host path '${var_host_share_path}' is valid."
        var_host_share_path="" # Clear it so internal path logic takes over
        warn "Proceeding with internal LXC storage for the share at '${var_lxc_share_path}' due to bind mount failure."
      fi
    fi
  else
    msg_info "No host_share_path defined. Share data will be stored inside the LXC at '${var_lxc_share_path}'."
  fi

  # 2. Ensure LXC share path directory exists (especially if not a bind mount or if bind mount target needed creation)
  msg_info "Ensuring LXC share path exists: ${var_lxc_share_path}"
  pct_exec "mkdir -p ${var_lxc_share_path}"

  # 3. Install and Configure Samba inside the LXC
  msg_info "Installing Samba packages in CT ${CTID}..."
  pct_exec "apk update && apk add samba samba-common-tools nano" # nano for convenience
  msg_ok "Samba packages installed."

  msg_info "Creating Samba configuration (/etc/samba/smb.conf)..."
  # $HOSTNAME is set by build.func to the CT's short hostname.
  local lxc_hostname=$(pct exec $CTID -- hostname) # Get actual short hostname from within LXC

  # Determine read_only value based on var_samba_writable
  local samba_read_only_value="no"
  if [ "${var_samba_writable}" == "no" ]; then
    samba_read_only_value="yes"
  fi

  pct_exec "cat <<EOF > /etc/samba/smb.conf
[global]
    workgroup = WORKGROUP
    server string = Samba Server on ${lxc_hostname}
    netbios name = ${lxc_hostname}
    security = user
    map to guest = bad user
    dns proxy = no
    log file = /var/log/samba/log.%m
    max log size = 50
    guest account = nobody # Explicitly set for clarity with guest ok = yes

[${var_samba_share_name}]
    comment = Shared Folder
    path = ${var_lxc_share_path}
    browsable = yes
    writable = ${var_samba_writable}
    guest ok = ${var_samba_guest_ok}
    read only = ${samba_read_only_value}
    force create mode = 0664
    force directory mode = 0775
    # Optional: VFS objects for better macOS compatibility
    # vfs objects = fruit streams_xattr
    # fruit:metadata = stream
    # fruit:model = MacSamba
EOF"
  msg_ok "Samba configuration file created."

  # 4. Set permissions for the share path *inside* the LXC
  # This is primarily for the case where data is stored inside the LXC (no bind mount).
  # For bind mounts, host-side permissions + UID mapping are the primary concern.
  if [ -z "${var_host_share_path}" ]; then
      msg_info "Setting permissions for internal LXC share path: ${var_lxc_share_path}"
      # For guest access with 'nobody', making it world-writable or owned by nobody:nobody
      pct_exec "chown -R nobody:nobody ${var_lxc_share_path}"
      pct_exec "chmod -R 0775 ${var_lxc_share_path}" # Or 0777 for full guest write without sticky bit concerns
      msg_ok "Permissions set on internal share path."
  else
      # Reminders for bind mount permissions
      if [ "${var_unprivileged}" == "1" ]; then
          warn "UNPRIVILEGED CONTAINER: Host path '${var_host_share_path}' is bind-mounted."
          warn "YOU MUST ensure correct UID/GID mapping and permissions on the HOST for user 'nobody' (typically UID/GID 65534 within LXC) or other intended Samba users."
          warn "Example host command for 'nobody' if mapped UID is 165534: 'sudo chown -R 165534:165534 ${var_host_share_path} && sudo chmod -R u+rwX,g+rX,o+rX ${var_host_share_path}'"
      else # Privileged container
          warn "PRIVILEGED CONTAINER: Host path '${var_host_share_path}' is bind-mounted."
          warn "Ensure this path on the HOST is accessible (e.g., readable/writable) by the 'nobody' user (UID 65534) or other intended Samba users."
          warn "Example host command: 'sudo chown -R nobody:nogroup ${var_host_share_path} && sudo chmod -R 0775 ${var_host_share_path}' (if host 'nobody' UID is 65534)"
      fi
  fi

  # 5. Enable and start Samba service
  msg_info "Enabling and starting Samba service..."
  pct_exec "rc-update add samba default"
  pct_exec "rc-service samba restart" # Use restart to ensure it picks up new config

  if pct_exec "rc-service samba status --quiet"; then
    msg_ok "Samba service is running."
  else
    err "Samba service failed to start. Check logs in CT ${CTID}:/var/log/samba/"
    # Consider exiting if Samba fails to start: exit 1;
  fi
}

# --- Main Execution Flow ---
start # From build.func: Pre-flight checks

build_container # From build.func: Creates CT, sets up OS, network. CTID, IP, etc., are set.

setup_samba # Call our custom Samba setup function

description # From build.func: Displays standard CT info (IP, password, etc.)

# --- Custom Post-Setup Information ---
echo -e "" # Newline for better formatting
echo -e "${INFO}${GN}Samba Share Configuration:${CL}"
echo -e "${INFO}${YW}Samba Share Name:${CL} ${CYAN}${var_samba_share_name}${CL}"
if [ -n "$IP" ]; then # IP is set by build.func
    echo -e "${INFO}${YW}Access (example):${CL} ${CYAN}\\\\${IP}\\${var_samba_share_name}${CL}"
else
    echo -e "${INFO}${YW}Access (example):${CL} ${CYAN}\\\\<LXC_IP_ADDRESS>\\${var_samba_share_name}${CL} (IP address not detected by script)"
fi

if [ -n "${var_host_share_path}" ]; then
  echo -e "${INFO}${YW}Data Source:${CL} ${CYAN}Bind-mounted from Proxmox host path '${var_host_share_path}'${CL}"
  echo -e "${INFO}${YW}Mounted inside LXC at:${CL} ${CYAN}${var_lxc_share_path}${CL}"
else
  echo -e "${INFO}${YW}Data Source:${CL} ${CYAN}Stored inside the LXC's disk at '${var_lxc_share_path}'${CL}"
fi

if [ "${var_samba_guest_ok}" == "yes" ]; then
  echo -e "${INFO}${GN}Share is configured for GUEST access.${CL}"
else
  echo -e "${INFO}${YW}Share requires user authentication.${CL}"
  echo -e "${INFO}${YW}Create Samba users with 'pct exec ${CTID} -- smbpasswd -a <username>' (username must exist in LXC).${CL}"
fi
echo -e "${INFO}${GN}Remember to configure firewall rules if necessary.${CL}"

msg_ok "Completed Successfully!\n"
# End message from build.func usually indicates completion.