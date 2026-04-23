#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Author: Stefan Odermatt <soderma@student.ethz.ch>


import os
import glob
import re
import sys


def parse_metrics(files):
    metrics = {
        "ALU": [],
        "LSU": [],
        "FPU": [],
        "ROB": [],
        "GPR": [],
        "FPR": [],
    }

    pattern_indexed = re.compile(r"(ALU|LSU|FPU)(\d+)\s+value=(\d+)")
    pattern_scalar = re.compile(r"(ROB|GPR|FPR)\s+value=(\d+)")

    for fname in files:
        with open(fname, "r") as f:
            for line in f:
                line = line.strip()

                m = pattern_indexed.match(line)
                if m:
                    typ = m.group(1)
                    val = int(m.group(3))
                    metrics[typ].append(val)
                    continue

                m = pattern_scalar.match(line)
                if m:
                    typ = m.group(1)
                    val = int(m.group(2))
                    metrics[typ].append(val)
                    continue

    return metrics


def compute_summary(metrics):
    summary = {}
    for typ, values in metrics.items():
        if values:
            summary[typ] = {
                "min": min(values),
                "max": max(values)
            }
        else:
            summary[typ] = {
                "min": None,
                "max": None
            }
    return summary


def write_summary(summary, output_path):
    with open(output_path, "w") as f:
        for typ in ["ALU", "LSU", "FPU", "ROB", "GPR", "FPR"]:
            min_val = summary[typ]["min"]
            max_val = summary[typ]["max"]
            f.write(f"{typ}: min={min_val} max={max_val}\n")


def main():
    if len(sys.argv) != 2:
        print("Usage: python script.py <path_to_metrics_folder>")
        sys.exit(1)

    input_dir = sys.argv[1]

    if not os.path.isdir(input_dir):
        print(f"Error: '{input_dir}' is not a valid directory")
        sys.exit(1)

    pattern = os.path.join(input_dir, "alloc_metrics_hart_*.txt")
    files = sorted(glob.glob(pattern))

    if not files:
        print("No matching metric files found.")
        sys.exit(1)

    metrics = parse_metrics(files)
    summary = compute_summary(metrics)

    output_file = os.path.join(input_dir, "alloc_metrics_summary.txt")
    write_summary(summary, output_file)


if __name__ == "__main__":
    main()
