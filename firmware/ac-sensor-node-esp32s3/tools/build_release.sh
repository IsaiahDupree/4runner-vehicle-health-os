#!/usr/bin/env bash
set -euo pipefail

release="${1:-v0.1.0-dev.1}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
target_dir="${repo_root}/firmware/ac-sensor-node-esp32s3"
build_dir="${target_dir}/build-release"
output_dir="${build_dir}/release"
merged_name="vhos-ac-sensor-node-esp32s3-${release}-merged.bin"

cd "${repo_root}"
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "release build requires a clean source worktree" >&2
  exit 1
fi

idf.py -C "${target_dir}" -B "${build_dir}" reconfigure
idf.py -C "${target_dir}" -B "${build_dir}" build
mkdir -p "${output_dir}"
idf.py -C "${target_dir}" -B "${build_dir}" merge-bin \
  --format raw \
  -o "${output_dir}/${merged_name}"

python3 "${target_dir}/tools/validate_release.py" \
  --release "${release}" \
  --repo-root "${repo_root}" \
  --target-dir "${target_dir}" \
  --build-dir "${build_dir}" \
  --output-dir "${output_dir}" \
  --merged "${output_dir}/${merged_name}"
