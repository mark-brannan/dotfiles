#!/usr/bin/env sh

{
cat<<EOF
dotfiles
symphony
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
