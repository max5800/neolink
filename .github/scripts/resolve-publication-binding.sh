#!/usr/bin/env bash
set -euo pipefail

readonly API_ROOT="https://api.github.com"
readonly VALIDATION_PATH=".github/workflows/validate.yml"
readonly VALIDATION_JOB="validate-linux-amd64"
readonly MAX_BINDING_ARCHIVE_BYTES=65536

publication_binding_temp_dir=

cleanup_publication_binding_temp_dir() {
  local exit_status=$? candidate="${publication_binding_temp_dir:-}"
  publication_binding_temp_dir=
  trap - EXIT HUP INT TERM

  case "${candidate}" in
    ''|'/'|'.'|'..') return "${exit_status}" ;;
  esac

  if ! rm -rf -- "${candidate}" && test "${exit_status}" -eq 0; then
    exit_status=1
  fi
  return "${exit_status}"
}

select_pr_record() {
  local response="$1" repository="$2" repository_id="$3"
  local merge_sha="$4" previous_sha="$5" reviewed_sha="$6"

  jq --exit-status --compact-output \
    --arg repository "${repository}" \
    --argjson repository_id "${repository_id}" \
    --arg merge_sha "${merge_sha}" \
    --arg previous_sha "${previous_sha}" \
    --arg reviewed_sha "${reviewed_sha}" '
      [ .[]
        | select(.state == "closed")
        | select(.merged_at != null)
        | select(.draft == false)
        | select(.merge_commit_sha == $merge_sha)
        | select(.base.ref == "master")
        | select(.base.sha == $previous_sha)
        | select(.base.repo.full_name == $repository)
        | select(.base.repo.id == $repository_id)
        | select(.head.sha == $reviewed_sha)
        | select(.head.repo.full_name == $repository)
        | select(.head.repo.id == $repository_id)
      ]
      | if length == 1 then .[0] else error("expected one exact same-repository merged PR") end
      | {
          number,
          head_sha: .head.sha,
          head_ref: .head.ref,
          head_repository: .head.repo.full_name,
          head_repository_id: .head.repo.id,
          base_sha: .base.sha
        }
      | select((.number | type) == "number" and .number > 0)
      | select(.head_ref | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$"))
      | select((.head_ref | contains("..") or contains("//") or endswith("/") or endswith(".lock")) | not)
    ' "${response}"
}

select_validation_record() {
  local response="$1" repository="$2" repository_id="$3" reviewed_sha="$4"
  local head_ref="$5" head_repository="$6" head_repository_id="$7"

  jq --exit-status --compact-output \
    --arg repository "${repository}" \
    --argjson repository_id "${repository_id}" \
    --arg reviewed_sha "${reviewed_sha}" \
    --arg head_ref "${head_ref}" \
    --arg head_repository "${head_repository}" \
    --argjson head_repository_id "${head_repository_id}" \
    --arg validation_path "${VALIDATION_PATH}" '
      if (.total_count | type) != "number" or .total_count > 100 then
        error("validation run result set exceeds the bounded first page")
      else . end
      | [ .workflow_runs[]
          | select(.event == "pull_request")
          | select(.status == "completed")
          | select(.conclusion == "success")
          | select(.run_attempt == 1)
          | select(.path == $validation_path)
          | select(.head_sha == $reviewed_sha)
          | select(.head_branch == $head_ref)
          | select(.head_repository.full_name == $head_repository)
          | select(.head_repository.id == $head_repository_id)
          | select(.repository.full_name == $repository)
          | select(.repository.id == $repository_id)
          | select(.head_commit.id == $reviewed_sha)
        ]
      | if length == 1 then .[0] else error("expected one successful first-attempt exact-source validation run") end
      | {id, check_suite_id, run_attempt, head_sha, head_branch, path}
      | select((.id | type) == "number" and .id > 0)
      | select((.check_suite_id | type) == "number" and .check_suite_id > 0)
    ' "${response}"
}

verify_run_detail() {
  local response="$1" run_id="$2" check_suite_id="$3" repository="$4" repository_id="$5"
  local reviewed_sha="$6" head_ref="$7" head_repository="$8" head_repository_id="$9"

  jq --exit-status \
    --argjson run_id "${run_id}" \
    --argjson check_suite_id "${check_suite_id}" \
    --arg repository "${repository}" \
    --argjson repository_id "${repository_id}" \
    --arg reviewed_sha "${reviewed_sha}" \
    --arg head_ref "${head_ref}" \
    --arg head_repository "${head_repository}" \
    --argjson head_repository_id "${head_repository_id}" \
    --arg validation_path "${VALIDATION_PATH}" '
      .id == $run_id
      and .check_suite_id == $check_suite_id
      and .event == "pull_request"
      and .status == "completed"
      and .conclusion == "success"
      and .run_attempt == 1
      and .path == $validation_path
      and .head_sha == $reviewed_sha
      and .head_branch == $head_ref
      and .head_repository.full_name == $head_repository
      and .head_repository.id == $head_repository_id
      and .repository.full_name == $repository
      and .repository.id == $repository_id
      and .head_commit.id == $reviewed_sha
    ' "${response}" >/dev/null
}

verify_validation_jobs() {
  local response="$1" run_id="$2" reviewed_sha="$3"

  jq --exit-status \
    --argjson run_id "${run_id}" \
    --arg reviewed_sha "${reviewed_sha}" \
    --arg validation_job "${VALIDATION_JOB}" \
    --arg api_root "${API_ROOT}" '
      (.total_count | type) == "number"
      and .total_count == 1
      and (.jobs | length) == 1
      and .jobs[0].name == $validation_job
      and .jobs[0].run_id == $run_id
      and .jobs[0].run_attempt == 1
      and .jobs[0].head_sha == $reviewed_sha
      and .jobs[0].status == "completed"
      and .jobs[0].conclusion == "success"
      and .jobs[0].run_url == ($api_root + "/repos/max5800/neolink/actions/runs/" + ($run_id | tostring))
      and ([.jobs[0].steps[] | select(.conclusion != "success")] | length) == 0
      and any(.jobs[0].steps[]; .name == "Upload durable publication binding" and .conclusion == "success")
    ' "${response}" >/dev/null
}

select_binding_artifact() {
  local response="$1" run_id="$2" reviewed_sha="$3"
  local expected_name="publication-binding-${reviewed_sha}-${run_id}-1"

  jq --exit-status --compact-output \
    --argjson run_id "${run_id}" \
    --arg expected_name "${expected_name}" \
    --arg api_root "${API_ROOT}" '
      if (.total_count | type) != "number" or .total_count > 100 then
        error("artifact result set exceeds the bounded first page")
      else . end
      | [ .artifacts[]
          | select(.name == $expected_name)
          | select(.expired == false)
          | select(.workflow_run.id == $run_id)
          | select(.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
          | select(.size_in_bytes | type == "number" and . > 0 and . <= 65536)
        ]
      | if length == 1 then .[0] else error("expected one unexpired exact-run publication binding artifact") end
      | {id, name, digest, size_in_bytes, archive_download_url}
      | select((.id | type) == "number" and .id > 0)
      | select(.archive_download_url == ($api_root + "/repos/max5800/neolink/actions/artifacts/" + (.id | tostring) + "/zip"))
    ' "${response}"
}

write_binding_document() {
  local output="$1" repository="$2" repository_id="$3" pr_number="$4"
  local head_sha="$5" head_ref="$6" head_repository="$7" head_repository_id="$8"
  local base_sha="$9" base_ref="${10}" base_repository="${11}" base_repository_id="${12}"
  local run_id="${13}" run_attempt="${14}" workflow_ref="${15}"

  jq --null-input --sort-keys \
    --arg schema 'neolink-publication-binding/v1' \
    --arg event_name 'pull_request' \
    --arg repository "${repository}" \
    --argjson repository_id "${repository_id}" \
    --argjson pull_request_number "${pr_number}" \
    --arg head_sha "${head_sha}" \
    --arg head_ref "${head_ref}" \
    --arg head_repository "${head_repository}" \
    --argjson head_repository_id "${head_repository_id}" \
    --arg base_sha "${base_sha}" \
    --arg base_ref "${base_ref}" \
    --arg base_repository "${base_repository}" \
    --argjson base_repository_id "${base_repository_id}" \
    --argjson run_id "${run_id}" \
    --argjson run_attempt "${run_attempt}" \
    --arg workflow_ref "${workflow_ref}" '
      {
        schema: $schema,
        event_name: $event_name,
        repository: $repository,
        repository_id: $repository_id,
        pull_request_number: $pull_request_number,
        head_sha: $head_sha,
        head_ref: $head_ref,
        head_repository: $head_repository,
        head_repository_id: $head_repository_id,
        base_sha: $base_sha,
        base_ref: $base_ref,
        base_repository: $base_repository,
        base_repository_id: $base_repository_id,
        run_id: $run_id,
        run_attempt: $run_attempt,
        workflow_ref: $workflow_ref
      }
    ' >"${output}"
}

verify_binding_document() {
  local binding="$1" repository="$2" repository_id="$3" pr_number="$4"
  local reviewed_sha="$5" head_ref="$6" head_repository="$7" head_repository_id="$8"
  local previous_sha="$9" run_id="${10}"
  local expected_workflow_ref="${repository}/${VALIDATION_PATH}@refs/pull/${pr_number}/merge"

  jq --exit-status \
    --arg repository "${repository}" \
    --argjson repository_id "${repository_id}" \
    --argjson pr_number "${pr_number}" \
    --arg reviewed_sha "${reviewed_sha}" \
    --arg head_ref "${head_ref}" \
    --arg head_repository "${head_repository}" \
    --argjson head_repository_id "${head_repository_id}" \
    --arg previous_sha "${previous_sha}" \
    --argjson run_id "${run_id}" \
    --arg expected_workflow_ref "${expected_workflow_ref}" '
      (keys | sort) == [
        "base_ref", "base_repository", "base_repository_id", "base_sha", "event_name",
        "head_ref", "head_repository", "head_repository_id", "head_sha", "pull_request_number",
        "repository", "repository_id", "run_attempt", "run_id", "schema", "workflow_ref"
      ]
      and .schema == "neolink-publication-binding/v1"
      and .event_name == "pull_request"
      and .repository == $repository
      and .repository_id == $repository_id
      and .pull_request_number == $pr_number
      and .head_sha == $reviewed_sha
      and .head_ref == $head_ref
      and .head_repository == $head_repository
      and .head_repository_id == $head_repository_id
      and .base_ref == "master"
      and .base_sha == $previous_sha
      and .base_repository == $repository
      and .base_repository_id == $repository_id
      and .run_id == $run_id
      and .run_attempt == 1
      and .workflow_ref == $expected_workflow_ref
    ' "${binding}" >/dev/null
}

api_get() {
  local endpoint="$1" output="$2" headers="$3" status
  status="$(curl --fail --silent --show-error --proto '=https' --tlsv1.2 --max-redirs 0 \
    --connect-timeout 15 --max-time 60 --retry 2 --retry-delay 1 \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${GITHUB_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --dump-header "${headers}" --output "${output}" --write-out '%{http_code}' \
    "${API_ROOT}${endpoint}")"
  test "${status}" = 200
}

reject_next_page() {
  local headers="$1"
  ! awk 'BEGIN { IGNORECASE=1 } /^link:/ && /rel="next"/ { found=1 } END { exit !found }' "${headers}"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

extract_binding_document() {
  local archive="$1" output="$2"
  python3 - "${archive}" "${output}" "${MAX_BINDING_ARCHIVE_BYTES}" <<'PY'
import json
import pathlib
import stat
import sys
import zipfile

archive, output, limit = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
with zipfile.ZipFile(archive) as zf:
    infos = zf.infolist()
    if len(infos) != 1 or infos[0].filename != "publication-binding.json":
        raise SystemExit("binding archive must contain exactly publication-binding.json")
    info = infos[0]
    mode = (info.external_attr >> 16) & 0o170000
    if info.is_dir() or info.flag_bits & 1 or info.file_size <= 0 or info.file_size > limit:
        raise SystemExit("binding archive entry is unsafe or outside size bounds")
    if mode not in (0, stat.S_IFREG):
        raise SystemExit("binding archive entry is not a regular file")
    data = zf.read(info)
    if len(data) != info.file_size or b"\0" in data:
        raise SystemExit("binding archive entry is malformed")
    json.loads(data)
    output.write_bytes(data)
PY
}

main() {
  : "${MERGE_SHA:?}" "${PREVIOUS_MASTER_SHA:?}" "${MERGE_HEAD_SHA:?}"
  : "${GITHUB_REPOSITORY:?}" "${GITHUB_REPOSITORY_ID:?}" "${GITHUB_TOKEN:?}" "${GITHUB_OUTPUT:?}"

  [[ "${MERGE_SHA}" =~ ^[0-9a-f]{40}$ ]]
  [[ "${PREVIOUS_MASTER_SHA}" =~ ^[0-9a-f]{40}$ ]]
  [[ "${MERGE_HEAD_SHA}" =~ ^[0-9a-f]{40}$ ]]
  [[ "${GITHUB_REPOSITORY_ID}" =~ ^[1-9][0-9]*$ ]]
  test "${GITHUB_REPOSITORY}" = "max5800/neolink"

  local temp_dir pr_response pr_headers runs_response runs_headers run_response run_headers
  local jobs_response jobs_headers artifacts_response artifacts_headers final_run_response final_run_headers
  local artifact_archive binding_file pr_record validation_record artifact_record
  local pr_number head_ref head_repository head_repository_id run_id check_suite_id
  temp_dir="$(mktemp -d)"
  publication_binding_temp_dir="${temp_dir}"
  trap cleanup_publication_binding_temp_dir EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  chmod 700 "${temp_dir}"
  pr_response="${temp_dir}/pulls.json"; pr_headers="${temp_dir}/pulls.headers"
  runs_response="${temp_dir}/runs.json"; runs_headers="${temp_dir}/runs.headers"
  run_response="${temp_dir}/run.json"; run_headers="${temp_dir}/run.headers"
  jobs_response="${temp_dir}/jobs.json"; jobs_headers="${temp_dir}/jobs.headers"
  artifacts_response="${temp_dir}/artifacts.json"; artifacts_headers="${temp_dir}/artifacts.headers"
  final_run_response="${temp_dir}/run-final.json"; final_run_headers="${temp_dir}/run-final.headers"
  artifact_archive="${temp_dir}/binding.zip"; binding_file="${temp_dir}/publication-binding.json"

  api_get "/repos/${GITHUB_REPOSITORY}/commits/${MERGE_SHA}/pulls?per_page=100&page=1" "${pr_response}" "${pr_headers}"
  reject_next_page "${pr_headers}"
  pr_record="$(select_pr_record "${pr_response}" "${GITHUB_REPOSITORY}" "${GITHUB_REPOSITORY_ID}" "${MERGE_SHA}" "${PREVIOUS_MASTER_SHA}" "${MERGE_HEAD_SHA}")"
  pr_number="$(jq --exit-status --raw-output '.number' <<<"${pr_record}")"
  head_ref="$(jq --exit-status --raw-output '.head_ref' <<<"${pr_record}")"
  head_repository="$(jq --exit-status --raw-output '.head_repository' <<<"${pr_record}")"
  head_repository_id="$(jq --exit-status --raw-output '.head_repository_id' <<<"${pr_record}")"

  api_get "/repos/${GITHUB_REPOSITORY}/actions/workflows/validate.yml/runs?head_sha=${MERGE_HEAD_SHA}&event=pull_request&status=success&per_page=100&page=1" "${runs_response}" "${runs_headers}"
  reject_next_page "${runs_headers}"
  validation_record="$(select_validation_record "${runs_response}" "${GITHUB_REPOSITORY}" "${GITHUB_REPOSITORY_ID}" "${MERGE_HEAD_SHA}" "${head_ref}" "${head_repository}" "${head_repository_id}")"
  run_id="$(jq --exit-status --raw-output '.id' <<<"${validation_record}")"
  check_suite_id="$(jq --exit-status --raw-output '.check_suite_id' <<<"${validation_record}")"

  api_get "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}" "${run_response}" "${run_headers}"
  verify_run_detail "${run_response}" "${run_id}" "${check_suite_id}" "${GITHUB_REPOSITORY}" "${GITHUB_REPOSITORY_ID}" "${MERGE_HEAD_SHA}" "${head_ref}" "${head_repository}" "${head_repository_id}"

  api_get "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/jobs?filter=latest&per_page=100&page=1" "${jobs_response}" "${jobs_headers}"
  reject_next_page "${jobs_headers}"
  verify_validation_jobs "${jobs_response}" "${run_id}" "${MERGE_HEAD_SHA}"

  api_get "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/artifacts?per_page=100&page=1" "${artifacts_response}" "${artifacts_headers}"
  reject_next_page "${artifacts_headers}"
  artifact_record="$(select_binding_artifact "${artifacts_response}" "${run_id}" "${MERGE_HEAD_SHA}")"

  local artifact_url artifact_digest artifact_size download_status actual_size actual_digest
  artifact_url="$(jq --exit-status --raw-output '.archive_download_url' <<<"${artifact_record}")"
  artifact_digest="$(jq --exit-status --raw-output '.digest' <<<"${artifact_record}")"
  artifact_size="$(jq --exit-status --raw-output '.size_in_bytes' <<<"${artifact_record}")"
  download_status="$(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --max-redirs 1 --connect-timeout 15 --max-time 60 --retry 2 --retry-delay 1 \
    --max-filesize "${MAX_BINDING_ARCHIVE_BYTES}" \
    --header 'Accept: application/vnd.github+json' \
    --header "Authorization: Bearer ${GITHUB_TOKEN}" \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "${artifact_archive}" --write-out '%{http_code}' "${artifact_url}")"
  test "${download_status}" = 200
  actual_size="$(wc -c <"${artifact_archive}" | tr -d ' ')"
  test "${actual_size}" = "${artifact_size}"
  actual_digest="$(sha256_file "${artifact_archive}")"
  test "sha256:${actual_digest}" = "${artifact_digest}"
  extract_binding_document "${artifact_archive}" "${binding_file}"
  verify_binding_document "${binding_file}" "${GITHUB_REPOSITORY}" "${GITHUB_REPOSITORY_ID}" "${pr_number}" \
    "${MERGE_HEAD_SHA}" "${head_ref}" "${head_repository}" "${head_repository_id}" "${PREVIOUS_MASTER_SHA}" "${run_id}"

  # Close the rerun race: a rerun changes run_attempt/status and invalidates the selected first-attempt evidence.
  api_get "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}" "${final_run_response}" "${final_run_headers}"
  verify_run_detail "${final_run_response}" "${run_id}" "${check_suite_id}" "${GITHUB_REPOSITORY}" "${GITHUB_REPOSITORY_ID}" "${MERGE_HEAD_SHA}" "${head_ref}" "${head_repository}" "${head_repository_id}"

  {
    printf 'pr_number=%s\n' "${pr_number}"
    printf 'pr_head_sha=%s\n' "${MERGE_HEAD_SHA}"
    printf 'validation_run_id=%s\n' "${run_id}"
    printf 'validation_run_url=https://github.com/%s/actions/runs/%s\n' "${GITHUB_REPOSITORY}" "${run_id}"
  } >>"${GITHUB_OUTPUT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
