#!/usr/bin/env bash
# =============================================================================
# share-access/setup.sh — one-time setup so a machine can run this project's
# deployment scripts (scripts/*.sh) against the shared AWS account.
#
# WHAT IT DOES
#   1. Installs the CLI tools the scripts need — AWS CLI v2, curl, unzip, and
#      (best effort) the AWS Session Manager plugin for interactive SSM.
#   2. Writes an AWS named profile from the credentials in share-access/SECRETS,
#      into ~/.aws/credentials and ~/.aws/config.
#   3. Persists AWS_PROFILE so scripts/*.sh authenticate as that profile, and
#      marks the scripts executable.
#
# OWNER — before sharing the project:
#   Copy share-access/SECRETS.template to share-access/SECRETS and fill in your AWS
#   credentials. share-access/SECRETS is git-ignored, so it never reaches GitHub —
#   but it IS included in a project .zip.
#
# FRIEND / NEW MACHINE — after cloning or unzipping:
#   1. Create the secrets file:  cp share-access/SECRETS.template share-access/SECRETS
#      then fill it in. (Skip if you got a zip that already contains SECRETS.)
#   2. From the project root run:  bash share-access/setup.sh
#   3. Open a new terminal (or `export AWS_PROFILE=mc_server`) and use the
#      scripts, e.g.   ./scripts/deploy.sh 1.20.4
#
# SECURITY: share-access/SECRETS holds live AWS credentials. It is git-ignored so
# it never reaches GitHub. A project .zip DOES contain it — share zips
# privately; anyone with the credentials has the same AWS access you do.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ---- Non-secret config (tracked in git — safe to commit) ------------------
AWS_REGION="us-east-1"      # default region for the deployment
PROFILE_NAME="mc_server"    # AWS profile name the scripts run under
# ---------------------------------------------------------------------------

say()  { printf '  %s\n'   "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!] %s\n'  "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

echo "=== mc_server project setup ==="

# --- 0. Load secrets -------------------------------------------------------
# Credentials live in share-access/SECRETS — git-ignored, never committed. Create
# it by copying share-access/SECRETS.template (which IS tracked in git).
SECRETS_FILE="$SCRIPT_DIR/SECRETS"
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
AWS_ACCOUNT_ID=""
if [ ! -f "$SECRETS_FILE" ]; then
  die "No share-access/SECRETS file. Create it:  cp share-access/SECRETS.template share-access/SECRETS  — then fill it in."
fi
# shellcheck disable=SC1090
. "$SECRETS_FILE"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  die "share-access/SECRETS is missing AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY — fill them in."
fi

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Linux*)               PLATFORM=linux ;;
  Darwin*)              PLATFORM=macos ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)                    PLATFORM=unknown ;;
esac
say "Platform: $OS ($PLATFORM)"

SUDO=""
if [ "$(id -u 2>/dev/null || echo 0)" != "0" ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# --- 1. CLI tools ----------------------------------------------------------
echo ""
echo "[1/4] CLI tools"

ensure_pkg() {  # $1=command  $2=package
  command -v "$1" >/dev/null 2>&1 && { ok "$1 present"; return 0; }
  say "Installing $2 ..."
  {
    if   command -v apt-get >/dev/null 2>&1; then $SUDO apt-get update -qq && $SUDO apt-get install -y "$2"
    elif command -v dnf     >/dev/null 2>&1; then $SUDO dnf install -y "$2"
    elif command -v yum     >/dev/null 2>&1; then $SUDO yum install -y "$2"
    elif command -v brew    >/dev/null 2>&1; then brew install "$2"
    else false
    fi
  } || warn "Could not auto-install $2 — install it manually if a script needs it."
  return 0
}
ensure_pkg curl curl
ensure_pkg unzip unzip

# AWS CLI v2
if command -v aws >/dev/null 2>&1; then
  ok "AWS CLI present: $(aws --version 2>&1 | head -1)"
else
  say "Installing AWS CLI v2 ..."
  TMP="$(mktemp -d)"
  case "$PLATFORM" in
    linux)
      ( curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$TMP/awscliv2.zip" \
        && unzip -q "$TMP/awscliv2.zip" -d "$TMP" \
        && $SUDO "$TMP/aws/install" --update ) \
        || warn "AWS CLI install failed — install manually: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      ;;
    macos)
      ( curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$TMP/AWSCLIV2.pkg" \
        && $SUDO installer -pkg "$TMP/AWSCLIV2.pkg" -target / ) \
        || warn "AWS CLI install failed — install manually: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      ;;
    windows)
      ( curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.msi" -o "$TMP/AWSCLIV2.msi" \
        && msiexec //i "$(cygpath -w "$TMP/AWSCLIV2.msi" 2>/dev/null || echo "$TMP/AWSCLIV2.msi")" //qn ) \
        || warn "AWS CLI MSI install failed — install manually: https://awscli.amazonaws.com/AWSCLIV2.msi"
      ;;
    *)
      warn "Unknown OS — install AWS CLI v2 manually: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      ;;
  esac
  rm -rf "$TMP"
  command -v aws >/dev/null 2>&1 && ok "AWS CLI installed" \
    || warn "AWS CLI not on PATH yet — reopen the terminal after setup finishes."
fi

# AWS Session Manager plugin (optional — only for interactive `aws ssm start-session`)
if command -v session-manager-plugin >/dev/null 2>&1; then
  ok "Session Manager plugin present"
else
  say "Installing Session Manager plugin (optional) ..."
  TMP="$(mktemp -d)"
  SMP="https://s3.amazonaws.com/session-manager-downloads/plugin/latest"
  case "$PLATFORM" in
    linux)
      if command -v dpkg >/dev/null 2>&1; then
        case "$(uname -m)" in x86_64) D=ubuntu_64bit ;; aarch64) D=ubuntu_arm64 ;; *) D="" ;; esac
        [ -n "$D" ] && { ( curl -fsSL "$SMP/$D/session-manager-plugin.deb" -o "$TMP/smp.deb" \
          && $SUDO dpkg -i "$TMP/smp.deb" ) || warn "SSM plugin install failed (non-fatal)."; }
      elif command -v rpm >/dev/null 2>&1; then
        case "$(uname -m)" in x86_64) D=linux_64bit ;; aarch64) D=linux_arm64 ;; *) D="" ;; esac
        [ -n "$D" ] && { ( curl -fsSL "$SMP/$D/session-manager-plugin.rpm" -o "$TMP/smp.rpm" \
          && $SUDO yum install -y "$TMP/smp.rpm" ) || warn "SSM plugin install failed (non-fatal)."; }
      fi
      ;;
    macos)
      ( curl -fsSL "$SMP/mac/sessionmanager-bundle.zip" -o "$TMP/smp.zip" \
        && unzip -q "$TMP/smp.zip" -d "$TMP" \
        && $SUDO "$TMP/sessionmanager-bundle/install" -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin ) \
        || warn "SSM plugin install failed (non-fatal)."
      ;;
    *)
      warn "Skipping SSM plugin auto-install on this OS — install manually if you need interactive SSM:"
      warn "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
      ;;
  esac
  rm -rf "$TMP"
fi

# --- 2. AWS profile --------------------------------------------------------
echo ""
echo "[2/4] AWS profile '$PROFILE_NAME'"

# Idempotently replace (or add) an INI section in a file.
write_ini_section() {  # $1=file  $2=header  $3=body
  local file="$1" header="$2" body="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  awk -v hdr="$header" '
    $0==hdr { skip=1; next }
    /^\[/   { skip=0 }
    !skip   { print }
  ' "$file" > "$file.ajtmp"
  { cat "$file.ajtmp"; printf '%s\n%s\n' "$header" "$body"; } > "$file"
  rm -f "$file.ajtmp"
  chmod 600 "$file"
}

write_ini_section "$HOME/.aws/credentials" "[$PROFILE_NAME]" \
"aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY"

write_ini_section "$HOME/.aws/config" "[profile $PROFILE_NAME]" \
"region = $AWS_REGION
output = json"

ok "Wrote profile '$PROFILE_NAME' to ~/.aws/credentials and ~/.aws/config"

# --- 3. Make the scripts use this profile ----------------------------------
echo ""
echo "[3/4] Wire up AWS_PROFILE + script permissions"

EXPORT_LINE="export AWS_PROFILE=$PROFILE_NAME"
case "${SHELL:-/bin/bash}" in
  *zsh) RC="$HOME/.zshrc" ;;
  *)    RC="$HOME/.bashrc" ;;
esac
touch "$RC"
if grep -qF "$EXPORT_LINE" "$RC" 2>/dev/null; then
  ok "$RC already sets AWS_PROFILE=$PROFILE_NAME"
else
  printf '\n# mc_server project — added by share-access/setup.sh\n%s\n' "$EXPORT_LINE" >> "$RC"
  ok "Added '$EXPORT_LINE' to $RC"
fi

chmod +x "$PROJECT_ROOT"/scripts/*.sh 2>/dev/null || true
chmod +x "$SCRIPT_DIR"/*.sh           2>/dev/null || true
ok "Marked scripts/*.sh executable"

# --- 4. Verify -------------------------------------------------------------
echo ""
echo "[4/4] Verify"
export AWS_PROFILE="$PROFILE_NAME"
if command -v aws >/dev/null 2>&1; then
  ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")"
  if [ -n "$ACCT" ] && [ "$ACCT" != "None" ]; then
    ok "Authenticated to AWS account $ACCT"
    if [ -n "$AWS_ACCOUNT_ID" ] && [ "$ACCT" != "$AWS_ACCOUNT_ID" ]; then
      warn "Account $ACCT does not match expected $AWS_ACCOUNT_ID — double-check the keys."
    fi
  else
    warn "Could not authenticate — verify the access key id and secret are correct."
  fi
else
  warn "AWS CLI is not on PATH in this shell yet (common right after install)."
  warn "Reopen the terminal, then verify with:  AWS_PROFILE=$PROFILE_NAME aws sts get-caller-identity"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "For THIS terminal session:   export AWS_PROFILE=$PROFILE_NAME"
echo "New terminals pick it up automatically (added to $RC)."
echo ""
echo "Then run the deployment scripts from the project root, e.g.:"
echo "  ./scripts/deploy.sh 1.20.4"
echo "  ./scripts/server-start.sh 1.20.4"
echo "  ./scripts/server-stop.sh 1.20.4"
