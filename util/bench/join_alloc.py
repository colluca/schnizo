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


def extract_hart_id(filename):
    """
    Extract hart ID from filename like:
    alloc_metrics_hart_00003.txt
    """
    match = re.search(r"alloc_metrics_hart_(\d+)\.txt$", os.path.basename(filename))
    if match:
        return int(match.group(1))
    return -1


def parse_metrics(files):
    """
    For each file:
        compute max usage per type

    Across files:
        store those maxima

    Final summary:
        min/max across per-file maxima
    """
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
        # max values for THIS file only
        file_max = {
            "ALU": 0,
            "LSU": 0,
            "FPU": 0,
            "ROB": 0,
            "GPR": 0,
            "FPR": 0,
        }

        with open(fname, "r") as f:
            for line in f:
                line = line.strip()

                m = pattern_indexed.match(line)
                if m:
                    typ = m.group(1)
                    val = int(m.group(3))
                    file_max[typ] = max(file_max[typ], val)
                    continue

                m = pattern_scalar.match(line)
                if m:
                    typ = m.group(1)
                    val = int(m.group(2))
                    file_max[typ] = max(file_max[typ], val)
                    continue

        # append only the per-file maxima
        for typ in metrics:
            metrics[typ].append(file_max[typ])

    return metrics


def compute_summary(metrics):
    summary = {}

    for typ, values in metrics.items():
        if values:
            summary[typ] = {
                "min": min(values),
                "max": max(values),
            }
        else:
            summary[typ] = {
                "min": None,
                "max": None,
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
    files = glob.glob(pattern)

    if not files:
        print("No matching metric files found.")
        sys.exit(1)

    # Sort by hart ID
    files = sorted(files, key=extract_hart_id)
    # Drop last file (DMA core)
    files.pop()

    if not files:
        print("No compute core files left after removing DMA core.")
        sys.exit(1)

    metrics = parse_metrics(files)
    summary = compute_summary(metrics)

    output_file = os.path.join(input_dir, "alloc_metrics_summary.txt")
    write_summary(summary, output_file)

    print(f"Summary written to: {output_file}")


if __name__ == "__main__":
    main()
