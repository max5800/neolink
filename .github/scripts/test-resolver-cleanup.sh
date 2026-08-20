#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-publication-binding.sh
source "${script_dir}/resolve-publication-binding.sh"

test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

repository=max5800/neolink
repository_id=424242
merge_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
previous_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
reviewed_sha=cccccccccccccccccccccccccccccccccccccccc
head_ref=openclaw/durable-binding
pr_number=17
run_id=123456
check_suite_id=456789
artifact_id=987654
fixture_dir="${test_root}/fixtures"
mkdir -- "${fixture_dir}"

jq --null-input \
  --arg repository "${repository}" --argjson repository_id "${repository_id}" \
  --arg merge_sha "${merge_sha}" --arg previous_sha "${previous_sha}" \
  --arg reviewed_sha "${reviewed_sha}" --arg head_ref "${head_ref}" \
  --argjson pr_number "${pr_number}" '[{
    number: $pr_number, state: "closed", merged_at: "2026-08-20T08:00:00Z", draft: false,
    merge_commit_sha: $merge_sha,
    base: {ref: "master", sha: $previous_sha, repo: {full_name: $repository, id: $repository_id}},
    head: {ref: $head_ref, sha: $reviewed_sha, repo: {full_name: $repository, id: $repository_id}}
  }]' >"${fixture_dir}/pulls.json"

jq --null-input \
  --arg repository "${repository}" --argjson repository_id "${repository_id}" \
  --arg reviewed_sha "${reviewed_sha}" --arg head_ref "${head_ref}" \
  --argjson run_id "${run_id}" --argjson check_suite_id "${check_suite_id}" '{
    total_count: 1,
    workflow_runs: [{
      id: $run_id, check_suite_id: $check_suite_id, event: "pull_request",
      status: "completed", conclusion: "success", run_attempt: 1,
      path: ".github/workflows/validate.yml", head_sha: $reviewed_sha,
      head_branch: $head_ref, head_commit: {id: $reviewed_sha},
      head_repository: {full_name: $repository, id: $repository_id},
      repository: {full_name: $repository, id: $repository_id}
    }]
  }' >"${fixture_dir}/runs.json"
jq '.workflow_runs[0]' "${fixture_dir}/runs.json" >"${fixture_dir}/run.json"

jq --null-input --arg reviewed_sha "${reviewed_sha}" --argjson run_id "${run_id}" '{
  total_count: 1,
  jobs: [{
    name: "validate-linux-amd64", run_id: $run_id, run_attempt: 1, head_sha: $reviewed_sha,
    status: "completed", conclusion: "success",
    run_url: ("https://api.github.com/repos/max5800/neolink/actions/runs/" + ($run_id | tostring)),
    steps: [
      {name: "Test the workspace with all features", conclusion: "success"},
      {name: "Upload durable publication binding", conclusion: "success"}
    ]
  }]
}' >"${fixture_dir}/jobs.json"

write_binding_document "${fixture_dir}/publication-binding.json" \
  "${repository}" "${repository_id}" "${pr_number}" \
  "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}" \
  "${previous_sha}" master "${repository}" "${repository_id}" \
  "${run_id}" 1 "${repository}/.github/workflows/validate.yml@refs/pull/${pr_number}/merge"

python3 - "${fixture_dir}/publication-binding.json" "${fixture_dir}/binding.zip" <<'PY'
import pathlib
import sys
import zipfile

binding, archive = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    zf.write(binding, "publication-binding.json")
PY

artifact_size="$(wc -c <"${fixture_dir}/binding.zip" | tr -d ' ')"
artifact_digest="$(sha256_file "${fixture_dir}/binding.zip")"
jq --null-input --arg reviewed_sha "${reviewed_sha}" --arg digest "sha256:${artifact_digest}" \
  --argjson size "${artifact_size}" --argjson run_id "${run_id}" --argjson artifact_id "${artifact_id}" '{
    total_count: 1,
    artifacts: [{
      id: $artifact_id,
      name: ("publication-binding-" + $reviewed_sha + "-" + ($run_id | tostring) + "-1"),
      expired: false, digest: $digest, size_in_bytes: $size,
      workflow_run: {id: $run_id},
      archive_download_url: ("https://api.github.com/repos/max5800/neolink/actions/artifacts/" + ($artifact_id | tostring) + "/zip")
    }]
  }' >"${fixture_dir}/artifacts.json"

run_resolver_case() {
  local mode="$1" expected_status="$2"
  local case_dir="${test_root}/${mode}" resolver_dir status
  resolver_dir="${case_dir}/resolver temp 'quoted' [glob]"
  mkdir -p -- "${case_dir}"
  printf '%s\n' keep >"${case_dir}/sibling-sentinel"

  set +e
  (
    set -euo pipefail
    export FIXTURE_DIR="${fixture_dir}" RESOLVER_DIR="${resolver_dir}" CASE_MODE="${mode}"
    export MERGE_SHA="${merge_sha}" PREVIOUS_MASTER_SHA="${previous_sha}" MERGE_HEAD_SHA="${reviewed_sha}"
    export GITHUB_REPOSITORY="${repository}" GITHUB_REPOSITORY_ID="${repository_id}"
    export GITHUB_TOKEN=offline-test-token GITHUB_OUTPUT="${case_dir}/github-output"

    mktemp() {
      test "$#" -eq 1 && test "$1" = -d
      mkdir -- "${RESOLVER_DIR}"
      printf '%s\n' "${RESOLVER_DIR}"
    }

    api_get() {
      local endpoint="$1" output="$2" headers="$3" fixture
      printf 'HTTP/1.1 200 OK\r\n\r\n' >"${headers}"
      if test "${CASE_MODE}" = failure; then
        printf '%s\n' partial >"${RESOLVER_DIR}/partial-response"
        return 77
      fi
      if test "${CASE_MODE}" = signal; then
        printf '%s\n' partial >"${RESOLVER_DIR}/partial-response"
        python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
      fi
      case "${endpoint}" in
        */commits/*/pulls*) fixture=pulls.json ;;
        */actions/workflows/validate.yml/runs*) fixture=runs.json ;;
        */actions/runs/"${run_id}"/jobs*) fixture=jobs.json ;;
        */actions/runs/"${run_id}"/artifacts*) fixture=artifacts.json ;;
        */actions/runs/"${run_id}") fixture=run.json ;;
        *) return 78 ;;
      esac
      cp -- "${FIXTURE_DIR}/${fixture}" "${output}"
    }

    curl() {
      local output= argument
      while test "$#" -gt 0; do
        argument="$1"
        shift
        case "${argument}" in
          --output) output="$1"; shift ;;
          --write-out) shift ;;
        esac
      done
      test -n "${output}"
      cp -- "${FIXTURE_DIR}/binding.zip" "${output}"
      printf 200
    }

    main
    grep -Fqx "pr_number=${pr_number}" "${GITHUB_OUTPUT}"
    grep -Fqx "pr_head_sha=${reviewed_sha}" "${GITHUB_OUTPUT}"
    grep -Fqx "validation_run_id=${run_id}" "${GITHUB_OUTPUT}"
  )
  status=$?
  set -e

  test "${status}" -eq "${expected_status}"
  test ! -e "${resolver_dir}"
  grep -Fqx keep "${case_dir}/sibling-sentinel"
}

run_resolver_case success 0
run_resolver_case failure 77
run_resolver_case signal 143

publication_binding_temp_dir=
cleanup_publication_binding_temp_dir

printf '%s\n' 'publication binding resolver cleanup regressions: PASS'
