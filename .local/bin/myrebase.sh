#!/usr/bin/env sh

while read i
do
    echo "============================== ($i)"
    cd ~/"$i" || { echo "No such directory for '$i'"; continue; }
    pwd
    git -c color.ui=always status -s -b --untracked-files=no
    git checkout main -q || echo "Could not checkout main"
    git pull origin main --rebase --autostash || echo "Failed to pull/rebase $i" 
done <~/.local/share/vended-repos.txt
