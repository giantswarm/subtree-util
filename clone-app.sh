#!/bin/bash
set -euo pipefail
IFS=$'\n\t'


# positional parameters
clone_url=${1:-}
fork_clone_url=${2:-}
# fork_chart_path=${2:-}
# target_app_path=${3:-}
# pr_branch=${4:-}
if [[ -z "${clone_url}" || -z "${fork_clone_url}" ]]; then
  echo "usage: $0 git-clone-url fork_git-clone-url"
  exit 1
fi

repo_name="${clone_url##*/}"
repo_name="${repo_name%.git}"

# clone the repo
git clone "${clone_url}" "${repo_name}"

# set up remote
git -C "${repo_name}" remote add -f --no-tags upstream-copy "${fork_clone_url}"
