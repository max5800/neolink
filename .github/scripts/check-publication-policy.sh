#!/usr/bin/env bash
set -euo pipefail

workflow=".github/workflows/publish-ghcr.yml"
dockerfile="Dockerfile"
readme="README.md"

test -f "${workflow}"
test -f "${dockerfile}"
test -f "${readme}"

grep -Fqx '  push:' "${workflow}"
grep -Fqx '    branches: [master]' "${workflow}"
! grep -Fq 'pull_request_target:' "${workflow}"
! grep -Fq 'workflow_dispatch:' "${workflow}"

grep -Fq 'test "${#parents[@]}" -eq 2' "${workflow}"
grep -Fq 'test "${parents[0]}" = "${PREVIOUS_MASTER_SHA}"' "${workflow}"
grep -Fq 'select(.head.sha == $head_sha)' "${workflow}"
grep -Fq 'actions/workflows/validate.yml/runs?head_sha=' "${workflow}"
grep -Fq 'select(.conclusion == "success")' "${workflow}"
grep -Fq 'select(.name == "validate-linux-amd64")' "${workflow}"
grep -Fq 'ref: ${{ steps.trust.outputs.pr_head_sha }}' "${workflow}"

grep -Fq -- '--request HEAD' "${workflow}"
grep -Fq 'Refusing to overwrite existing GHCR tag' "${workflow}"
grep -Fq -- '--request PATCH' "${workflow}"
grep -Fq -- '--data '"'"'{"visibility":"private"}'"'"'' "${workflow}"
grep -Fq '.visibility == "private"' "${workflow}"
grep -Fq 'tag_digest="$(read_manifest_digest "${TAG_SUFFIX}"' "${workflow}"
grep -Fq 'digest_reference_digest="$(read_manifest_digest "${DIGEST}"' "${workflow}"

grep -Fq 'COPY LICENSE /usr/share/licenses/neolink/LICENSE' "${dockerfile}"
grep -Fq '> /usr/share/doc/neolink/SOURCE_OFFER' "${dockerfile}"
grep -Fq 'SOURCE_SHA=${{ steps.trust.outputs.pr_head_sha }}' "${workflow}"
grep -Fq 'test -s /usr/share/licenses/neolink/LICENSE' "${workflow}"
grep -Fq 'test -s /usr/share/doc/neolink/SOURCE_OFFER' "${workflow}"
grep -Fq '/usr/share/licenses/neolink/LICENSE' "${readme}"
grep -Fq '/usr/share/doc/neolink/SOURCE_OFFER' "${readme}"
