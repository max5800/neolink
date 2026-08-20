#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-publication-binding.sh
source "${script_dir}/resolve-publication-binding.sh"

temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT

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

pr_file="${temp_dir}/pr.json"
runs_file="${temp_dir}/runs.json"
run_file="${temp_dir}/run.json"
jobs_file="${temp_dir}/jobs.json"
artifacts_file="${temp_dir}/artifacts.json"
binding_file="${temp_dir}/binding.json"

jq --null-input \
  --arg repository "${repository}" --argjson repository_id "${repository_id}" \
  --arg merge_sha "${merge_sha}" --arg previous_sha "${previous_sha}" \
  --arg reviewed_sha "${reviewed_sha}" --arg head_ref "${head_ref}" \
  --argjson pr_number "${pr_number}" '[{
    number: $pr_number, state: "closed", merged_at: "2026-08-20T08:00:00Z", draft: false,
    merge_commit_sha: $merge_sha,
    base: {ref: "master", sha: $previous_sha, repo: {full_name: $repository, id: $repository_id}},
    head: {ref: $head_ref, sha: $reviewed_sha, repo: {full_name: $repository, id: $repository_id}}
  }]' >"${pr_file}"

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
      repository: {full_name: $repository, id: $repository_id},
      pull_requests: []
    }]
  }' >"${runs_file}"
jq '.workflow_runs[0]' "${runs_file}" >"${run_file}"

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
}' >"${jobs_file}"

jq --null-input --arg reviewed_sha "${reviewed_sha}" --argjson run_id "${run_id}" \
  --argjson artifact_id "${artifact_id}" '{
    total_count: 1,
    artifacts: [{
      id: $artifact_id,
      name: ("publication-binding-" + $reviewed_sha + "-" + ($run_id | tostring) + "-1"),
      expired: false, digest: ("sha256:" + ("d" * 64)), size_in_bytes: 512,
      workflow_run: {id: $run_id},
      archive_download_url: ("https://api.github.com/repos/max5800/neolink/actions/artifacts/" + ($artifact_id | tostring) + "/zip")
    }]
  }' >"${artifacts_file}"

jq --null-input --sort-keys \
  --arg repository "${repository}" --argjson repository_id "${repository_id}" \
  --argjson pr_number "${pr_number}" --arg reviewed_sha "${reviewed_sha}" \
  --arg head_ref "${head_ref}" --arg previous_sha "${previous_sha}" \
  --argjson run_id "${run_id}" '{
    schema: "neolink-publication-binding/v1", event_name: "pull_request",
    repository: $repository, repository_id: $repository_id, pull_request_number: $pr_number,
    head_sha: $reviewed_sha, head_ref: $head_ref,
    head_repository: $repository, head_repository_id: $repository_id,
    base_sha: $previous_sha, base_ref: "master",
    base_repository: $repository, base_repository_id: $repository_id,
    run_id: $run_id, run_attempt: 1,
    workflow_ref: ($repository + "/.github/workflows/validate.yml@refs/pull/" + ($pr_number | tostring) + "/merge")
  }' >"${binding_file}"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    printf 'expected command to fail:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    exit 1
  fi
}

# The durable path must pass even when GitHub clears workflow_run.pull_requests after merge.
pr_record="$(select_pr_record "${pr_file}" "${repository}" "${repository_id}" "${merge_sha}" "${previous_sha}" "${reviewed_sha}")"
test "$(jq -r '.number' <<<"${pr_record}")" = "${pr_number}"
validation_record="$(select_validation_record "${runs_file}" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}")"
test "$(jq -r '.id' <<<"${validation_record}")" = "${run_id}"
verify_run_detail "${run_file}" "${run_id}" "${check_suite_id}" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
verify_validation_jobs "${jobs_file}" "${run_id}" "${reviewed_sha}"
select_binding_artifact "${artifacts_file}" "${run_id}" "${reviewed_sha}" >/dev/null
verify_binding_document "${binding_file}" "${repository}" "${repository_id}" "${pr_number}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}" "${previous_sha}" "${run_id}"

# Wrong repository, branch/field injection, a rerun, ambiguity, absent evidence, and PR mismatch fail closed.
jq '.workflow_runs[0].head_repository.full_name = "attacker/neolink"' "${runs_file}" >"${temp_dir}/wrong-repo.json"
expect_failure select_validation_record "${temp_dir}/wrong-repo.json" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
jq '.workflow_runs[0].head_branch = "openclaw/durable-binding\nforged=1"' "${runs_file}" >"${temp_dir}/injected-branch.json"
expect_failure select_validation_record "${temp_dir}/injected-branch.json" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
jq '.workflow_runs[0].run_attempt = 2' "${runs_file}" >"${temp_dir}/rerun.json"
expect_failure select_validation_record "${temp_dir}/rerun.json" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
jq '.total_count = 2 | .workflow_runs += [.workflow_runs[0]]' "${runs_file}" >"${temp_dir}/ambiguous.json"
expect_failure select_validation_record "${temp_dir}/ambiguous.json" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
jq '.total_count = 101' "${runs_file}" >"${temp_dir}/paginated.json"
expect_failure select_validation_record "${temp_dir}/paginated.json" "${repository}" "${repository_id}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}"
jq '.artifacts = [] | .total_count = 0' "${artifacts_file}" >"${temp_dir}/absent-artifact.json"
expect_failure select_binding_artifact "${temp_dir}/absent-artifact.json" "${run_id}" "${reviewed_sha}"
jq '.[0].head.sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "${pr_file}" >"${temp_dir}/wrong-pr-head.json"
expect_failure select_pr_record "${temp_dir}/wrong-pr-head.json" "${repository}" "${repository_id}" "${merge_sha}" "${previous_sha}" "${reviewed_sha}"
jq '.pull_request_number += 1' "${binding_file}" >"${temp_dir}/wrong-binding-pr.json"
expect_failure verify_binding_document "${temp_dir}/wrong-binding-pr.json" "${repository}" "${repository_id}" "${pr_number}" "${reviewed_sha}" "${head_ref}" "${repository}" "${repository_id}" "${previous_sha}" "${run_id}"

printf '%s\n' 'publication binding offline regressions: PASS'
