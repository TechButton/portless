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

# _mount_nfs_one <server> <export> <local_dir> <nfs_ver> <user>
# Mounts a single NFS export with a retry loop. Returns 0 on success.
_mount_nfs_one() {
  local nfs_server="$1" export_path="$2" local_dir="$3" nfs_ver="$4" user="$5"

  # Create subfolder if needed
  if [[ ! -d "$local_dir" ]]; then
    sudo mkdir -p "$local_dir" || { log_error "Could not create $local_dir"; return 1; }
  fi

  while true; do
    log_sub "Mounting ${nfs_server}:${export_path} → ${local_dir}..."
    if sudo mount -t nfs -o "nfsvers=${nfs_ver}" "${nfs_server}:${export_path}" "$local_dir"; then
      log_ok "Mounted → ${local_dir}"
      sudo chown "${user}:${user}" "$local_dir" 2>/dev/null || true

      # Add fstab entry with _netdev (wait for network) and nofail (don't block boot)
      local fstab_entry="${nfs_server}:${export_path} ${local_dir} nfs nfsvers=${nfs_ver},defaults,_netdev,nofail 0 0"
      if grep -qsF "$local_dir" /etc/fstab; then
        log_warn "fstab entry for ${local_dir} already exists — skipped"
      else
        echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
        log_sub "fstab: $fstab_entry"
      fi
      return 0
    fi

    log_error "Mount failed for ${nfs_server}:${export_path}"
    prompt_yn "Retry with a different export path?" "Y"
    if [[ "${REPLY^^}" == "Y" ]]; then
      prompt_input "Correct export path" "$export_path"
      export_path="$REPLY"
      [[ -n "$export_path" ]] || return 1
    else
      return 1
    fi
  done
}

_mount_nfs() {
  local mountpoint="${1%/}"   # strip trailing slash, e.g. /media
  local user="$2"

  # Ensure nfs-common is present (also provides showmount)
  if ! command -v mount.nfs &>/dev/null && ! command -v mount.nfs4 &>/dev/null; then
    _mount_install_pkg "nfs-common"
  fi

  prompt_input "NFS server hostname or IP" ""
  local nfs_server="$REPLY"
  [[ -n "$nfs_server" ]] || die "NFS server cannot be empty"

  # ── Discover exports ────────────────────────────────────────────────────────
  log_sub "Querying exports from ${nfs_server}..."
  # showmount output: first line is "Export list for <server>:", skip it
  local exports_raw
  exports_raw=$(showmount -e "$nfs_server" 2>/dev/null | awk 'NR>1 {print $1}' | sort)

  log_blank
  if [[ -n "$exports_raw" ]]; then
    log_info "Exports available on ${nfs_server}:"
    while IFS= read -r ep; do
      echo -e "  ${DIM}${ep}${RESET}"
    done <<< "$exports_raw"
  else
    log_warn "showmount returned no results — server may block the query, or no exports are configured."
    log_warn "Enter export paths manually. Common NAS formats:"
    log_warn "  Synology  /volume1/data   /volume1/homes/user/media"
    log_warn "  TrueNAS   /mnt/pool/name"
    log_warn "  Unraid    /mnt/user/name"
    log_blank

    # Collect paths manually — same loop as the auto path below
    local manual_paths=()
    while true; do
      prompt_input "NFS export path to add (leave blank when done)" ""
      [[ -z "$REPLY" ]] && break
      manual_paths+=("$REPLY")
      log_sub "Added: $REPLY"
    done
    [[ ${#manual_paths[@]} -gt 0 ]] || die "No export paths entered — cannot continue NFS setup."
    exports_raw=$(printf '%s\n' "${manual_paths[@]}")

    log_blank
    log_info "Exports to process:"
    while IFS= read -r ep; do echo -e "  ${DIM}${ep}${RESET}"; done <<< "$exports_raw"
  fi

  # ── NFS version — ask once for all mounts ───────────────────────────────────
  log_blank
  prompt_input "NFS version to use for all mounts" "4"
  local nfs_ver="$REPLY"

  # ── Ensure base mountpoint exists ───────────────────────────────────────────
  if [[ ! -d "$mountpoint" ]]; then
    sudo mkdir -p "$mountpoint" || die "Failed to create base directory $mountpoint"
  fi

  # ── Walk each export top-down ───────────────────────────────────────────────
  local -a share_types=("movies" "tv" "music" "books" "audiobooks" "comics" "downloads" "custom name")
  local mounted_count=0

  while IFS= read -r export_path; do
    [[ -z "$export_path" ]] && continue
    log_blank
    echo -e "  ${BOLD}Export:${RESET} ${CYAN}${nfs_server}:${export_path}${RESET}"

    prompt_yn "Mount this share?" "Y"
    [[ "${REPLY^^}" == "Y" ]] || { log_sub "Skipped"; continue; }

    # Ask what this share is for
    prompt_select "What is this share for?" "${share_types[@]}"
    local share_type="$REPLY"

    local folder_name
    if [[ "$share_type" == "custom name" ]]; then
      prompt_input "Folder name (will be created under ${mountpoint}/)" ""
      folder_name="$REPLY"
      [[ -n "$folder_name" ]] || { log_warn "No name given — skipping"; continue; }
    else
      folder_name="$share_type"
    fi

    local local_dir="${mountpoint}/${folder_name}"

    if _mount_nfs_one "$nfs_server" "$export_path" "$local_dir" "$nfs_ver" "$user"; then
      (( mounted_count++ ))
    else
      log_warn "Skipped ${export_path} — could not mount"
    fi

  done <<< "$exports_raw"

  log_blank
  if (( mounted_count == 0 )); then
    log_warn "No NFS shares were mounted."
    return 1
  fi
  log_ok "${mounted_count} NFS share(s) mounted under ${mountpoint}"
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
