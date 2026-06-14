#!/usr/bin/env python3
import argparse
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

KERNEL_TO_OP = {
    "relu":      "aten::relu",
    "gelu":      "aten::gelu",
    "silu":      "aten::silu",
    "layernorm": "aten::layer_norm",
    "batchnorm": "aten::batch_norm",
    "rms_norm":  "llamarmsnorm_prof",
    "add":       "aten::add",
    "mul":       "aten::mul",
    "neg":       "aten::neg",
    "div":       "aten::div",
    "softmax":   "aten::softmax",
}


def cmd_operators(args):
    df = pd.read_csv(csv)
    ops = sorted(df["op_name"].unique())
    for op in ops:
        print(op)
    print(f"\n{len(ops)} unique operators")


def cmd_sizes(args):
    op_name = KERNEL_TO_OP[args.kernel]
    df = pd.read_csv(csv)
    sizes = df.loc[df["op_name"] == op_name, "shape"].tolist()
    for s in sizes:
        print(s)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("operators")

    p_sizes = sub.add_parser("sizes")
    p_sizes.add_argument("kernel", choices=KERNELS)

    args = parser.parse_args()
    if args.command == "operators":
        cmd_operators(args)
    elif args.command == "sizes":
        cmd_sizes(args)


if __name__ == "__main__":
    main()
