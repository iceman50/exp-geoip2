#!/usr/bin/env bash
#
# geolite2-to-github.sh
#
# Downloads the latest MaxMind GeoLite2 databases and publishes them as assets
# on a GitHub release (one release per database build, e.g. geolite2-20261124).
# Runs are idempotent: if the release for the current build already exists,
# nothing is downloaded or uploaded.
#
# Requirements (Debian): curl, tar, coreutils, util-linux (flock), gh
#   sudo apt install curl gh
#   gh auth login                 # or export GH_TOKEN=...
#
# Configuration: ~/.config/geolite2-github.conf (override with GEOLITE2_CONFIG)
# or environment variables:
#   MAXMIND_ACCOUNT_ID   MaxMind account ID                        (required)
#   MAXMIND_LICENSE_KEY  MaxMind license key                       (required)
#   GITHUB_REPO          target repository, owner/name             (required)
#   EDITIONS             space-separated edition IDs  (default: ASN City Country)
#   TAG_PREFIX           release tag prefix           (default: geolite2-)
#   UPLOAD_TARBALLS      1 = also upload the original .tar.gz files (default: 0)
#   KEEP_RELEASES        keep only the newest N releases, 0 = all  (default: 0)
#
# Usage: geolite2-to-github.sh [--force] [--dry-run]
#   --force    re-upload (overwrite assets) even if the release already exists
#   --dry-run  download and verify only; don't touch GitHub

set -Eeuo pipefail

CONFIG_FILE="${GEOLITE2_CONFIG:-$HOME/.config/geolite2-github.conf}"
if [[ -f $CONFIG_FILE ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

EDITIONS="${EDITIONS:-GeoLite2-ASN GeoLite2-City GeoLite2-Country}"
TAG_PREFIX="${TAG_PREFIX:-geolite2-}"
UPLOAD_TARBALLS="${UPLOAD_TARBALLS:-0}"
KEEP_RELEASES="${KEEP_RELEASES:-0}"
FORCE=0
DRY_RUN=0

for arg in "$@"; do
  case $arg in
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: line $LINENO: $BASH_COMMAND"' ERR

[[ -n ${MAXMIND_ACCOUNT_ID:-} ]]  || die "MAXMIND_ACCOUNT_ID is not set (config: $CONFIG_FILE)"
[[ -n ${MAXMIND_LICENSE_KEY:-} ]] || die "MAXMIND_LICENSE_KEY is not set (config: $CONFIG_FILE)"
[[ ${GITHUB_REPO:-} == */* ]]     || die "GITHUB_REPO must be owner/name (config: $CONFIG_FILE)"

for cmd in curl tar sha256sum awk flock; do
  command -v "$cmd" >/dev/null || die "required command not found: $cmd"
done
if (( ! DRY_RUN )); then
  command -v gh >/dev/null || die "GitHub CLI not found: sudo apt install gh"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated: run 'gh auth login' or set GH_TOKEN"
fi

# Only one run at a time.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/geolite2-to-github.lock"
flock -n 9 || die "another run is already in progress"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Credentials go in a netrc file so the license key never shows up in the
# process list or a URL, and curl only sends them to download.maxmind.com
# (not to the storage host the download redirects to).
NETRC="$WORK_DIR/netrc"
( umask 077
  printf 'machine download.maxmind.com\nlogin %s\npassword %s\n' \
    "$MAXMIND_ACCOUNT_ID" "$MAXMIND_LICENSE_KEY" > "$NETRC" )

CURL=(curl --fail --silent --show-error --location
      --retry 3 --retry-delay 5 --connect-timeout 30
      --netrc-file "$NETRC")

mm_url() {
  printf 'https://download.maxmind.com/geoip/databases/%s/download?suffix=%s' "$1" "$2"
}

release_exists() {
  gh release view "$1" -R "$GITHUB_REPO" >/dev/null 2>&1
}

# Print the current build date (YYYYMMDD) of an edition using a HEAD request,
# which doesn't count towards MaxMind's daily download limit.
build_date() {
  local headers d
  headers="$("${CURL[@]}" --head "$(mm_url "$1" tar.gz)" 2>/dev/null)" || return 1
  d="$(grep -io 'filename=[^;]*' <<<"$headers" | grep -o '[0-9]\{8\}' | tail -n1 || true)"
  if [[ -z $d ]]; then
    d="$(grep -i '^last-modified:' <<<"$headers" | tail -n1 | cut -d' ' -f2- | tr -d '\r' || true)"
    if [[ -n $d ]]; then
      d="$(date -u -d "$d" +%Y%m%d 2>/dev/null || true)"
    fi
  fi
  [[ $d =~ ^[0-9]{8}$ ]] || return 1
  printf '%s\n' "$d"
}

# --- 1. Cheap check: is there anything new? ---------------------------------
latest=""
for ed in $EDITIONS; do
  if d="$(build_date "$ed")"; then
    if [[ $d > $latest ]]; then latest=$d; fi
  else
    log "couldn't read the build date of $ed with a HEAD request; downloading to find out"
    latest=""
    break
  fi
done

if [[ -n $latest ]] && (( ! FORCE && ! DRY_RUN )) && release_exists "$TAG_PREFIX$latest"; then
  log "release $TAG_PREFIX$latest already exists in $GITHUB_REPO; nothing to do"
  exit 0
fi

# --- 2. Download, verify and extract ----------------------------------------
ASSET_DIR="$WORK_DIR/assets"
mkdir -p "$ASSET_DIR"
build=""

for ed in $EDITIONS; do
  dl="$WORK_DIR/download/$ed"
  mkdir -p "$dl"
  log "downloading $ed"
  "${CURL[@]}" -o "$dl/db.tar.gz"        "$(mm_url "$ed" tar.gz)"
  "${CURL[@]}" -o "$dl/db.tar.gz.sha256" "$(mm_url "$ed" tar.gz.sha256)"

  expected="$(awk '{print $1; exit}' "$dl/db.tar.gz.sha256")"
  actual="$(sha256sum "$dl/db.tar.gz" | awk '{print $1}')"
  [[ -n $expected && $expected == "$actual" ]] \
    || die "$ed: SHA-256 mismatch (expected '$expected', got '$actual')"

  # The archive holds a single directory named <edition>_<YYYYMMDD>/.
  top="$(tar -tzf "$dl/db.tar.gz" | awk 'NR == 1')"
  top="${top%%/*}"
  d="${top##*_}"
  [[ $d =~ ^[0-9]{8}$ ]] || die "$ed: unexpected archive layout ('$top')"

  tar -xzf "$dl/db.tar.gz" -C "$dl" --no-same-owner
  [[ -f $dl/$top/$ed.mmdb ]] || die "$ed: $ed.mmdb not found in the archive"
  mv "$dl/$top/$ed.mmdb" "$ASSET_DIR/"
  if (( UPLOAD_TARBALLS )); then
    mv "$dl/db.tar.gz" "$ASSET_DIR/$ed.tar.gz"
  fi

  if [[ $d > $build ]]; then build=$d; fi
  log "$ed: build $d, checksum OK"
done

( cd "$ASSET_DIR" && sha256sum -- * > "$WORK_DIR/SHA256SUMS" )
mv "$WORK_DIR/SHA256SUMS" "$ASSET_DIR/"

tag="$TAG_PREFIX$build"
pretty="${build:0:4}-${build:4:2}-${build:6:2}"

if (( DRY_RUN )); then
  log "dry run: would publish release $tag to $GITHUB_REPO with:"
  ls -l "$ASSET_DIR" >&2
  exit 0
fi

# --- 3. Publish ---------------------------------------------------------------
notes="MaxMind GeoLite2 databases, build $pretty.

Editions: ${EDITIONS// /, }

This product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com."

if release_exists "$tag"; then
  if (( FORCE )); then
    log "release $tag exists; overwriting its assets (--force)"
    gh release upload "$tag" "$ASSET_DIR"/* -R "$GITHUB_REPO" --clobber
  else
    log "release $tag already exists in $GITHUB_REPO; nothing to do"
    exit 0
  fi
else
  log "creating release $tag in $GITHUB_REPO"
  gh release create "$tag" "$ASSET_DIR"/* -R "$GITHUB_REPO" \
    --title "GeoLite2 $pretty" --notes "$notes"
fi

# --- 4. Optionally prune old releases ----------------------------------------
if (( KEEP_RELEASES > 0 )); then
  # Tags embed the build date, so sorting by name sorts by age.
  mapfile -t old < <(
    gh api --paginate "repos/$GITHUB_REPO/releases?per_page=100" \
      --jq ".[].tag_name | select(startswith(\"$TAG_PREFIX\"))" \
    | sort -r | tail -n +"$((KEEP_RELEASES + 1))"
  )
  for t in "${old[@]}"; do
    log "deleting old release $t"
    gh release delete "$t" -R "$GITHUB_REPO" --yes --cleanup-tag
  done
fi

log "done: https://github.com/$GITHUB_REPO/releases/tag/$tag"
log "stable links: https://github.com/$GITHUB_REPO/releases/latest/download/<Edition>.mmdb"
