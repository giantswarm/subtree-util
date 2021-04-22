#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ORG="giantswarm"

clone_url=${1:-}
if [[ -z "$clone_url" ]]; then
  echo "usage: $0 git-clone-url"
  exit 1
fi

repo_name="${clone_url##*/}"
repo_name="${repo_name%.git}"

# query the forks clone url, we need it for setting up the remote
repo_info=$(curl --silent -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${ORG}/${repo_name}")
fork_clone_url=$(echo "$repo_info" | jq -cr ".parent.clone_url")
default_branch=$(echo "$repo_info" | jq -cr ".default_branch")

# clone the fork
git clone "${clone_url}" "${repo_name}"

# set up remote
git -C "${repo_name}" remote add -f upstream "${fork_clone_url}"

# set up branch tracking
git -C "${repo_name}" switch -c "upstream-${default_branch}" "upstream/${default_branch}"
