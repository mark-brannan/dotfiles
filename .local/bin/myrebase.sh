#!/usr/bin/env sh

# Not claude_prompts_scratch: the Stop hook syncs that clone under its own lock; an unlocked rebase races it.
{
cat<<EOF
.github
dotfiles
claude
symphony
home-automation
saferspacesllc
stranger-loops
homebrew-tap
coderabbit
EOF
cat ~/.local/share/vended-repos.txt
} | while read i
do
    echo "============================== ($i)"
    cd ~/"$i" || { echo "No such directory for '$i'"; continue; }
    pwd
    git -c color.ui=always status -s -b --untracked-files=no
    git checkout main -q || echo "Could not checkout main"
    git pull origin main --rebase --autostash || echo "Failed to pull/rebase $i" 
done
