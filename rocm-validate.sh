#!/usr/bin/env nix-shell
#! nix-shell -i bash -p nix jq coreutils bc nix-output-monitor
# SPDX-FileCopyrightText: 2026 LunNova
# SPDX-License-Identifier: CC0-1.0

# Validates ROCm package set health for a given nixpkgs flake reference.
# Usage: ./rocm-validate.sh <flake-ref-prefix>
# Example: ./rocm-validate.sh github:nixos/nixpkgs/nixos-25.11
#          ./rocm-validate.sh /path/to/nixpkgs

set -euo pipefail

trap 'echo "Interrupted." >&2; exit 130' INT

export NIXPKGS_ALLOW_UNFREE=1

HYDRA_MAX_SIZE_BYTES=$((3 * 1024 * 1024 * 1024)) # 3 GiB
HYDRA_MAX_SIZE_HUMAN="3 GiB"

prefix="${1:?Usage: $0 <flake-ref-prefix>}"
flake_ref="$prefix"  # preserve original for --override-input

echo "INFO: Resolving $prefix to a store path..."
resolved_path=$(nix flake metadata "$prefix" --json | jq -r '.path')
if [[ -z "$resolved_path" || "$resolved_path" == "null" ]]; then
  echo "ERROR: Could not resolve flake ref '$prefix' to a path" >&2
  exit 1
fi
echo "INFO: Resolved to: $resolved_path"
prefix="$resolved_path"

rocm_drvs_ref="$prefix#rocmPackages.rocm-tests.tests.rocmPackagesDerivations"
echo "INFO: Checking if rocmPackagesDerivations test is available..."
if nix eval "$rocm_drvs_ref" --apply 'drv: drv ? outPath' 2>/dev/null | grep -q 'true'; then
  echo "INFO: Building rocmPackagesDerivations with nom (--keep-going)..."
  nom build "$rocm_drvs_ref" -j1 --keep-going --no-link || true
fi

failures=()
warnings=()

fail() {
  echo "FAIL: $1" >&2
  failures+=("$1")
}

warn() {
  echo "WARN: $1" >&2
  warnings+=("$1")
}

info() {
  echo "INFO: $1"
}

human_bytes() {
  local bytes="$1"
  if ((bytes >= 1073741824)); then
    echo "$(echo "scale=2; $bytes / 1073741824" | bc) GiB"
  elif ((bytes >= 1048576)); then
    echo "$(echo "scale=2; $bytes / 1048576" | bc) MiB"
  else
    echo "$bytes bytes"
  fi
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NIX_HELPERS='
let
  optionalsWithSuccess = toTry: next:
    let tried = builtins.tryEval toTry;
    in if tried.success then next tried.value else [];
  isAvailable = obj:
    !((obj ? meta) && (!(obj.meta.available or true) || (obj.meta.broken or false)));
  findAll = path: obj:
    optionalsWithSuccess obj (obj:
      if obj ? outPath then
        optionalsWithSuccess (obj.outPath or null) (outPath:
          if !(isAvailable obj) then [] else [{ p = path; o = outPath; }]
        )
      else if (obj.recurseForDerivations or false) then
        builtins.concatLists (builtins.attrValues (builtins.mapAttrs (name: value:
          findAll (if path == null then name else path + "." + name) value
        ) obj))
      else []
    );
  enumerateTestAttr = attr: ps:
    let
      topLevel = optionalsWithSuccess (ps ? ${attr} && builtins.isAttrs ps.${attr}) (has:
        if !has then []
        else optionalsWithSuccess (builtins.attrNames ps.${attr}) (names:
          map (t: "${attr}.${t}") names
        )
      );
      perPkg = builtins.concatMap (n:
        optionalsWithSuccess ps.${n} (pkg:
          if !(isAvailable pkg) then []
          else optionalsWithSuccess (pkg ? ${attr} && builtins.isAttrs pkg.${attr}) (has:
            if !has then []
            else optionalsWithSuccess (builtins.attrNames pkg.${attr}) (names:
              map (t: "${n}.${attr}.${t}") names
            )
          )
        )
      ) (builtins.attrNames ps);
    in topLevel ++ perPkg;
in'

enumerate_rocm_packages() {
  nix eval "$prefix#rocmPackages" --apply "ps: $NIX_HELPERS findAll null (ps // { recurseForDerivations = true; })" --json | jq -r '.[].p'
}

enumerate_rocm_packages_with_src() {
  nix eval "$prefix#rocmPackages" --apply "ps: $NIX_HELPERS
    builtins.filter (n:
      let
        hasOutPath = builtins.tryEval (ps.\${n} ? outPath);
        hasSrc = builtins.tryEval (ps.\${n} ? src);
        available = builtins.tryEval (isAvailable ps.\${n});
      in hasOutPath.success && hasOutPath.value
         && hasSrc.success && hasSrc.value
         && available.success && available.value
    ) (builtins.attrNames ps)
  " --json | jq -r '.[]'
}

enumerate_tests() {
  nix eval "$prefix#rocmPackages" --apply "ps: $NIX_HELPERS enumerateTestAttr \"tests\" ps" --json | jq -r '.[]'
}

enumerate_impure_tests() {
  nix eval "$prefix#rocmPackages" --apply "ps: $NIX_HELPERS enumerateTestAttr \"impureTests\" ps" --json | jq -r '.[]'
}

check_size() {
  local label="$1" ref="$2"
  size_bytes=$(nix path-info --size --json "$ref" 2>/dev/null | jq '[.[].narSize // empty][0] // empty') || {
    fail "$label not in store/cache (not built or not substitutable)"
    return
  }
  if [[ -z "$size_bytes" || "$size_bytes" == "null" ]]; then
    fail "$label not in store/cache (not built or not substitutable)"
    return
  fi
  if [[ "$size_bytes" -gt "$HYDRA_MAX_SIZE_BYTES" ]]; then
    fail "$label size $(human_bytes "$size_bytes") exceeds hydra limit ($HYDRA_MAX_SIZE_HUMAN)"
  else
    info "  $label OK ($(human_bytes "$size_bytes"))"
  fi
}

info "=== Phase 1: Checking .src sizes ==="

mapfile -t src_pkgs < <(enumerate_rocm_packages_with_src)
info "Found ${#src_pkgs[@]} packages with .src"

for pkg in "${src_pkgs[@]}"; do
  check_size "rocmPackages.${pkg}.src" "$prefix#rocmPackages.${pkg}.src"
done

info ""
info "=== Phase 2: Checking package sizes ==="

mapfile -t all_pkgs < <(enumerate_rocm_packages)
info "Found ${#all_pkgs[@]} packages"

for pkg in "${all_pkgs[@]}"; do
  check_size "rocmPackages.${pkg}" "$prefix#rocmPackages.${pkg}"
done

info ""
info "=== Phase 2.5: Checking package aliases ==="

rocm_torch=$(nix eval --raw "$prefix#pkgsRocm.python3Packages.torch.outPath" 2>/dev/null) || rocm_torch=""
torch_with_rocm=$(nix eval --raw "$prefix#python3Packages.torchWithRocm.outPath" 2>/dev/null) || torch_with_rocm=""

if [[ -z "$rocm_torch" ]]; then
  fail "Could not evaluate pkgsRocm.python3Packages.torch.outPath"
elif [[ -z "$torch_with_rocm" ]]; then
  fail "Could not evaluate python3Packages.torchWithRocm.outPath"
elif [[ "$rocm_torch" != "$torch_with_rocm" ]]; then
  fail "pkgsRocm.python3Packages.torch.outPath ($rocm_torch) != python3Packages.torchWithRocm.outPath ($torch_with_rocm)"
else
  info "  pkgsRocm.python3Packages.torch == python3Packages.torchWithRocm OK"
fi

info ""
info "=== Phase 3: Running .tests ==="

mapfile -t test_paths < <(enumerate_tests)
info "Found ${#test_paths[@]} test(s)"

for path in "${test_paths[@]}"; do
  ref="$prefix#rocmPackages.${path}"
  info "Building test: $ref"
  if ! nix build "$ref" --no-link; then
    fail "Test $ref failed to build"
  else
    info "  PASS: $ref"
  fi
done

info ""
info "=== Phase 4: Building and running impureTests ==="

mapfile -t impure_paths < <(enumerate_impure_tests)
info "Found ${#impure_paths[@]} impure test(s)"

for path in "${impure_paths[@]}"; do
  ref="$prefix#rocmPackages.${path}"
  info "Building impure test: $ref"
  if ! script_path=$(nix build "$ref" --no-link --print-out-paths --impure); then
    fail "Impure test $ref failed to build"
    continue
  fi
  if [[ -z "$script_path" ]]; then
    fail "Impure test $ref built but produced no output path"
    continue
  fi
  info "Running impure test: $ref"
  if ! (cd "$resolved_path" && bash "$script_path" --no-out-link); then
    fail "Impure test $ref failed to run"
  else
    info "  PASS: $ref"
  fi
done

info ""
info "=== Phase 5: ROCm inference smoke test (llama-cpp) ==="

llama_ref="$prefix#pkgsRocm.llama-cpp"
if ! llama_path=$(nix build "$llama_ref" --no-link --print-out-paths); then
  fail "Could not build $llama_ref"
elif [[ -z "$llama_path" ]]; then
  fail "$llama_ref built but produced no output path"
else
  info "Running llama-cpp inference test..."
  if ! "$llama_path/bin/llama-cli" \
    -hf ggml-org/functiongemma-270m-it-GGUF \
    -st -n 32 -p "hello" -c 2048 -fa 1 -ub 8 -b 16; then
    fail "llama-cpp ROCm inference test failed"
  else
    info "  PASS: llama-cpp inference test"
  fi
fi

info ""
info "=== Phase 6: torch-triton tests (tl.dot etc.) ==="

# Run torch-triton-tests from this repo's flake, but with the target nixpkgs
# swapped in via --override-input so tests use the nixpkgs under validation.
if ! nix run "${script_dir}#torch-triton-tests" --override-input nixpkgs "$flake_ref"; then
  fail "torch-triton-tests failed"
else
  info "  PASS: torch-triton-tests"
fi

echo ""
echo "=== SUMMARY ==="
echo "Warnings: ${#warnings[@]}"
echo "Failures: ${#failures[@]}"

if [[ ${#warnings[@]} -gt 0 ]]; then
  echo ""
  echo "Warnings:"
  for w in "${warnings[@]}"; do
    echo "  - $w"
  done
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${failures[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo ""
echo "All checks passed."
