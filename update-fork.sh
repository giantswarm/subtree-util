#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# are we in a git repository
if [ ! -d ".git" ]; then
  echo -e "Error:\n.git directory not found.\nExecute this script inside a git repository"
  exit 1
fi

# query the name of the default branch (main/master) branch
# this will also fail when there is no "upstream" remote
default_branch=$(git remote show upstream | grep "HEAD branch" | sed "s/.*: //")

# try to switch to branch named "upstream-${default_branch}"
# this will fail if the branch could not be found
git checkout "upstream-${default_branch}"

# fetch from upstream
git fetch upstream

# merge default branch from upstream into your local upstream-${default_branch} branch
git merge --no-edit "upstream/${default_branch}"

# switch to our default branch
git checkout "${default_branch}"

# merge upstream changes
git merge --no-edit "upstream-${default_branch}"

read -r -p "Do you wish to execute 'git push origin '${default_branch}'? (Y/N): " answer
case $answer in
    [Yy]* ) git push origin "${default_branch}";;
    * ) echo "Not pushing";;
esac
