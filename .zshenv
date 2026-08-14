
# npm: settings live here, not in ~/.npmrc. npm rewrites that file with an auth
# token on every login, so it is gitignored and holds credentials only.
# Mirrored in ~/.profile, which zsh does not read.
export NPM_CONFIG_PACKAGE_LOCK=false
# nvm refuses to load while NPM_CONFIG_PREFIX is set — it manages a prefix per
# node version. So set ours only where nvm isn't in use: hosts running the OS's
# node, where global installs need a writable prefix of their own. The PATH
# entry is unguarded because npm creates the directory on first global install.
if [ ! -d "$HOME/.nvm" ]; then
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
fi

export GITHUB_USERNAME=mark-brannan
