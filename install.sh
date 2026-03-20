#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# orc installer — tmux-based orchestrator for OpenCode
# ============================================================================

VERSION="0.1.0"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Logging ─────────────────────────────────────────────────────────────────
info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

# ── Paths ───────────────────────────────────────────────────────────────────
ORC_INSTALL_DIR="${ORC_INSTALL_DIR:-$HOME/.local/share/orc}"
ORC_BIN_DIR="${ORC_BIN_DIR:-$HOME/.local/bin}"
ORC_CONFIG_DIR="$HOME/.config/opencode"
ORC_FALLBACK_DIR="$HOME/.config/orc"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
${BOLD}orc installer${NC} v${VERSION}

Usage:
  ${BOLD}install.sh${NC}              Install orc
  ${BOLD}install.sh --uninstall${NC}  Uninstall orc
  ${BOLD}install.sh --help${NC}       Show this help

Environment variables:
  ORC_INSTALL_DIR   Installation directory (default: ~/.local/share/orc)
  ORC_BIN_DIR       Binary symlink directory (default: ~/.local/bin)

EOF
    exit 0
}

# ── Preflight checks ───────────────────────────────────────────────────────
preflight_checks() {
    info "Running preflight checks..."
    local missing=()

    # bash >= 4.0
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        missing+=("bash >= 4.0 (current: ${BASH_VERSION})")
    fi

    # tmux
    if ! command -v tmux &>/dev/null; then
        missing+=("tmux — install via: brew install tmux / apt install tmux")
    fi

    # jq
    if ! command -v jq &>/dev/null; then
        missing+=("jq — install via: brew install jq / apt install jq")
    fi

    # opencode
    if ! command -v opencode &>/dev/null; then
        missing+=("opencode — install via: curl -fsSL https://opencode.ai/install | bash")
    fi

    # git
    if ! command -v git &>/dev/null; then
        missing+=("git — install via: brew install git / apt install git")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            printf "  ${RED}✗${NC} %s\n" "$dep" >&2
        done
        die "Install the missing dependencies and try again."
    fi

    success "All preflight checks passed"
}

# ── Check PATH ──────────────────────────────────────────────────────────────
check_path() {
    if [[ ":$PATH:" != *":${ORC_BIN_DIR}:"* ]]; then
        warn "${ORC_BIN_DIR} is not in your PATH"
        warn "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
        printf "  ${BOLD}export PATH=\"%s:\$PATH\"${NC}\n" "$ORC_BIN_DIR"
        echo ""
    fi
}

# ── Install binaries ───────────────────────────────────────────────────────
install_binaries() {
    info "Installing orc binaries..."

    mkdir -p "$ORC_BIN_DIR"
    mkdir -p "$ORC_INSTALL_DIR"

    # Determine source: local git repo or remote clone
    if [[ -f "$SCRIPT_DIR/orc_agent" && -f "$SCRIPT_DIR/orc" ]]; then
        info "Installing from local repository: $SCRIPT_DIR"
        # Copy all project files to install dir (if not already there)
        if [[ "$SCRIPT_DIR" != "$ORC_INSTALL_DIR" ]]; then
            cp -R "$SCRIPT_DIR/"* "$ORC_INSTALL_DIR/" 2>/dev/null || true
            # Also copy hidden dirs like .opencode
            for hidden in "$SCRIPT_DIR"/.opencode "$SCRIPT_DIR"/.orchestrator; do
                if [[ -d "$hidden" ]]; then
                    cp -R "$hidden" "$ORC_INSTALL_DIR/" 2>/dev/null || true
                fi
            done
        fi
    else
        info "Cloning orc repository..."
        if [[ -d "$ORC_INSTALL_DIR/.git" ]]; then
            info "Repository already exists, pulling latest..."
            git -C "$ORC_INSTALL_DIR" pull --ff-only 2>/dev/null || warn "Could not pull latest changes"
        else
            git clone https://github.com/PLACEHOLDER/orc.git "$ORC_INSTALL_DIR" 2>/dev/null \
                || die "Failed to clone repository. Check the URL and your internet connection."
        fi
    fi

    # Make executables
    chmod +x "$ORC_INSTALL_DIR/orc" 2>/dev/null || true
    chmod +x "$ORC_INSTALL_DIR/orc_agent" 2>/dev/null || true

    # Create symlinks (idempotent — remove old ones first)
    for bin in orc orc_agent; do
        local target="$ORC_BIN_DIR/$bin"
        if [[ -L "$target" || -f "$target" ]]; then
            rm -f "$target"
        fi
        ln -s "$ORC_INSTALL_DIR/$bin" "$target"
    done

    success "Binaries installed to $ORC_INSTALL_DIR"
    success "Symlinks created in $ORC_BIN_DIR"
}

# ── Install OpenCode agents (native mode) ──────────────────────────────────
install_opencode_agents() {
    info "Installing orc agents into OpenCode..."

    # Create directories
    mkdir -p "$ORC_CONFIG_DIR/agents"
    mkdir -p "$ORC_CONFIG_DIR/tools"
    mkdir -p "$ORC_CONFIG_DIR/plugins"

    # Copy agent definitions
    local agents_src="$ORC_INSTALL_DIR/.opencode/agents"
    if [[ -d "$agents_src" ]]; then
        for agent_file in "$agents_src"/orc-*.md; do
            if [[ -f "$agent_file" ]]; then
                local basename
                basename="$(basename "$agent_file")"
                cp "$agent_file" "$ORC_CONFIG_DIR/agents/$basename"
                success "  Installed agent: $basename"
            fi
        done
    else
        warn "No agent files found in $agents_src"
    fi

    # Copy custom tools
    local tools_src="$ORC_INSTALL_DIR/.opencode/tools"
    if [[ -d "$tools_src" ]]; then
        for tool_file in "$tools_src"/*; do
            if [[ -f "$tool_file" ]]; then
                local basename
                basename="$(basename "$tool_file")"
                cp "$tool_file" "$ORC_CONFIG_DIR/tools/$basename"
                success "  Installed tool: $basename"
            fi
        done
    else
        info "No custom tools to install (directory not found yet)"
    fi

    # Copy plugins
    local plugins_src="$ORC_INSTALL_DIR/.opencode/plugins"
    if [[ -d "$plugins_src" ]]; then
        for plugin_file in "$plugins_src"/*; do
            if [[ -f "$plugin_file" ]]; then
                local basename
                basename="$(basename "$plugin_file")"
                cp "$plugin_file" "$ORC_CONFIG_DIR/plugins/$basename"
                success "  Installed plugin: $basename"
            fi
        done
    else
        info "No plugins to install (directory not found yet)"
    fi

    # Ensure package.json exists with @opencode-ai/plugin
    local pkg_json="$ORC_CONFIG_DIR/package.json"
    if [[ ! -f "$pkg_json" ]]; then
        info "Creating package.json with @opencode-ai/plugin dependency..."
        cat > "$pkg_json" <<'PKGJSON'
{
  "dependencies": {
    "@opencode-ai/plugin": "latest"
  }
}
PKGJSON
        success "  Created $pkg_json"
    else
        # Check if @opencode-ai/plugin is already a dependency
        if ! jq -e '.dependencies["@opencode-ai/plugin"]' "$pkg_json" &>/dev/null; then
            info "Adding @opencode-ai/plugin to existing package.json..."
            local tmp
            tmp=$(mktemp)
            jq '.dependencies["@opencode-ai/plugin"] = "latest"' "$pkg_json" > "$tmp" && mv "$tmp" "$pkg_json"
            success "  Added @opencode-ai/plugin dependency"
        else
            info "  @opencode-ai/plugin already in package.json"
        fi
    fi

    # Merge opencode.json — add orc tool permissions
    local opencode_json="$ORC_CONFIG_DIR/opencode.json"
    if [[ -f "$opencode_json" ]]; then
        info "Updating opencode.json with orc tool permissions..."
        local tmp
        tmp=$(mktemp)
        # Add permissions for orc tools if not already present
        jq '
            .permission = (.permission // {}) |
            .permission.orc_done = (.permission.orc_done // "allow") |
            .permission.orc_reply = (.permission.orc_reply // "allow") |
            .permission.orc_spawn = (.permission.orc_spawn // "allow")
        ' "$opencode_json" > "$tmp" && mv "$tmp" "$opencode_json"
        success "  Updated opencode.json"
    else
        info "Creating opencode.json with orc configuration..."
        cat > "$opencode_json" <<'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "orc_done": "allow",
    "orc_reply": "allow",
    "orc_spawn": "allow"
  }
}
OCJSON
        success "  Created $opencode_json"
    fi

    success "OpenCode agents installed successfully"
}

# ── Install fallback mode (without OpenCode integration) ───────────────────
install_fallback() {
    info "Setting up fallback mode (without OpenCode agent integration)..."

    mkdir -p "$ORC_FALLBACK_DIR/agents"

    # Copy agent descriptions for prompt injection
    local agents_src="$ORC_INSTALL_DIR/.opencode/agents"
    if [[ -d "$agents_src" ]]; then
        for agent_file in "$agents_src"/orc-*.md; do
            if [[ -f "$agent_file" ]]; then
                local basename
                basename="$(basename "$agent_file")"
                cp "$agent_file" "$ORC_FALLBACK_DIR/agents/$basename"
                success "  Copied agent: $basename"
            fi
        done
    fi

    # Create fallback config
    cat > "$ORC_FALLBACK_DIR/config.json" <<'FALLBACK'
{
  "fallback_mode": true,
  "agents_dir": "~/.config/orc/agents",
  "note": "Agents will be injected via prompt rather than native OpenCode agents. Run install.sh again and choose Y to enable native mode."
}
FALLBACK

    success "Fallback mode configured at $ORC_FALLBACK_DIR"
    warn "Agents will work via prompt injection (less efficient than native OpenCode agents)"
    info "Run install.sh again and choose Y to enable native OpenCode agent mode"
}

# ── Ask about agent installation ────────────────────────────────────────────
ask_install_agents() {
    printf "\n${BOLD}Install custom agents into OpenCode?${NC}\n"
    printf "This will add orc agents to ~/.config/opencode/agents/\n"
    printf "[Y/n]: "
    read -r answer

    # Default to Y
    answer="${answer:-Y}"

    case "$answer" in
        [Yy]|[Yy][Ee][Ss])
            install_opencode_agents
            ;;
        [Nn]|[Nn][Oo])
            install_fallback
            ;;
        *)
            install_opencode_agents
            ;;
    esac
}

# ── Final verification ──────────────────────────────────────────────────────
final_check() {
    echo ""
    info "Running final verification..."

    if command -v orc &>/dev/null; then
        success "orc is accessible in PATH"
    else
        warn "orc is not in PATH yet"
        warn "Add ${ORC_BIN_DIR} to your PATH and restart your shell"
    fi

    if command -v orc_agent &>/dev/null; then
        success "orc_agent is accessible in PATH"
    else
        warn "orc_agent is not in PATH yet"
    fi

    echo ""
    printf "${GREEN}${BOLD}Installation complete!${NC}\n"
    echo ""
    echo "Usage:"
    printf "  ${BOLD}orc${NC}               Start the orc orchestrator\n"
    printf "  ${BOLD}orc --help${NC}        Show help\n"
    echo ""
    echo "Quick start:"
    printf "  ${BOLD}cd /path/to/project${NC}\n"
    printf "  ${BOLD}orc${NC}\n"
    echo ""

    if [[ ":$PATH:" != *":${ORC_BIN_DIR}:"* ]]; then
        echo "Don't forget to add orc to your PATH:"
        printf "  ${BOLD}export PATH=\"%s:\$PATH\"${NC}\n" "$ORC_BIN_DIR"
        echo ""
    fi
}

# ── Uninstall ───────────────────────────────────────────────────────────────
uninstall() {
    info "Uninstalling orc..."

    # Remove symlinks
    for bin in orc orc_agent; do
        local target="$ORC_BIN_DIR/$bin"
        if [[ -L "$target" ]]; then
            rm -f "$target"
            success "Removed symlink: $target"
        elif [[ -f "$target" ]]; then
            warn "Skipping $target — not a symlink (manual removal required)"
        fi
    done

    # Remove install dir
    if [[ -d "$ORC_INSTALL_DIR" ]]; then
        rm -rf "$ORC_INSTALL_DIR"
        success "Removed install directory: $ORC_INSTALL_DIR"
    fi

    # Remove fallback config
    if [[ -d "$ORC_FALLBACK_DIR" ]]; then
        rm -rf "$ORC_FALLBACK_DIR"
        success "Removed fallback config: $ORC_FALLBACK_DIR"
    fi

    # Do NOT remove ~/.config/opencode/ files
    info "OpenCode agent files in ~/.config/opencode/ were NOT removed"
    info "Remove them manually if needed:"
    printf "  rm ~/.config/opencode/agents/orc-*.md\n"
    printf "  rm ~/.config/opencode/tools/orc_*.ts\n"
    printf "  rm ~/.config/opencode/plugins/orc-*.ts\n"

    echo ""
    success "orc has been uninstalled"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --help|-h)
            usage
            ;;
        --uninstall)
            uninstall
            exit 0
            ;;
        --version|-v)
            echo "orc installer v${VERSION}"
            exit 0
            ;;
    esac

    echo ""
    printf "${BOLD}orc installer${NC} v${VERSION}\n"
    printf "tmux-based orchestrator for OpenCode\n"
    echo ""

    preflight_checks
    check_path
    install_binaries
    ask_install_agents
    final_check
}

main "$@"
