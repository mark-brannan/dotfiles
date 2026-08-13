
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

# npm: settings live here, not in ~/.npmrc. npm rewrites that file with an auth
# token on every login, so it is gitignored and holds credentials only.
# Mirrored in ~/.profile, which zsh does not read.
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export NPM_CONFIG_PACKAGE_LOCK=false
[ -d "$NPM_CONFIG_PREFIX/bin" ] && export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"

export GITHUB_USERNAME=mark-brannan
