{
  lib,
  writeShellApplication,
  curl,
  jq,
  unzip,
  coreutils,
}:
let
  constants = lib.importJSON ./constants.json;
in
writeShellApplication {
  name = "chrome-bisect";
  runtimeInputs = [
    curl
    jq
    unzip
    coreutils
  ];
  text = ''
    set -euo pipefail

    SNAPSHOT_BASE="${constants.snapshot_base}"
    CHROMIUMDASH_API="${constants.chromiumdash_api}"

    GOOD_INPUT=""
    BAD_INPUT=""
    WRAPPER_CMD=""
    WORK_DIR=""
    SKIPPED=":"

    if [[ -t 1 ]]; then
      RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
      BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
    else
      RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" NC=""
    fi

    log_info()  { echo -e "''${BLUE}[info]''${NC}  $*"; }
    log_good()  { echo -e "''${GREEN}[good]''${NC}  $*"; }
    log_bad()   { echo -e "''${RED}[bad]''${NC}   $*"; }
    log_warn()  { echo -e "''${YELLOW}[warn]''${NC}  $*"; }
    log_step()  { echo -e "''${CYAN}[step]''${NC}  $*"; }
    log_error() { echo -e "''${RED}[error]''${NC} $*" >&2; }

    cleanup() {
      if [[ -n "''${WORK_DIR:-}" && -d "''${WORK_DIR:-}" ]]; then
        log_info "Cleaning up $WORK_DIR …"
        rm -rf "$WORK_DIR"
      fi
    }
    trap cleanup EXIT INT TERM

    usage() {
      cat <<USAGE_EOF

    ''${BOLD}chrome-bisect''${NC} — find the Chromium snapshot that introduced a regression

    ''${BOLD}USAGE''${NC}
      chrome-bisect --good <version|position> --bad <version|position> [OPTIONS]

    ''${BOLD}OPTIONS''${NC}
      --good  <val>   Known-good Chrome version (e.g. 136.0.7103.0) or
                      Chromium commit position (e.g. 1400000)
      --bad   <val>   Known-bad Chrome version or commit position
      --wrapper <cmd> Run chrome through <cmd> (e.g. steam-run for NixOS)
      -h, --help      Show this help and exit

    ''${BOLD}EXAMPLES''${NC}
      chrome-bisect --good 1400000 --bad 1410000
      chrome-bisect --good 136.0.7103.0 --bad 137.0.7151.55
      chrome-bisect --good 1400000 --bad 1410000 --wrapper steam-run

    ''${BOLD}INTERACTIVE KEYS''${NC}
      g / good  — this build does NOT have the bug
      b / bad   — this build HAS the bug
      s / skip  — cannot tell (snapshot broken, etc.)
      q / quit  — abort the bisect session

    ''${BOLD}NOTE''${NC}
      Snapshots are raw Chromium builds. On NixOS, use --wrapper steam-run
      or nix-ld. The --no-sandbox flag is added automatically.

    USAGE_EOF
      exit 0
    }

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --good)    GOOD_INPUT="$2"; shift 2 ;;
        --bad)     BAD_INPUT="$2";  shift 2 ;;
        --wrapper) WRAPPER_CMD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
      esac
    done

    if [[ -z "$GOOD_INPUT" || -z "$BAD_INPUT" ]]; then
      log_error "Both --good and --bad are required."
      usage
    fi

    is_version()  { [[ "$1" == *.* ]]; }
    is_position() { [[ "$1" =~ ^[0-9]+$ ]]; }

    resolve_version_to_position() {
      local version="$1"
      for channel in Stable Beta Dev Canary; do
        local response position
        response=$(curl -sL --fail \
          "$CHROMIUMDASH_API?channel=$channel&platform=Linux&num=100" 2>/dev/null) || continue
        position=$(echo "$response" | jq -r \
          --arg v "$version" \
          '.[] | select(.version == $v) | .chromium_main_branch_position' 2>/dev/null) || true
        if [[ -n "$position" && "$position" != "null" ]]; then
          log_info "Resolved $version ($channel) → position $position"
          echo "$position"
          return 0
        fi
      done
      return 1
    }

    snapshot_exists() {
      local pos="$1" code
      code=$(curl -sI -o /dev/null -w "%{http_code}" \
        "$SNAPSHOT_BASE/$pos/chrome-linux.zip" 2>/dev/null) || true
      [[ "$code" == "200" ]]
    }

    is_skipped() { [[ "$SKIPPED" == *":$1:"* ]]; }

    find_nearest_snapshot() {
      local target="$1" lower="$2" upper="$3"
      local radius=100 offset

      if ! is_skipped "$target" && snapshot_exists "$target"; then
        echo "$target"; return 0
      fi
      for offset in $(seq 1 "$radius"); do
        local up=$((target + offset)) down=$((target - offset))
        if [[ "$up" -le "$upper" ]] && ! is_skipped "$up" && snapshot_exists "$up"; then
          echo "$up"; return 0
        fi
        if [[ "$down" -ge "$lower" ]] && ! is_skipped "$down" && snapshot_exists "$down"; then
          echo "$down"; return 0
        fi
      done
      return 1
    }

    download_and_find_chrome() {
      local pos="$1" dest="$2"
      local url="$SNAPSHOT_BASE/$pos/chrome-linux.zip"
      local zipfile="$dest/chrome-linux.zip"

      log_step "Downloading snapshot at position $pos …"
      if ! curl -# -L --fail -o "$zipfile" "$url"; then
        log_warn "Download failed for position $pos"; return 1
      fi
      log_step "Extracting …"
      if ! unzip -qo "$zipfile" -d "$dest" 2>/dev/null; then
        log_warn "Extraction failed for position $pos"; return 1
      fi
      rm -f "$zipfile"

      local chrome=""
      for d in "$dest/chrome-linux/chrome" "$dest/chrome-linux64/chrome"; do
        if [[ -f "$d" ]]; then chmod +x "$d"; chrome="$d"; break; fi
      done
      if [[ -z "$chrome" ]]; then
        log_warn "Chrome binary not found in snapshot $pos"; return 1
      fi
      echo "$chrome"
    }

    calc_steps() {
      local n="$1" s=0
      while [[ "$n" -gt 1 ]]; do n=$((n / 2)); s=$((s + 1)); done
      echo "$s"
    }

    resolve_input() {
      local label="$1" raw="$2" pos=""
      if is_position "$raw"; then pos="$raw"
      elif is_version "$raw"; then
        pos=$(resolve_version_to_position "$raw") || true
        if [[ -z "$pos" ]]; then
          log_error "Could not resolve $label version '$raw'"; exit 1
        fi
      else
        log_error "Invalid $label value '$raw'"; exit 1
      fi
      echo "$pos"
    }

    GOOD_POS=$(resolve_input "good" "$GOOD_INPUT")
    BAD_POS=$(resolve_input "bad" "$BAD_INPUT")

    if [[ "$GOOD_POS" -gt "$BAD_POS" ]]; then
      log_warn "Good ($GOOD_POS) > bad ($BAD_POS) — swapping."
      tmp="$GOOD_POS"; GOOD_POS="$BAD_POS"; BAD_POS="$tmp"
    fi
    if [[ "$GOOD_POS" -eq "$BAD_POS" ]]; then
      log_error "Same position ($GOOD_POS). Nothing to bisect."; exit 1
    fi

    WORK_DIR=$(mktemp -d)
    log_info "Working directory: $WORK_DIR"

    log_info "Verifying snapshots at range endpoints …"
    GOOD_SNAP=$(find_nearest_snapshot "$GOOD_POS" "$GOOD_POS" "$BAD_POS") || true
    if [[ -z "$GOOD_SNAP" ]]; then
      log_error "No snapshot near good position $GOOD_POS"; exit 1
    fi
    [[ "$GOOD_SNAP" != "$GOOD_POS" ]] && log_warn "Using nearest good: $GOOD_SNAP"
    GOOD_POS="$GOOD_SNAP"

    BAD_SNAP=$(find_nearest_snapshot "$BAD_POS" "$GOOD_POS" "$BAD_POS") || true
    if [[ -z "$BAD_SNAP" ]]; then
      log_error "No snapshot near bad position $BAD_POS"; exit 1
    fi
    [[ "$BAD_SNAP" != "$BAD_POS" ]] && log_warn "Using nearest bad: $BAD_SNAP"
    BAD_POS="$BAD_SNAP"

    range=$((BAD_POS - GOOD_POS))
    echo ""
    echo -e "''${BOLD}  chrome-bisect''${NC}"
    echo -e "  Good : ''${GREEN}$GOOD_POS''${NC}"
    echo -e "  Bad  : ''${RED}$BAD_POS''${NC}"
    echo -e "  Range: $range positions (~$(calc_steps "$range") steps)"
    echo ""

    lo="$GOOD_POS"
    hi="$BAD_POS"
    step=0

    while [[ $((hi - lo)) -gt 1 ]]; do
      step=$((step + 1))
      est=$(calc_steps $((hi - lo)))
      mid=$(( (lo + hi) / 2 ))

      echo ""
      echo -e "''${BOLD}═══ Step $step (~$est left) ═══  [$lo .. $hi]''${NC}"

      actual=$(find_nearest_snapshot "$mid" "$lo" "$hi") || true
      if [[ -z "$actual" ]]; then
        actual=$(find_nearest_snapshot $(( (lo + mid) / 2 )) "$lo" "$hi") || true
      fi
      if [[ -z "$actual" ]]; then
        actual=$(find_nearest_snapshot $(( (mid + hi) / 2 )) "$lo" "$hi") || true
      fi
      if [[ -z "$actual" ]]; then
        log_warn "No testable snapshots in [$lo … $hi]. Stopping."; break
      fi
      if [[ "$actual" -le "$lo" || "$actual" -ge "$hi" ]]; then
        log_warn "Nearest snapshot ($actual) at boundary — done."; break
      fi

      [[ "$actual" != "$mid" ]] && log_info "Nearest snapshot: $actual"

      snap_dir="$WORK_DIR/snap-$actual"
      mkdir -p "$snap_dir"
      chrome_bin=$(download_and_find_chrome "$actual" "$snap_dir") || true

      if [[ -z "$chrome_bin" ]]; then
        log_warn "Skipping $actual (could not prepare)."
        SKIPPED="$SKIPPED$actual:"
        rm -rf "$snap_dir"; continue
      fi

      echo ""
      log_info "Launching Chromium at position ''${BOLD}$actual''${NC} …"
      echo ""

      profile_dir="$WORK_DIR/profile-$actual"
      mkdir -p "$profile_dir"
      if [[ -n "$WRAPPER_CMD" ]]; then
        $WRAPPER_CMD "$chrome_bin" --no-first-run --no-default-browser-check \
          --no-sandbox --user-data-dir="$profile_dir" 2>/dev/null || true
      else
        "$chrome_bin" --no-first-run --no-default-browser-check \
          --no-sandbox --user-data-dir="$profile_dir" 2>/dev/null || true
      fi

      echo ""
      while true; do
        printf "  ''${BOLD}Position %d — [g]ood / [b]ad / [s]kip / [q]uit?''${NC} " "$actual"
        read -r verdict || { echo ""; log_warn "EOF — aborting."; exit 1; }
        case "$verdict" in
          g|good) log_good "Position $actual → GOOD"; lo="$actual"; break ;;
          b|bad)  log_bad  "Position $actual → BAD";  hi="$actual"; break ;;
          s|skip) log_warn "Position $actual → SKIP"; SKIPPED="$SKIPPED$actual:"; break ;;
          q|quit) echo "Aborted."; exit 0 ;;
          *) echo "  Enter g, b, s, or q." ;;
        esac
      done
      rm -rf "$snap_dir" "$profile_dir"
    done

    echo ""
    echo -e "''${BOLD}══════════ BISECT COMPLETE ($step steps) ══════════''${NC}"
    echo ""
    echo -e "  ''${GREEN}✓ Last good :''${NC} $lo"
    echo -e "  ''${RED}✗ First bad :''${NC} $hi"
    echo -e "  Window: $((hi - lo)) position(s)"
    echo ""
    echo "  Changes: https://chromium.googlesource.com/chromium/src/+log/$lo..$hi"
    echo "  Good: https://crrev.com/$lo"
    echo "  Bad:  https://crrev.com/$hi"
    echo ""
  '';
}
