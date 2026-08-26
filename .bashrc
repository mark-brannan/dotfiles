# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u\[\033[00m\]@\[\033[01;33m\]\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Fall back rather than name an editor that may not be installed: EDITOR
# pointing at a missing binary breaks git, crontab and anything else that
# shells out to it.
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
elif type -p nvim >/dev/null; then
  export EDITOR='nvim'
elif type -p vim >/dev/null; then
  export EDITOR='vim'
else
  export EDITOR='vi'
fi
set -o vi
alias gedit=gvim
alias st='git status'

# --- Everything below is machine-dependent. This file is shared across macOS,
# --- WSL and the Pi by yadm, so each block guards on what it needs. ---

# AWS CLI completions
[ -x /usr/local/bin/aws_completer ] && complete -C /usr/local/bin/aws_completer aws
[ -d /usr/local/aws/bin ] && export PATH="/usr/local/aws/bin:$PATH"

# rbenv, where it is installed
if [ -d "$HOME/.rbenv" ]; then
    export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/plugins/ruby-build/bin:$PATH"
    eval "$(rbenv init -)"
fi

# Docker Desktop adds this on macOS; there is no such file on Linux.
[ -r "$HOME/.docker/init-bash.sh" ] && . "$HOME/.docker/init-bash.sh"

# imageio needs an absolute ffmpeg path, and it differs per platform.
if command -v ffmpeg >/dev/null 2>&1; then
    export IMAGEIO_FFMPEG_EXE="$(command -v ffmpeg)"
fi

# One-command sync across machines. --autostash so local churn never blocks the
# pull, and `yadm alt` so os-alternates relink immediately afterwards.
alias dotsync='yadm pull --rebase --autostash && yadm alt && yadm status --short'

# Run from inside the plain ~/dotfiles clone after committing there: pushes it,
# then folds that same history into $HOME via yadm so edits made in the clone
# don't need a separate manual sync step. Only makes sense from that clone --
# $HOME itself is yadm's own worktree, not a plain repo `git push` understands.
alias dotpush='git push && (cd ~ && dotsync)'

# Secrets decrypted by `yadm bootstrap` (sops+age) land here, never in git.
# See secrets/*.sops.env and .config/yadm/bootstrap. Mirrors the loop in .zshrc;
# without it, bash-only hosts never load them. The glob is unquoted on purpose,
# and the -r test covers the no-match case. claude-token.env is excluded on
# purpose — see the `claude` wrapper below, which scopes
# CLAUDE_CODE_OAUTH_TOKEN to just that command instead of exporting it into
# every shell and everything the shell spawns.
for _secret_file in "$HOME"/.config/secrets/*.env; do
    case "$_secret_file" in
        */claude-token.env) continue ;;
    esac
    [ -r "$_secret_file" ] && . "$_secret_file"
done
unset _secret_file
export CLAUDE_CODE_TMPDIR="$HOME/.local/state/claude-tmpdir"

# CLAUDE_CODE_OAUTH_TOKEN stays out of the general environment (see the
# excluded loop above) and is exported only for the duration of this one
# command, in a subshell, so it never leaks into the interactive shell.
claude() {
    _tok="$HOME/.config/secrets/claude-token.env"
    if [ -r "$_tok" ]; then
        ( . "$_tok" && command claude "$@" )
    else
        command claude "$@"
    fi
}
