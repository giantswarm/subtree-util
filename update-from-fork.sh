#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

ORG="giantswarm"

# are we in a git repository
if [ ! -d ".git" ]; then
  echo -e "Error:\n.git directory not found.\nExecute this script inside a git repository"
  exit 1
fi

# positional parameters
fork_clone_url=${1:-}
fork_chart_path=${2:-}
fork_target_ref=${3:-}
target_app_path=${4:-}
pr_branch=${5:-}
subtree_mode=${6:-"merge"}
if [[ -z "${fork_clone_url}" || -z "${fork_chart_path}" || -z "${fork_target_ref}" || -z "${target_app_path}" || -z "${pr_branch}" ]]; then
  echo "usage: $0 fork_git-clone-url fork_chart_path fork_target_ref target_app_path pr_branch_name subtree_mode"
  echo "fork_target_ref = 'tag:REMOTE_TAG|branch:REMOTE_BRANCH'"
  echo "subtree_mode = [add|merge]"
  exit 1
fi

fork_target_type=${fork_target_ref%:*}
fork_target_name=${fork_target_ref#*:}

if [ "${subtree_mode}" == "merge" && ! -d "${target_app_path}" ]; then
  echo -e "Error:\n'${target_app_path}' target directory not found."
  exit 1
fi

if [ "${subtree_mode}" == "add" && -d "${target_app_path}" ]; then
  echo -e "Error:\n'${target_app_path}' target directory already exists."
  exit 1
fi

# check if we already have the remote
set +e
remote_exists=$(git remote -v | grep -q "upstream-copy\s*${fork_clone_url}")
retval=$?
set -e

if [[ "${retval}" != 0 ]]; then
  echo "Did not find upstream-copy remote, setting it up."

  # set up "upstream" remote
  git remote add -f --no-tags upstream-copy "${fork_clone_url}"
fi

# we need this for querying the github api
fork_repo_name="${fork_clone_url##*/}"
fork_repo_name="${fork_repo_name%.git}"

# query the forks default branch, we need it for setting up the remote and other stuff
fork_repo_info=$(curl --silent -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${ORG}/${fork_repo_name}")

# determine default branch of our repo
default_branch=$(git remote show origin | grep "HEAD branch" | sed "s/.*: //")

# go to default branch
git checkout "${default_branch}"

# update the default branch
git pull origin "${default_branch}"

# fetch the named branched or tag state from the fork
# checkout the named branched or tag state from the fork
if [[ "${fork_target_type}" == "tag" ]]; then
  # we might already have the tag and git will complain
  set +e
  git fetch upstream-copy --tags "${fork_target_name}"
  set -e
  git checkout "${fork_target_name}"
else
  git fetch upstream-copy "${fork_target_name}"
  git checkout "upstream-copy/${fork_target_name}"
fi


# extract the path we require into a branch named temp-split-branch
git subtree split -P "${fork_chart_path}" -b temp-split-branch

# create the pr branch from the default branch of the repository
git checkout -b "${pr_branch}" "${default_branch}"

# merge back from the temp-split-branch
git subtree -d "${subtree_mode}" --squash -P "${target_app_path}" temp-split-branch

git branch -D temp-split-branch
