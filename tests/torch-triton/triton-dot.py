#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LunNova
# SPDX-License-Identifier: CC0-1.0

"""
Triton tl.dot verification against numpy matmul.

Exit codes:
  0 = PASS  - tl.dot results match numpy
  1 = FAIL  - ISA should support tl.dot but doesn't, or results are wrong
  2 = N/A   - triton doesn't support this ISA / deps missing / no GPU
"""

import sys

try:
    import numpy as np
    import torch
except ImportError as e:
    print(f"N/A: missing dependency: {e}")
    sys.exit(2)

if not torch.cuda.is_available():
    print("N/A: no GPU available (torch.cuda.is_available() is False)")
    sys.exit(2)

try:
    import triton
    import triton.language as tl
except ImportError as e:
    print(f"N/A: triton not available: {e}")
    sys.exit(2)

props = torch.cuda.get_device_properties(0)
gpu_name = torch.cuda.get_device_name(0)
gpu_arch = getattr(props, "gcnArchName", "unknown")
print(f"INFO: GPU: {gpu_name} (arch: {gpu_arch})")

np.random.seed(42)

PASS, FAIL, NA = None, "fail", "na"


@triton.jit
def dot_kernel(
    a_ptr,
    b_ptr,
    c_ptr,
    M,
    N,
    K,
    stride_am,
    stride_ak,
    stride_bk,
    stride_bn,
    stride_cm,
    stride_cn,
    BLOCK_M: tl.constexpr,
    BLOCK_N: tl.constexpr,
    BLOCK_K: tl.constexpr,
):
    pid_m = tl.program_id(0)
    pid_n = tl.program_id(1)

    offs_m = pid_m * BLOCK_M + tl.arange(0, BLOCK_M)
    offs_n = pid_n * BLOCK_N + tl.arange(0, BLOCK_N)
    offs_k = tl.arange(0, BLOCK_K)

    a_ptrs = a_ptr + offs_m[:, None] * stride_am + offs_k[None, :] * stride_ak
    b_ptrs = b_ptr + offs_k[:, None] * stride_bk + offs_n[None, :] * stride_bn

    acc = tl.zeros((BLOCK_M, BLOCK_N), dtype=tl.float32)

    for k in range(0, K, BLOCK_K):
        a = tl.load(
            a_ptrs, mask=(offs_m[:, None] < M) & (offs_k[None, :] + k < K), other=0.0
        )
        b = tl.load(
            b_ptrs, mask=(offs_k[:, None] + k < K) & (offs_n[None, :] < N), other=0.0
        )
        acc += tl.dot(a, b)
        a_ptrs += BLOCK_K * stride_ak
        b_ptrs += BLOCK_K * stride_bk

    c_ptrs = c_ptr + offs_m[:, None] * stride_cm + offs_n[None, :] * stride_cn
    c_mask = (offs_m[:, None] < M) & (offs_n[None, :] < N)
    tl.store(c_ptrs, acc, mask=c_mask)


def run_test(M, N, K, BLOCK_M, BLOCK_N, BLOCK_K):
    assert M % BLOCK_M == 0 and N % BLOCK_N == 0 and K % BLOCK_K == 0, (
        f"dimensions must be multiples of block sizes: {M}x{N}x{K} vs {BLOCK_M}x{BLOCK_N}x{BLOCK_K}"
    )

    a_np = np.random.randn(M, K).astype(np.float32)
    b_np = np.random.randn(K, N).astype(np.float32)
    expected = a_np @ b_np

    a = torch.from_numpy(a_np).cuda()
    b = torch.from_numpy(b_np).cuda()
    c = torch.empty((M, N), device="cuda", dtype=torch.float32)

    grid = (M // BLOCK_M, N // BLOCK_N)

    try:
        dot_kernel[grid](
            a,
            b,
            c,
            M,
            N,
            K,
            a.stride(0),
            a.stride(1),
            b.stride(0),
            b.stride(1),
            c.stride(0),
            c.stride(1),
            BLOCK_M=BLOCK_M,
            BLOCK_N=BLOCK_N,
            BLOCK_K=BLOCK_K,
        )
        torch.cuda.synchronize()
    except triton.CompilationError as e:
        print(f"FAIL: tl.dot compilation failed on {gpu_arch}: {e}")
        return FAIL
    except RuntimeError as e:
        msg = str(e).lower()
        if any(
            w in msg
            for w in (
                "unsupported",
                "not supported",
                "invalid target",
                "unknown target",
            )
        ):
            print(f"N/A: GPU arch {gpu_arch} not supported by triton: {e}")
            return NA
        print(f"FAIL: runtime error during tl.dot on {gpu_arch}: {e}")
        return FAIL

    result = c.cpu().numpy()
    if np.allclose(result, expected, rtol=1e-2, atol=1e-3):
        return PASS

    max_diff = float(np.max(np.abs(result - expected)))
    mean_diff = float(np.mean(np.abs(result - expected)))
    print(
        f"FAIL: tl.dot {M}x{N}x{K} results don't match numpy "
        f"(max diff: {max_diff:.6f}, mean diff: {mean_diff:.6f})"
    )
    return FAIL


test_configs = [
    (64, 64, 64, 64, 64, 64),  # single tile
    (128, 128, 64, 64, 64, 64),  # 2x2 tiles, smaller K
    (128, 128, 128, 64, 64, 64),  # 2x2 tiles, multi-K
]

any_fail = False
all_na = True
for M, N, K, BM, BN, BK in test_configs:
    label = f"{M}x{N}x{K} (blocks {BM}x{BN}x{BK})"
    print(f"INFO: Testing tl.dot {label}...")
    result = run_test(M, N, K, BM, BN, BK)
    if result is PASS:
        print(f"  PASS: {label}")
        all_na = False
    elif result is NA:
        print(f"  N/A: {label}")
    else:
        print(f"  FAIL: {label}")
        any_fail = True
        all_na = False

if all_na:
    print("N/A: all tl.dot tests skipped")
    sys.exit(2)
elif any_fail:
    sys.exit(1)
else:
    print("PASS: all tl.dot tests match numpy")
    sys.exit(0)
