#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# This script detects bank conflicts based on when a memory instruction is dispatched.
# However, in regular execution the dispatch happens only if the memory backend accepts the
# request. This leads to misses of actual bank conflicts. However, in LCP the dispatch happens
# immediately, so this script can be used to detect bank conflicts during LCP phases.
# One exception is in case there is only one LSU, and thus the dispatch is also delayed by one
# cycle.

import argparse
import os
import re
from collections import defaultdict

from addr_to_bank import decode_bank_offset


# find all files at files in folder which start with the prefix
def find_trace_files(folder, file_prefix, file_suffix):
    # the folder can be relative to this file or an absolute path
    if not os.path.isabs(folder):
        folder = os.path.join(os.path.dirname(__file__), folder)
    else:
        folder = os.path.abspath(folder)
    files = os.listdir(folder)
    trace_files = [f for f in files if f.startswith(file_prefix) and f.endswith('.txt')]
    # merge file name with folder path
    trace_files = [os.path.join(folder, f) for f in trace_files]
    return trace_files


# go through the trace file and extract all loads and stores
# a trace file line for a load can look like this:
# 383000     381  M REG  0x18020030 lw t0, 0(t0)      #; t0 <~~ Word[0x18021188]

# It is a load if there is "<~~" after the "#;" part.
# A store line looks similar, but has "~~>" instead of "<~~".
# We want to extract the following details:
# - The cycle number: The 2nd number in the line (e.g., 381)
# - The register where the value is loaded into (e.g., t0): The first string after the #; symbol.
# - The address that was accessed: The address is inside the [ and ] after the "<~~" or "~~>" part.
#   The word infront of [ is arbitrary.
# - The PC of the instruction: The first hex number in the line.
def extract_loads_and_stores(trace_file):
    accesses = defaultdict(list)
    with open(trace_file, 'r') as f:
        for line in f:
            match = re.search(
                (r'^\d+\s+(\d+)\s+.*\s+(0x[0-9a-fA-F]+).*#;\s+(\S+)\s+.*[<~~|~~>]\s+\S+'
                 r'\[(0x[0-9a-fA-F]+)\]'),
                line
            )
            if match:
                cycle = int(match.group(1))
                pc = match.group(2)
                reg = match.group(3)
                address = match.group(4)

                if '<~~' in line:
                    type = 'load'
                elif '~~>' in line:
                    type = 'store'
                accesses[cycle].append({
                        'pc': pc,
                        'reg': reg,
                        'address': address,
                        'type': type
                    })
    return accesses


def find_all_accesses(trace_files, trace_file_prefix, num_banks, base_address, bank_width_bits):
    # for each bank create a defaultdict
    all_accesses = defaultdict(lambda: defaultdict(list))

    for trace_file in trace_files:
        # extract the core id from the trace file name. The id is the number after the prefix
        # The prefix is given by trace_file_name_start. Extract it with regex.
        core_id_match = re.search(rf'{trace_file_prefix}(\d+).*', trace_file)
        if not core_id_match:
            print(f"Could not extract core id from trace file name: {trace_file}")
            continue
        core_id = int(core_id_match.group(1))
        # extrac all loads and stores from the trace file
        accesses = extract_loads_and_stores(trace_file)

        # for each access, decode the bank index and offset
        for cycle, details in accesses.items():
            for detail in details:
                address = int(detail['address'], 16)
                bank_index, offset, offset_in_bank = decode_bank_offset(
                    address=address,
                    base_address=base_address,
                    num_banks=num_banks,
                    bank_width_bits=bank_width_bits
                )
                # add the access to the all_accesses dict
                all_accesses[bank_index][cycle].append({
                    'core_id': core_id,
                    'address': detail['address'],  # keep string formatted hex
                    'bank_offset': offset,
                    'offset_in_bank': offset_in_bank,
                    'pc': detail['pc'],
                    'reg': detail['reg'],
                    'type': detail['type']
                })
    return all_accesses


def find_conflicts(trace_files, trace_file_prefix, num_banks, base_address, bank_width_bits):
    all_accesses = find_all_accesses(trace_files, trace_file_prefix, num_banks, base_address,
                                     bank_width_bits)

    # extract all banks which have more than one access at the same cycle
    all_conflicts = defaultdict(lambda: defaultdict(list))
    for bank_index, accesses in all_accesses.items():
        for cycle, details in accesses.items():
            if len(details) > 1:
                for detail in details:
                    all_conflicts[bank_index][cycle].append(detail)
    # sort the conflicts by banks
    all_conflicts = dict(sorted(all_conflicts.items()))
    # sort the cycles in each bank
    for bank_id, cycles in all_conflicts.items():
        all_conflicts[bank_id] = dict(sorted(cycles.items()))

    return all_conflicts


def print_conflicts(all_conflicts):
    if not all_conflicts:
        print("No conflicts found.")
        return

    for bank_id, bank_conflicts in all_conflicts.items():
        print(f"Bank {bank_id} has {len(bank_conflicts)} conflicts:")
        for cycle, conflicts in bank_conflicts.items():
            print(f"  Bank {bank_id}, Cycle {cycle}:")
            for detail in conflicts:
                print(f"    Core {detail['core_id']} accessed address {detail['address']} at PC "
                      f"{detail['pc']} ({detail['type']})")
        print("---------------------")


def generate_conflicts_report(all_conflicts):
    report = []
    if not all_conflicts:
        report.append("No conflicts found.")
        return "\n".join(report)

    for bank_id, bank_conflicts in all_conflicts.items():
        report.append(f"Bank {bank_id} has {len(bank_conflicts)} conflicts:")
        for cycle, conflicts in bank_conflicts.items():
            report.append(f"  Bank {bank_id}, Cycle {cycle}:")
            for detail in conflicts:
                report.append(f"    Core {detail['core_id']} accessed address {detail['address']} "
                              f"at PC {detail['pc']} ({detail['type']})")
        report.append("---------------------")
    report.append("\n")
    return "\n".join(report)


def main():
    """Parses command-line arguments and prints any bank conflicts."""
    parser = argparse.ArgumentParser(
        description="Scan traces and report bank conflicts per bank."
    )

    parser.add_argument(
        "--num_banks",
        type=int,
        default=32,
        help="Total number of memory banks (default: 32)."
    )
    parser.add_argument(
        "--base_address",
        type=lambda x: int(x, 0),
        default=0x10000000,
        help="Base address of the banked memory (default: 0x1000000)."
    )
    parser.add_argument(
        "--bank_width",
        type=int,
        default=64,
        help="Bank width in bits (default: 64). Must be a multiple of 8."
    )
    parser.add_argument(
        "--traces_file_path",
        type=str,
        default="../target/snitch_cluster/logs/",
        help="Path to the trace files (default: '../target/snitch_cluster/logs/')."
    )
    parser.add_argument(
        "--trace_file_prefix",
        type=str,
        default="sz_trace_hart_",
        help="Prefix of the trace files before the hard id starts (default: 'sz_trace_hart_')."
    )
    parser.add_argument(
        "--trace_file_suffix",
        type=str,
        default=".txt",
        help="Suffix of the trace files (default: '.txt')."
    )
    parser.add_argument(
        "--print_conflicts",
        action='store_true',
        default=False,
        help="Print conflicts to stdout."
    )
    # Add argument to specify the output file for the report
    parser.add_argument(
        "--report",
        type=str,
        default=None,
        help="File to save the conflicts report. If not specified, report will be printed to "
             "stdout."
    )

    args = parser.parse_args()

    if args.bank_width % 8 != 0:
        raise ValueError("Bank width must be a multiple of 8 (to align with byte addressing).")

    trace_files = find_trace_files(args.traces_file_path, args.trace_file_prefix,
                                   args.trace_file_suffix)

    if not trace_files:
        print("No trace files found. Please check the path and prefix.")
        return

    print(f"Found {len(trace_files)} trace files in {args.traces_file_path} with prefix "
          f"'{args.trace_file_prefix}'.")

    all_conflicts = find_conflicts(trace_files, args.trace_file_prefix, args.num_banks,
                                   args.base_address, args.bank_width)

    report = generate_conflicts_report(all_conflicts)

    if args.print_conflicts or (args.report is None):
        print(report)

    if args.report:
        with open(args.report, 'w') as report_file:
            report_file.write(report)


if __name__ == "__main__":
    main()
