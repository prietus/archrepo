#!/usr/bin/env bash
#
# Runs the whole repo pipeline inside the cluster on a stock `archlinux:base-devel`
# image — no custom image, no registry. The build logic and the PKGBUILDs are
# delivered as ConfigMaps (see `make sync`).
#
# Two-phase execution:
#   * As root (first entry): install nvchecker/makepkg tooling, create the unprivileged
#     `builder` user, unpack the source bundle, then re-exec itself as `builder`.
#   * As builder: check upstream versions, rebuild changed packages, sign, publish.
#
# All persistent state (packages, the .db, nvchecker history, pacman cache) lives under
# $REPO_ROOT — the shared PVC that nginx serves.
set -euo pipefail

REPO_NAME="${REPO_NAME:-myrepo}"
REPO_ROOT="${REPO_ROOT:-/srv/repo}"
ARCH="${ARCH:-x86_64}"
PKGBUILD_DIR="${PKGBUILD_DIR:-$HOME/pkgbuilds}"
NVCHECKER_TOML="${NVCHECKER_TOML:-$HOME/nvchecker/nvchecker.toml}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m!!>\033[0m %s\n' "$*" >&2; }

# =========================================================================
# Phase 1 — privileged bootstrap (only when launched as root in the cluster)
# =========================================================================
if [[ "$(id -u)" -eq 0 ]]; then
  log "Bootstrapping stock Arch image"
  # Make the PVC writable by the unprivileged builder (uid 1000), regardless of how
  # the StorageClass (e.g. NFS) created the directory.
  mkdir -p "$REPO_ROOT"
  chown 1000:1000 "$REPO_ROOT"
  # Persist pacman's package cache on the PVC so hourly runs don't re-download.
  PAC_CACHE="${REPO_ROOT}/.cache/pacman-pkg"
  mkdir -p "$PAC_CACHE"
  pacman -Sy --noconfirm --needed --cachedir "$PAC_CACHE" \
      nvchecker pacman-contrib jq git

  # Register our own repo so makepkg --syncdeps can resolve inter-package deps against
  # packages we built in a previous run (or earlier in this one). SigLevel TrustAll:
  # these are our own freshly-built, locally-signed files served straight off the PVC.
  if ! grep -q "^\[$REPO_NAME\]" /etc/pacman.conf; then
    cat >> /etc/pacman.conf <<EOF

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = file://$REPO_ROOT/\$arch
EOF
  fi
  # Seed pacman's sync db with whatever we built in earlier runs (no network needed).
  install -d /var/lib/pacman/sync
  if [[ -f "$REPO_ROOT/$ARCH/$REPO_NAME.db.tar.zst" ]]; then
    cp -fL "$REPO_ROOT/$ARCH/$REPO_NAME.db.tar.zst" "/var/lib/pacman/sync/$REPO_NAME.db"
  fi

  # Trust our signing key in pacman's keyring. Without this, installing our own signed
  # packages as build deps from [myrepo] fails with "required key missing from keyring"
  # (SigLevel TrustAll is not enough — pacman still verifies the package signature).
  if [[ -f /secrets/gpg-private-key ]]; then
    pacman-key --init >/dev/null 2>&1 || true   # idempotent; no-op if already initialized
    _tg="$(mktemp -d)"
    gpg --homedir "$_tg" --batch --quiet --import /secrets/gpg-private-key
    _kid="$(gpg --homedir "$_tg" --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
    gpg --homedir "$_tg" --batch --export "$_kid" > /tmp/archrepo-signing.pub
    pacman-key --add /tmp/archrepo-signing.pub
    pacman-key --lsign-key "$_kid"
    rm -rf "$_tg" /tmp/archrepo-signing.pub
  fi

  id -u builder &>/dev/null || useradd -m -u 1000 -U builder
  printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
  chmod 0440 /etc/sudoers.d/builder

  # Source bundle (pkgbuilds/ + nvchecker/) mounted from the archrepo-src ConfigMap.
  if [[ -f /src/src.tar.gz ]]; then
    tar -xzf /src/src.tar.gz -C /home/builder
  fi
  chown -R builder:builder /home/builder

  # Drop privileges and re-run this same script as the builder user.
  exec runuser -u builder -- env \
      HOME=/home/builder \
      REPO_NAME="$REPO_NAME" REPO_ROOT="$REPO_ROOT" ARCH="$ARCH" \
      bash "${BASH_SOURCE[0]}" "$@"
fi

# =========================================================================
# Phase 2 — unprivileged build (runs as the `builder` user)
# =========================================================================
PKGDIR="${REPO_ROOT}/${ARCH}"
STATE_DIR="${REPO_ROOT}/state"
DB="${PKGDIR}/${REPO_NAME}.db.tar.zst"
mkdir -p "$PKGDIR" "$STATE_DIR"

# --- GPG signing setup ----------------------------------------------------
# Secret mounted at /secrets. Private key required; passphrase file optional.
SIGN_ARGS=()
REPOADD_SIGN=()
if [[ -f /secrets/gpg-private-key ]]; then
  export GNUPGHOME="$HOME/.gnupg"
  install -d -m700 "$GNUPGHOME"
  gpg --batch --quiet --import /secrets/gpg-private-key
  printf 'pinentry-mode loopback\n' > "$GNUPGHOME/gpg.conf"
  printf 'allow-loopback-pinentry\n' > "$GNUPGHOME/gpg-agent.conf"
  if [[ -f /secrets/gpg-passphrase ]]; then
    printf 'passphrase-file /secrets/gpg-passphrase\n' >> "$GNUPGHOME/gpg.conf"
  fi
  GPGKEY="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
  export GPGKEY
  export PACKAGER="${PACKAGER:-Arch Repo Builder <archrepo@example.com>}"
  SIGN_ARGS=(--sign --key "$GPGKEY")
  REPOADD_SIGN=(--sign --key "$GPGKEY")
  log "GPG signing enabled (key ${GPGKEY})"
else
  err "No /secrets/gpg-private-key found — building UNSIGNED packages"
fi

# --- nvchecker ------------------------------------------------------------
# The keyfile (GitHub API token) must be passed with -k; nvchecker does NOT read any
# NVCHECKER_KEYFILE env var. Without it we hit GitHub's 60 req/h unauthenticated limit
# and many github-source packages silently fail to resolve a version.
KEY_ARGS=()
if [[ -f /secrets/nvchecker-keyfile ]]; then
  KEY_ARGS=(-k /secrets/nvchecker-keyfile)
  log "Using nvchecker keyfile (authenticated GitHub API)"
fi

log "Checking upstream versions with nvchecker"
nvchecker -c "$NVCHECKER_TOML" "${KEY_ARGS[@]}"

# nvcmp prints one line per changed entry: "<name> <oldver> <newver>".
mapfile -t CHANGED < <(nvcmp -c "$NVCHECKER_TOML" | awk 'NF>=2 && $1 !~ /^#/ {print $1"\t"$NF}')

if [[ ${#CHANGED[@]} -eq 0 ]]; then
  log "No version changes — nothing to build."
  exit 0
fi
log "${#CHANGED[@]} package(s) to (re)build"

# --- build (multi-pass) ---------------------------------------------------
# nvcmp lists changed packages alphabetically, NOT in dependency order, so a package
# can be attempted before a sibling it depends on (e.g. caelestia-cli before
# python-materialyoucolor). We build in passes: a package that fails *only* because a
# dependency isn't in [myrepo] yet is retried next pass, after its siblings have built
# and been published. A pass that builds nothing ends the loop. Real (compile) failures
# are detected and NOT retried, so an expensive build (dlib) isn't repeated for nothing.
built=()

# Build one "pkg<TAB>newver" entry in the current shell (mutates $built).
# Returns: 0 = built OK, 2 = failed on unmet deps (retry later), 3 = permanent failure.
build_one() {
  local entry="$1" pkg newver src work mklog f
  pkg="${entry%%$'\t'*}"
  newver="${entry##*$'\t'}"
  src="$PKGBUILD_DIR/$pkg"

  if [[ ! -f "$src/PKGBUILD" ]]; then
    err "nvchecker entry '$pkg' has no $src/PKGBUILD — skipping"
    return 3
  fi

  log "Building $pkg => $newver"
  work="$(mktemp -d)"
  cp -rT "$src" "$work"
  pushd "$work" >/dev/null

  # VCS packages (-git/-hg/...) carry a pkgver() function: makepkg clones the source and
  # computes the real version (e.g. r1234.gdeadbeef) itself. For those we must NOT rewrite
  # pkgver or run updpkgsums (sources are SKIP'd) — just let makepkg do its job.
  if grep -qE '^[[:space:]]*pkgver[[:space:]]*\(\)' PKGBUILD; then
    log "  $pkg is a VCS package — pkgver() will be computed by makepkg"
    sed -i -E "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
  else
    sed -i -E "s/^pkgver=.*/pkgver=${newver}/" PKGBUILD
    sed -i -E "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    # Metapackages have no source=() array — updpkgsums errors with nothing to checksum.
    if grep -qE '^[[:space:]]*source(_[a-z0-9_]+)?=' PKGBUILD; then
      if ! updpkgsums; then
        err "updpkgsums failed for $pkg"
        popd >/dev/null; rm -rf "$work"; return 3
      fi
    else
      log "  $pkg has no source array — skipping updpkgsums"
    fi
  fi

  # Metapackages (no source array, nothing to compile) must NOT resolve/install their
  # runtime deps at build time — those resolve at install time on the user's machine.
  # Building such a package with --syncdeps would try to pacman -S all 20+ depends (incl.
  # siblings not yet built) and fail. Build it with --nodeps instead.
  local dep_args=(--syncdeps --rmdeps)
  if ! grep -qE '^[[:space:]]*source(_[a-z0-9_]+)?=' PKGBUILD; then
    dep_args=(--nodeps)
    log "  $pkg has no sources — building as metapackage (--nodeps)"
  fi

  mklog="$work/.makepkg.log"
  if makepkg --force --clean --cleanbuild "${dep_args[@]}" --noconfirm "${SIGN_ARGS[@]}" 2>&1 | tee "$mklog"; then
    local newfiles=()
    shopt -s nullglob
    for f in *.pkg.tar.zst; do
      cp -f "$f" "$PKGDIR/"
      [[ -f "$f.sig" ]] && cp -f "$f.sig" "$PKGDIR/"
      built+=("$PKGDIR/$f")
      newfiles+=("$PKGDIR/$f")
    done
    shopt -u nullglob
    # Publish immediately and refresh pacman's sync copy so later packages in this run
    # can resolve sibling deps from [myrepo] via makepkg --syncdeps.
    if [[ ${#newfiles[@]} -gt 0 ]]; then
      repo-add "${REPOADD_SIGN[@]}" "$DB" "${newfiles[@]}"
      sudo cp -fL "$DB" "/var/lib/pacman/sync/${REPO_NAME}.db" 2>/dev/null || true
    fi
    nvtake -c "$NVCHECKER_TOML" "$pkg"   # record version only after a successful build
    log "OK: $pkg $newver"
    popd >/dev/null; rm -rf "$work"; return 0
  fi

  # Failed: unmet deps (retry next pass) or a genuine build error (give up)?
  local rc=2
  grep -qiE 'failed to install missing dependencies|could not satisfy|unresolvable package dependencies|target not found' "$mklog" || rc=3
  popd >/dev/null; rm -rf "$work"; return $rc
}

pending=( "${CHANGED[@]}" )
permfail=()
pass=0
while [[ ${#pending[@]} -gt 0 ]]; do
  pass=$((pass + 1))
  log "=== Build pass $pass — ${#pending[@]} package(s) to attempt ==="
  progress=0
  retry=()
  for entry in "${pending[@]}"; do
    build_one "$entry" && rc=0 || rc=$?
    case "$rc" in
      0) progress=1 ;;
      2) retry+=("$entry"); log "  deferred (missing sibling dep): ${entry%%$'\t'*}" ;;
      *) permfail+=("$entry"); err "Build FAILED (permanent) for ${entry%%$'\t'*}" ;;
    esac
  done
  pending=( "${retry[@]}" )
  # No package built this pass => the remaining deferred deps will never appear; stop.
  [[ $progress -eq 0 ]] && break
done

for entry in "${pending[@]}"; do
  err "Build FAILED for ${entry%%$'\t'*} — dependency not available, will retry next run"
done

# --- summary --------------------------------------------------------------
# Packages are added to the DB incrementally as they build (see loop above), so the
# repo stays consistent and self-referential even if a later package fails.
if [[ ${#built[@]} -gt 0 ]]; then
  log "Published ${#built[@]} package file(s) to ${REPO_NAME} in $pass pass(es)"
fi
failcount=$(( ${#permfail[@]} + ${#pending[@]} ))
[[ $failcount -gt 0 ]] && err "$failcount package(s) failed this run (see FAILED lines above)"

log "Done."
