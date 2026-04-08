{
  lib,
  writeShellApplication,
  jq,
  coreutils,
  curl,
}:
let
  constants = lib.importJSON ./constants.json;
in
writeShellApplication {
  name = "chrome-bin-update";
  runtimeInputs = [
    jq
    coreutils
    curl
  ];
  text = ''
    # --- Configuration ---
    CURL_OPTS=(--fail --silent --show-error --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5)
    VERSION_FILE="version.json"
    VERSIONHISTORY_API="${constants.versionhistory_api}"
    CHROMIUMDASH_API="${constants.chromiumdash_api}"
    DOWNLOAD_BASE="${constants.download_base}"
    SNAPSHOT_LAST_CHANGE="${constants.snapshot_last_change}"
    SNAPSHOT_BASE="${constants.snapshot_base}"
    FAILED_CHANNELS=()
    UPDATED=0

    # --- Logging ---
    log() {
      echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
    }

    log_error() {
      echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2
    }

    # --- Dependency check ---
    command -v nix >/dev/null 2>&1 || { log_error "'nix' not found on PATH; required for hash prefetching"; exit 1; }

    # --- Cleanup ---
    cleanup() {
      rm -f "''${VERSION_FILE}.tmp" "''${VERSION_FILE}.bak"
    }
    trap cleanup EXIT

    # --- Backup ---
    cp "$VERSION_FILE" "''${VERSION_FILE}.bak"

    # --- Channel Update (hybrid: Version History API primary, ChromiumDash fallback) ---
    update_channel() {
      local CHANNEL="$1"
      local API_CHANNEL="$2"
      local DEB_SLUG="$3"
      local CHANNEL_LC
      CHANNEL_LC=$(echo "$CHANNEL" | tr '[:upper:]' '[:lower:]')

      log "=== Updating $CHANNEL channel ==="

      # --- PRIMARY: Version History API for version string ---
      local VERSION=""
      local VH_URL="''${VERSIONHISTORY_API}/platforms/linux/channels/''${CHANNEL_LC}/versions/all/releases?filter=endtime%3Dnone&order_by=version%20desc&page_size=1"
      local VH_JSON=""
      VH_JSON=$(curl "''${CURL_OPTS[@]}" -L "$VH_URL" 2>/dev/null) || true

      if [[ -n "$VH_JSON" ]]; then
        VERSION=$(echo "$VH_JSON" | jq -r '.releases[0].version // empty' 2>/dev/null) || true
      fi

      if [[ -n "$VERSION" && "$VERSION" != "null" ]]; then
        log "Version History API: $CHANNEL version $VERSION"
      else
        log "Version History API failed for $CHANNEL, falling back to ChromiumDash"
        VERSION=""
      fi

      # --- SECONDARY: ChromiumDash for position (and fallback version) ---
      local POSITION="unknown"
      local CD_JSON=""
      CD_JSON=$(curl "''${CURL_OPTS[@]}" -L "''${CHROMIUMDASH_API}?channel=''${API_CHANNEL}&platform=Linux&num=1" 2>/dev/null) || true

      if [[ -n "$CD_JSON" ]] && echo "$CD_JSON" | jq -e 'type == "array" and length > 0' > /dev/null 2>&1; then
        local CD_POSITION
        CD_POSITION=$(echo "$CD_JSON" | jq -r '.[0].chromium_main_branch_position // empty' 2>/dev/null) || true
        if [[ -n "$CD_POSITION" && "$CD_POSITION" =~ ^[0-9]+$ ]]; then
          POSITION="$CD_POSITION"
        fi

        # Fallback: if Version History API failed, use ChromiumDash for version
        if [[ -z "$VERSION" ]]; then
          local CD_VERSION
          CD_VERSION=$(echo "$CD_JSON" | jq -r '.[0].version // empty' 2>/dev/null) || true
          if [[ -n "$CD_VERSION" && "$CD_VERSION" != "null" ]]; then
            VERSION="$CD_VERSION"
            log "ChromiumDash fallback: $CHANNEL version $VERSION"
          fi
        fi
      else
        log "ChromiumDash unavailable for $CHANNEL (position will be 'unknown')"
      fi

      # --- Validate version (must have one from either source) ---
      if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
        log_error "Could not determine version for $CHANNEL from any API"
        return 1
      fi

      if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format for $CHANNEL: '$VERSION'"
        return 1
      fi

      log "Latest $CHANNEL version: $VERSION (position: $POSITION)"

      # --- Fetch and validate .deb hash ---
      local CURRENT_HASH
      CURRENT_HASH=$(jq -r --arg ch "$CHANNEL" '.[$ch].hash' "$VERSION_FILE")
      local DEB_URL="''${DOWNLOAD_BASE}/google-chrome-''${DEB_SLUG}_current_amd64.deb"
      log "Fetching .deb hash from: $DEB_URL"

      local HASH
      HASH=$(nix store prefetch-file --json "$DEB_URL" | jq -r '.hash') || {
        log_error "Failed to prefetch .deb for $CHANNEL"
        return 1
      }

      if ! [[ "$HASH" =~ ^sha256- ]]; then
        log_error "Invalid hash for $CHANNEL: '$HASH'"
        return 1
      fi

      if [[ "$HASH" == "$CURRENT_HASH" ]]; then
        log "$CHANNEL hash unchanged, skipping update"
        return 0
      fi

      jq --arg channel "$CHANNEL" \
         --arg version "$VERSION" \
         --arg position "$POSITION" \
         --arg hash "$HASH" \
         '.[$channel].version = $version |
          .[$channel].position = $position |
          .[$channel].hash = $hash' \
         "$VERSION_FILE" > "''${VERSION_FILE}.tmp"
      mv "''${VERSION_FILE}.tmp" "$VERSION_FILE"
      log "Updated $CHANNEL to version $VERSION"
      UPDATED=$((UPDATED + 1))
    }

    # --- Snapshot Update (uses GCS LAST_CHANGE, unchanged) ---
    update_snapshot() {
      log "=== Updating chromium-snapshot ==="

      local POSITION
      POSITION=$(curl "''${CURL_OPTS[@]}" "$SNAPSHOT_LAST_CHANGE") || {
        log_error "Failed to fetch LAST_CHANGE"
        return 1
      }

      # Validate position is numeric
      if ! [[ "$POSITION" =~ ^[0-9]+$ ]]; then
        log_error "Invalid snapshot position: '$POSITION'"
        return 1
      fi

      local CURRENT_POS
      CURRENT_POS=$(jq -r '.snapshot.position' "$VERSION_FILE")
      if [[ "$POSITION" == "$CURRENT_POS" ]]; then
        log "chromium-snapshot already at position $POSITION"
        return 0
      fi

      local URL="''${SNAPSHOT_BASE}/''${POSITION}/chrome-linux.zip"
      local HASH
      HASH=$(nix store prefetch-file --json "$URL" | jq -r '.hash') || {
        log_error "Failed to prefetch snapshot"
        return 1
      }

      # Validate hash
      if ! [[ "$HASH" =~ ^sha256- ]]; then
        log_error "Invalid snapshot hash: '$HASH'"
        return 1
      fi

      jq --arg pos "$POSITION" --arg hash "$HASH" \
        '.snapshot = {position: $pos, hash: $hash}' "$VERSION_FILE" > "''${VERSION_FILE}.tmp"
      mv "''${VERSION_FILE}.tmp" "$VERSION_FILE"
      log "Updated chromium-snapshot to position $POSITION"
      UPDATED=$((UPDATED + 1))
    }

    # --- Run Updates (error-isolated per channel) ---
    update_channel "stable" "Stable" "stable" || FAILED_CHANNELS+=("stable")
    update_channel "beta" "Beta" "beta" || FAILED_CHANNELS+=("beta")
    update_channel "dev" "Dev" "unstable" || FAILED_CHANNELS+=("dev")
    update_channel "canary" "Canary" "canary" || FAILED_CHANNELS+=("canary")
    update_snapshot || FAILED_CHANNELS+=("snapshot")

    # --- Summary ---
    TOTAL_OPS=5
    if [[ ''${#FAILED_CHANNELS[@]} -eq $TOTAL_OPS ]]; then
      log_error "All updates failed: ''${FAILED_CHANNELS[*]}"
      log "Restoring backup"
      cp "''${VERSION_FILE}.bak" "$VERSION_FILE"
      exit 1
    fi

    if [[ ''${#FAILED_CHANNELS[@]} -gt 0 ]]; then
      log "WARNING: Some updates failed: ''${FAILED_CHANNELS[*]}"
    fi

    log "Update complete ($UPDATED updated, ''${#FAILED_CHANNELS[@]} failed)"
  '';
}
