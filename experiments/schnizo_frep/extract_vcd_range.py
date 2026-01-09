#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import json5

base_name = '/sz_gemm/'
base_name = "absolute_path_to/sz_gemm"

# m,n,k
# ranges = defaultdict(defaultdict(defaultdict))

region_name = "compute"

for m in reversed([8, 16, 32]):
    for n in reversed([8, 16, 32]):
        for k in [16, 32, 64, 128]:
            # read the roi file
            # e.g. /sz_gemm/8/8/8/logs/roi.json
            roi_file = base_name + f'/{m}/{n}/{k}/logs/roi.json'
            with open(roi_file, 'r') as f:
                roi = json5.load(f)
            hart_0 = roi['hart_0']
            # find the region
            region = None
            # print(hart_0)
            for reg in hart_0:
                if reg['label'] == region_name:
                    # print(f"Found region: {reg['label']}")
                    region = reg
                    break
            # find the start and end time of the roi region
            start = region['tstart']
            end = region['tend']
            # ranges[m][n][k] = (start, end)

            print(f"m: {m}, n: {n}, k: {k} -> \'vcd_start\': {start}, \'vcd_end\': {end}")
