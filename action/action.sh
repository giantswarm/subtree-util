#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# are we in a git repository
if [ ! -d ".git" ]; then
  echo -e "Error:\n.git directory not found.\nExecute this script inside a git repository!"
  exit 1
fi

# check if we have the required env variables
if [[ -z "${GITHUB_REPOSITORY}" ]]; then
  echo "Environment variable 'GITHUB_REPOSITORY' unset or not found."
  echo "This can happen if you execute the action outside of a GitHub actions runner."
  echo "In this case, set it to ORG/REPOSITORY-NAME of your fork"
  exit 1
fi
if [[ -z "${TARGET_GITHUB_TOKEN}" ]]; then
  echo "Environment variable 'TARGET_GITHUB_TOKEN' unset or not found."
  echo "This can happen if you execute the action outside of a GitHub actions runner."
  echo "In this case, set it to a valid GitHub token with permissions on the target repository."
  exit 1
fi
if [[ -z "${TARGET_REPOSITORY}" ]]; then
  echo "Environment variable 'TARGET_REPOSITORY' unset or not found."
  echo "This can happen if you execute the action outside of a GitHub actions runner."
  echo "In this case, set it to a ORG/REPOSITORY-NAME of the repository to create the PR in."
  exit 1
fi
if [[ -z "${TARGET_PATH}" ]]; then
  echo "Environment variable 'TARGET_PATH' unset or not found."
  echo "TODO"
  exit 1
fi
if [[ -z "${SOURCE_PATH}" ]]; then
  echo "Environment variable 'INPUT_SOURCE_REPOSITORY' unset or not found."
  echo "TODO"
  exit 1
fi

# set up name and email of git commiter..
git config --global user.email "action@github.com"
git config --global user.name "github-actions"

# repositories in GitHub actions are shallow clones, this makes sure we have a full copy
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git fetch origin --unshallow

# query the forks clone url, we need it for setting up the remote
repo_info=$(curl --silent -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${GITHUB_REPOSITORY}")
fork_clone_url=$(echo "$repo_info" | jq -cr ".parent.clone_url")
default_branch=$(echo "$repo_info" | jq -cr ".default_branch")

# set up remote
git remote add -f upstream "${fork_clone_url}"

# set up branch tracking
git switch -c "upstream-${default_branch}" "upstream/${default_branch}"

# fetch from upstream
git fetch upstream

# merge default branch from upstream into your local upstream-${default_branch} branch
git merge --no-edit "upstream/${default_branch}"

# switch to our default branch
git checkout "${default_branch}"

# merge upstream changes
git merge --no-edit "upstream-${default_branch}"

# push the updated default branch into the repository
git push origin "${default_branch}"

# authenticate using custom github token
echo -n "${TARGET_GITHUB_TOKEN}" > token
gh auth login --with-token < token

# check if an update from automation is already pending
# result is if there are no additional commits to the branch (additions == 1)
pr_list=$(gh --repo "${TARGET_REPOSITORY}" pr list --state open --label "automated-update" --json "additions" --author "@me")
pr_info=$(echo "$pr_list" | jq -cjr 'length, ",", .[1].additions | tostring')


# if there are
# no open prs from automation (0,null)
# one open pr from automation and no external changes (1,1)
if [[ "${pr_info}" == "1,1" || "${pr_info}" == "0,null" ]]; then

  # clone the target repository
  gh repo clone "${TARGET_REPOSITORY}" .target-repo

  # set up remote of target repository
  git -C .target-repo remote add -f --no-tags upstream-copy ../

  # determine default branch of our repo
  target_default_branch=$(git -C .target-repo remote show origin | grep "HEAD branch" | sed "s/.*: //")

  # go to the default branch of the upstream-copy remote
  git -C .target-repo checkout "upstream-copy/${default_branch}"

  # extract the path we require into a branch named temp-split-branch
  git -C .target-repo subtree split -P "${SOURCE_PATH}" -b temp-split-branch

  # create the pr branch from the default branch of the repository
  git -C .target-repo checkout -b update-from-upstream "${target_default_branch}"

  # merge back from the temp-split-branch
  git -C .target-repo subtree merge --squash -P "${TARGET_PATH}" temp-split-branch

  # push changes into branch
  git -C .target-repo subtree push origin update-from-upstream

  if [[ "${pr_info}" == "0,null" ]]; then
    gh --repo "${TARGET_REPOSITORY}" pr create --title "Update from upstream" --base "${target_default_branch}" --head update-from-upstream --label "automated-update" --body "This PR has been created from automation in https://github.com/${GITHUB_REPOSITORY}"
  else
    gh --repo "${TARGET_REPOSITORY}" pr "update-from-upstream" --body "Force pushed through automation"
  fi
fi
