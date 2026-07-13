#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import json
import math
import pandas as pd
from pathlib import Path

csv = Path(__file__).parent / "registry_global.csv"

KERNELS = [
    "relu",
    "gelu",
    "silu",
    "layernorm",
    "batchnorm",
    "rms_norm",
    "add",
    "mul",
    "neg",
    "div",
    "softmax",
]

KERNEL_TO_OPS = {
    "relu":      ["aten::relu", "aten::relu_"],
    "gelu":      ["aten::gelu", "newgeluactivation_prof"],
    "silu":      ["aten::silu"],
    "layernorm": ["aten::layer_norm"],
    "batchnorm": ["aten::batch_norm", "frozenbatchnorm2d_prof", "detrfrozenbatchnorm2d_prof"],
    "rms_norm":  ["llamarmsnorm_prof"],
    "add":       ["aten::add", "aten::add_"],
    "mul":       ["aten::mul", "aten::mul_"],
    "neg":       ["aten::neg", "aten::neg_"],
    "div":       ["aten::div", "aten::div_"],
    "softmax":   ["aten::softmax"],
}

BINARY_KERNELS = {"add", "mul", "div"}

ELTWISE_OP = {
    "add": "ELTWISE_ADD",
    "mul": "ELTWISE_MUL",
    "neg": "ELTWISE_NEG",
    "div": "ELTWISE_DIV",
}


TCDM_HEAP = 112 * 1024  # bytes
DTYPE_BYTES = 4         # FP32
ALIGN = 4               # elements (FREP 4× unroll)


def _align_down(n):
    return (n // ALIGN) * ALIGN


def _dims(tensor):
    return [d if d != 0 else 1 for d in tensor]


def shape_to_params(shape_str, kernel):
    tensors = json.loads(shape_str)
    t0 = tensors[0] if tensors else []
    if not t0 or all(x == 0 for x in t0):
        return None
    d = _dims(t0)

    if kernel in ("relu", "gelu", "silu"):
        return {"size": math.prod(d)}

    if kernel in ELTWISE_OP:
        if kernel in BINARY_KERNELS:
            t1 = tensors[1] if len(tensors) > 1 else []
            if not t1 or t1 != t0:
                return None
        return {"size": math.prod(d), "op": ELTWISE_OP[kernel]}

    if kernel == "layernorm":
        # last dim is always the normalization axis (embeddings)
        return {"input_dim": {
            "batch_size":  d[0],
            "seq_len":     math.prod(d[1:-1]),
            "embeddings":  d[-1],
        }}

    if kernel == "batchnorm":
        # NCHW — no batch field in kernel struct, fold batch into CI
        if len(d) != 4:
            return None
        return {"CI": d[0] * d[1], "IH": d[2], "IW": d[3]}

    if kernel == "softmax":
        # softmax always reduces along the last axis
        if len(d) == 2:
            return {"input_dim": {
                "batch_size":    d[0],
                "seq_len":       1,
                "input_samples": d[1],
            }, "reduce_dim": -1}
        if len(d) == 3:
            return {"input_dim": {
                "batch_size":    d[0],
                "seq_len":       d[1],
                "input_samples": d[2],
            }, "reduce_dim": -1}
        if len(d) == 4:
            return {"input_dim": {
                "batch_size":    d[0] * d[1],
                "seq_len":       d[2],
                "input_samples": d[3],
            }, "reduce_dim": -1}
        return None

    if kernel == "rms_norm":
        if len(d) != 3:
            return None
        return {"input_dim": {
            "batch_size": d[0],
            "seq_len":    d[1],
            "hidden_dim": d[2],
        }}

    return None


def clamp_params(params, kernel):
    """Return (clamped_params, scale) where scale = original_elements / clamped_elements."""

    if kernel in ("relu", "gelu", "silu"):
        max_size = _align_down(TCDM_HEAP // (2 * DTYPE_BYTES))
        orig = params["size"]
        size = _align_down(min(orig, max_size))
        return {**params, "size": size}, orig / size

    if kernel in ELTWISE_OP:
        n_tensors = 3  # datagen always allocates ifmap0, ifmap1, ofmap
        max_size = _align_down(TCDM_HEAP // (n_tensors * DTYPE_BYTES))
        orig = params["size"]
        size = _align_down(min(orig, max_size))
        return {**params, "size": size}, orig / size

    if kernel == "layernorm":
        d = params["input_dim"]
        orig_rows = d["batch_size"] * d["seq_len"]
        emb = d["embeddings"]
        max_emb = _align_down(TCDM_HEAP // (2 * DTYPE_BYTES))
        emb = min(emb, max_emb)
        emb = _align_down(emb)
        scale = orig_rows * d["embeddings"] / emb
        return {"input_dim": {"batch_size": 1, "seq_len": 1, "embeddings": emb}}, scale

    if kernel == "rms_norm":
        d = params["input_dim"]
        orig_rows = d["batch_size"] * d["seq_len"]
        hidden = d["hidden_dim"]
        # footprint: (2 * hidden + hidden) * DTYPE_BYTES = 3 * hidden * DTYPE_BYTES
        max_hidden = _align_down(TCDM_HEAP // (3 * DTYPE_BYTES))
        hidden = min(hidden, max_hidden)
        hidden = _align_down(hidden)
        scale = orig_rows * d["hidden_dim"] / hidden
        return {"input_dim": {"batch_size": 1, "seq_len": 1, "hidden_dim": hidden}}, scale

    if kernel == "softmax":
        d = params["input_dim"]
        orig_rows = d["batch_size"] * d["seq_len"]
        samples = d["input_samples"]
        max_samples = _align_down(TCDM_HEAP // (2 * DTYPE_BYTES))
        samples = min(samples, max_samples)
        samples = _align_down(samples)
        scale = orig_rows * d["input_samples"] / samples
        return {"input_dim": {"batch_size": 1, "seq_len": 1, "input_samples": samples},
                "reduce_dim": params["reduce_dim"]}, scale

    if kernel == "batchnorm":
        CI, IH, IW = params["CI"], params["IH"], params["IW"]
        gamma_beta_bytes = 2 * 1 * DTYPE_BYTES  # CI=1 after clamping
        max_IH = _align_down((TCDM_HEAP - gamma_beta_bytes) // (2 * IW * DTYPE_BYTES))
        clamped_IH = max(ALIGN, min(IH, max_IH))
        clamped_IH = _align_down(clamped_IH)
        scale = CI * IH / clamped_IH
        return {"CI": 1, "IH": clamped_IH, "IW": IW}, scale

    return params, 1.0


def cmd_operators(args):
    df = pd.read_csv(csv)
    ops = sorted(df["op_name"].unique())
    for op in ops:
        print(op)
    print(f"\n{len(ops)} unique operators")


def _print_sizes_for_kernel(kernel, df):
    op_names = KERNEL_TO_OPS[kernel]
    for shape_str in df.loc[df["op_name"].isin(op_names), "shape"]:
        params = shape_to_params(shape_str, kernel)
        if params is None:
            continue
        clamped, scale = clamp_params(params, kernel)
        out = {"params": clamped, "scale": round(scale, 4)}
        print(f"{shape_str} -> {json.dumps(out)}")


def cmd_sizes(args):
    df = pd.read_csv(csv)
    kernels = [args.kernel] if args.kernel else KERNELS
    for kernel in kernels:
        if not args.kernel:
            print(f"\n### {kernel}")
        _print_sizes_for_kernel(kernel, df)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("operators")

    p_sizes = sub.add_parser("sizes")
    p_sizes.add_argument("kernel", choices=KERNELS, nargs="?", default=None)

    args = parser.parse_args()
    if args.command == "operators":
        cmd_operators(args)
    elif args.command == "sizes":
        cmd_sizes(args)


if __name__ == "__main__":
    main()
