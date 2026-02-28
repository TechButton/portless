#!/usr/bin/env bash
# lib/mount.sh — NFS and SMB/CIFS mount helpers for the data directory

[[ -n "$HOMELAB_COMMON_LOADED" ]] || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
HOMELAB_MOUNT_LOADED=1

# ─── Package installer ───────────────────────────────────────────────────────

_mount_install_pkg() {
  local pkg="$1"
  log_sub "Installing $pkg..."
  if ! sudo apt-get install -y "$pkg" >> "${LOG_FILE:-/tmp/portless-install.log}" 2>&1; then
    die "Failed to install $pkg — install it manually and re-run the installer."
  fi
  log_ok "$pkg installed"
}

# ─── Local creation (sudo) ───────────────────────────────────────────────────

_mount_sudo_create() {
  local dir="$1"
  local user="$2"

  log_sub "Creating $dir with sudo..."
  sudo mkdir -p "$dir" || die "sudo mkdir -p $dir failed"
  sudo chown "${user}:${user}" "$dir" || die "sudo chown ${user}:${user} $dir failed"
  log_ok "Created $dir (owned by $user)"
}

# ─── NFS ─────────────────────────────────────────────────────────────────────

_mount_nfs() {
  local mountpoint="$1"
  local user="$2"

  # Ensure nfs-common is present (also provides showmount)
  if ! command -v mount.nfs &>/dev/null && ! command -v mount.nfs4 &>/dev/null; then
    _mount_install_pkg "nfs-common"
  fi

  prompt_input "NFS server hostname or IP" ""
  local nfs_server="$REPLY"
  [[ -n "$nfs_server" ]] || die "NFS server cannot be empty"

  # Show available exports so the user knows the exact path to enter.
  # This is the most common source of confusion — NAS paths look nothing
  # like local paths (Synology: /volume1/..., TrueNAS: /mnt/pool/...).
  echo ""
  log_sub "Querying exports from ${nfs_server}..."
  if showmount -e "$nfs_server" 2>/dev/null; then
    echo ""
  else
    log_warn "Could not retrieve export list (showmount failed — server may block the query)."
    log_warn "Common NAS export path formats:"
    log_warn "  Synology:  /volume1/data   or  /volume1/homes/user/media"
    log_warn "  TrueNAS:   /mnt/pool/media"
    log_warn "  Unraid:    /mnt/user/media"
    echo ""
  fi

  prompt_input "NFS export path on the server (copy exactly from the list above)" ""
  local nfs_export="$REPLY"
  [[ -n "$nfs_export" ]] || die "NFS export path cannot be empty"

  prompt_input "NFS version" "4"
  local nfs_ver="$REPLY"

  # Create mount point if needed
  if [[ ! -d "$mountpoint" ]]; then
    log_sub "Creating mount point $mountpoint..."
    sudo mkdir -p "$mountpoint" || die "Failed to create mount point $mountpoint"
  fi

  # Test mount — retry loop so the user can correct the path without
  # re-running the whole installer.
  local mounted=false
  while true; do
    log_sub "Testing NFS mount (${nfs_server}:${nfs_export} → $mountpoint)..."
    if sudo mount -t nfs -o "nfsvers=${nfs_ver}" "${nfs_server}:${nfs_export}" "$mountpoint"; then
      mounted=true
      break
    fi

    log_error "Mount failed. The export path must match exactly what the server publishes."
    log_warn "Re-run showmount to double-check:  showmount -e ${nfs_server}"

    prompt_yn "Try a different export path?" "Y"
    if [[ "${REPLY^^}" != "Y" ]]; then
      die "NFS mount failed. Fix the export path and re-run the installer."
    fi

    prompt_input "NFS export path on the server" "$nfs_export"
    nfs_export="$REPLY"
    [[ -n "$nfs_export" ]] || die "NFS export path cannot be empty"
  done

  log_ok "NFS mount succeeded"

  # Grant ownership so the user can write subdirectories
  sudo chown "${user}:${user}" "$mountpoint" 2>/dev/null || true

  # fstab entry — _netdev waits for network before mounting;
  # nofail allows boot to continue if the server is unreachable
  local fstab_entry="${nfs_server}:${nfs_export} ${mountpoint} nfs nfsvers=${nfs_ver},defaults,_netdev,nofail 0 0"

  if grep -qsF "$mountpoint" /etc/fstab; then
    log_warn "An entry for $mountpoint already exists in /etc/fstab — skipping fstab update."
    log_warn "Verify manually: grep '${mountpoint}' /etc/fstab"
  else
    log_sub "Adding fstab entry..."
    echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
    log_ok "fstab updated"
  fi

  log_sub "Entry: $fstab_entry"
}

# ─── SMB/CIFS ────────────────────────────────────────────────────────────────

_mount_smb() {
  local mountpoint="$1"
  local user="$2"
  local dockerdir="$3"
  local uid gid
  uid=$(id -u "$user" 2>/dev/null || echo "1000")
  gid=$(id -g "$user" 2>/dev/null || echo "1000")
  local creds_file="${dockerdir}/secrets/.smb_credentials"

  # Ensure cifs-utils is present
  if ! command -v mount.cifs &>/dev/null; then
    _mount_install_pkg "cifs-utils"
  fi

  prompt_input "SMB server hostname or IP" ""
  local smb_server="$REPLY"
  [[ -n "$smb_server" ]] || die "SMB server cannot be empty"

  prompt_input "Share name (e.g. media)" "media"
  local smb_share="$REPLY"
  [[ -n "$smb_share" ]] || die "Share name cannot be empty"

  prompt_input "SMB username" "$user"
  local smb_user="$REPLY"

  prompt_secret "SMB password"
  local smb_pass="$REPLY"

  # Write credentials file with restricted permissions
  log_sub "Writing credentials to $creds_file..."
  install -m 600 /dev/null "$creds_file" || die "Failed to create credentials file at $creds_file"
  printf 'username=%s\npassword=%s\n' "$smb_user" "$smb_pass" > "$creds_file"
  log_ok "Credentials saved (permissions: 600)"

  # Create mount point if needed
  if [[ ! -d "$mountpoint" ]]; then
    log_sub "Creating mount point $mountpoint..."
    sudo mkdir -p "$mountpoint" || die "Failed to create mount point $mountpoint"
  fi

  # Test mount
  log_sub "Testing SMB mount (//${smb_server}/${smb_share} → $mountpoint)..."
  if ! sudo mount -t cifs "//${smb_server}/${smb_share}" "$mountpoint" \
      -o "credentials=${creds_file},uid=${uid},gid=${gid},iocharset=utf8"; then
    die "SMB mount failed. Verify the server address, share name, and credentials."
  fi
  log_ok "SMB mount succeeded"

  # fstab entry — credentials path is stored in dockerdir/secrets (root-readable)
  # _netdev waits for network; nofail allows boot even if the server is unreachable
  local fstab_entry="//${smb_server}/${smb_share} ${mountpoint} cifs credentials=${creds_file},uid=${uid},gid=${gid},iocharset=utf8,_netdev,nofail 0 0"

  if grep -qsF "$mountpoint" /etc/fstab; then
    log_warn "An entry for $mountpoint already exists in /etc/fstab — skipping fstab update."
    log_warn "Verify manually: grep '${mountpoint}' /etc/fstab"
  else
    log_sub "Adding fstab entry..."
    echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
    log_ok "fstab updated"
  fi

  # Log the entry with password hidden
  log_sub "Entry: //${smb_server}/${smb_share} ${mountpoint} cifs credentials=<hidden>,uid=${uid},gid=${gid},iocharset=utf8,_netdev,nofail 0 0"
}

# ─── Public entrypoint ───────────────────────────────────────────────────────

# setup_data_dir <dir> <user> <dockerdir>
#
# Ensures <dir> exists and is writable by <user>. If it is not, the user is
# offered four options: create locally with sudo, mount NFS, mount SMB, or
# skip (manual setup later). Returns 1 when skipped so the caller can omit
# subdirectory creation.
setup_data_dir() {
  local dir="$1"
  local user="$2"
  local dockerdir="$3"

  if [[ -d "$dir" ]] && [[ -w "$dir" ]]; then
    log_sub "$dir already exists and is writable — skipping mount setup"
    return 0
  fi

  log_warn "$dir does not exist or is not writable"
  log_blank

  prompt_select "How would you like to set up ${BOLD}${dir}${RESET}?" \
    "Create locally (sudo mkdir + chown)" \
    "Mount an NFS share" \
    "Mount an SMB/CIFS share" \
    "Skip — I will set it up manually"

  case "$REPLY" in
    "Create locally (sudo mkdir + chown)")
      _mount_sudo_create "$dir" "$user"
      ;;
    "Mount an NFS share")
      _mount_nfs "$dir" "$user"
      ;;
    "Mount an SMB/CIFS share")
      _mount_smb "$dir" "$user" "$dockerdir"
      ;;
    "Skip — I will set it up manually")
      log_warn "Skipping data directory setup."
      log_warn "Create ${dir} and ensure ${user} has write access before starting containers."
      return 1
      ;;
  esac
}
