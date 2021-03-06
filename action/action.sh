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
  echo "Environment variable 'SOURCE_PATH' unset or not found."
  echo "TODO"
  exit 1
fi

log () {
  printf "[LOG] %s\n" "$*"
}

# set up name and email of git commiter..
git config --global user.email "action@github.com"
git config --global user.name "github-actions"

git config --global core.pager "cat"

log "Un-shallowing clone"
# repositories in GitHub actions are shallow clones, this makes sure we have a full copy
git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git fetch --quiet origin --unshallow --no-auto-gc

log "Querying information for ${GITHUB_REPOSITORY} from GitHub API"
# query the forks clone url, we need it for setting up the remote
repo_info=$(curl --silent -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${GITHUB_REPOSITORY}")
fork_clone_url=$(echo "$repo_info" | jq -cr ".parent.clone_url")
default_branch=$(echo "$repo_info" | jq -cr ".default_branch")

log "Parent clone url: ${fork_clone_url}"
log "Default branch of this repository: ${default_branch}"

# set up remote
log "Setting up remote 'upstream' with '${fork_clone_url}'"
git remote add upstream "${fork_clone_url}"
git fetch --quiet upstream

merge_from="upstream/${default_branch}"

if [[ -n "${SOURCE_TAG_WILDCARD}" ]]; then
  log "Environment variable 'SOURCE_TAG_WILDCARD' set to '${SOURCE_TAG_WILDCARD}'."

  # query the latest tag of the fork
  merge_from=$(git ls-remote --tags --sort -version:refname upstream "${SOURCE_TAG_WILDCARD}" | awk 'NR==1 {print $2;}')
  log "Latest ref from upstream '${SOURCE_TAG_WILDCARD}' is '${merge_from}'"
fi

log "Updating default branch from '${merge_from}'"
# merge upstream changes
git merge --no-edit "${merge_from}"

log "Pushing default branch to origin remote"
# push the updated default branch into the repository
git push origin "${default_branch}"

# authenticate using custom github token
echo -n "${TARGET_GITHUB_TOKEN}" > token
gh auth login --with-token < token

# check if an update from automation is already pending
# result is if there are no additional commits to the branch (additions == 1)
pr_list=$(gh --repo "${TARGET_REPOSITORY}" pr list --state open --label "automated-update" --json "additions" --author "@me")
pr_info=$(echo "$pr_list" | jq -cjr 'length, ",", .[1].additions | tostring')

log "Queried target PRs (open, with label 'automated-update', opened by automation)"
log "Result: ${pr_info} (number of matching PRs, number of additions)"

# if there are
# - no open prs from automation (0,null)
# - one open pr from automation and no external changes (1,null)
if [[ "${pr_info}" == "0,null" || "${pr_info}" == "1,null" ]]; then
  # clone the target repository
  log "Cloning the target repository (${TARGET_REPOSITORY}) into subfolder .target-repo"
  git clone "https://${TARGET_GITHUB_TOKEN}@github.com/${TARGET_REPOSITORY}.git" .target-repo

  # set up remote of target repository
  log "Setting up remote 'upstream-copy' in target repository clone"
  git -C .target-repo remote add upstream-copy ../
  git -C .target-repo fetch --quiet --no-tags upstream-copy

  # determine default branch of our repo
  target_default_branch=$(git -C .target-repo remote show origin | grep "HEAD branch" | sed "s/.*: //")
  log "Default branch of target repository is '${target_default_branch}'"

  # if the source path is the root of the repository, we can skip
  # the subtree split and git subtree merge directly into the target
  if [[ "${SOURCE_PATH}" == "." ]]; then
    log "SOURCE_PATH is '${SOURCE_PATH}'."
    # create the pr branch from the default branch of the repository
    log "Creating PR branch 'update-from-upstream' from '${target_default_branch}'"
    git -C .target-repo checkout -b update-from-upstream "${target_default_branch}"

    # git subtree merge the upstream-copy default branch
    log "git subtree merge --squash -P ${TARGET_PATH} upstream-copy/${default_branch}"
    git -C .target-repo subtree merge --squash -P "${TARGET_PATH}" "upstream-copy/${default_branch}"
  else
    # go to the default branch of the upstream-copy remote
    log "Checkout 'upstream-copy/${default_branch}' in target repository"
    git -C .target-repo checkout "upstream-copy/${default_branch}"

    # use cd, we're unsure if -C works well with git subtree
    cd .target-repo

    # extract the path we require into a branch named temp-split-branch
    log "git subtree split -P ${SOURCE_PATH} -b temp-split-branch"
    git subtree split -P "${SOURCE_PATH}" -b temp-split-branch

    # create the pr branch from the default branch of the repository
    log "Creating PR branch 'update-from-upstream' from '${target_default_branch}'"
    git checkout -b update-from-upstream "${target_default_branch}"

    # merge back from the temp-split-branch
    log "git subtree merge --squash -P ${TARGET_PATH} temp-split-branch"
    # Do not fail immediately. We want to try further merge conflict
    # autoresolving
    set +e
    subtree_merge_output=$(git subtree merge --squash -P "${TARGET_PATH}" temp-split-branch)
    retval=$?
    set -e

    if [[ "${subtree_merge_output}" == *"was never added"* ]]; then
      log "git substree merge had an error"
      log "${subtree_merge_output}"
      exit 1
    fi

    if [[ "${retval}" != 0 ]]; then
      # Capture a diff. It will be posted into the PR
      echo -e 'During subtree-merge there were some conflicts:\n```diff' > diff
      git diff --no-color >> diff
      echo '```' >> diff
      log "subtree merge had conflicts, trying to fix"
      git diff --name-only --diff-filter=U | xargs git checkout --ours
      git diff --name-only --diff-filter=U | xargs git add

      git commit --no-edit
    fi

    # cd back..
    cd ..
  fi

  touch .target-repo/diff

  if [[ "${pr_info}" == "0,null" ]]; then
    # push changes into branch
    log "Push changes into PR branch"
    git -C .target-repo push origin update-from-upstream

    # Create required label
    set +e
    curl --silent -f -X POST "https://api.github.com/repos/${TARGET_REPOSITORY}/labels" -H "Authorization: token ${TARGET_GITHUB_TOKEN}" -d '{"name":"automated-update","color":"e86d00","description":"Used to identify automated updates from upstream-forks"}'
    set -e
    # create a PR
    log "Creating PR"
    echo -e "This PR has been created from automation in https://github.com/${GITHUB_REPOSITORY}\n\n$(cat .target-repo/diff)" | \
      gh --repo "${TARGET_REPOSITORY}" pr create --title "Update from upstream" --base "${target_default_branch}" --head update-from-upstream --label "automated-update" --body-file -
  else
    # pull existing changes
    log "Pull changes from PR branch"
    git -C .target-repo pull origin update-from-upstream

    # push changes into branch
    log "Push changes into PR branch"
    git -C .target-repo push origin update-from-upstream

    # comment on PR
    log "Adding comment to existing PR"
    echo -e "Pushed through automation\n\n$(cat .target-repo/diff)" | \
      gh --repo "${TARGET_REPOSITORY}" pr comment "update-from-upstream" --body-file -
  fi
fi
