// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

[
    // Compute cores
    % for j in range(8):
    {
        "thread": "${f'hart_{j}'}",
        // specify which perf.json region we are interested in.
        // For AXPY the perf regions are:
        // 0: from startup to start of main
        // 1: from main to axpy_job()
        // 2: 1st tile
        // 3: setup of next tile
        // 4: 2nd tile
        // etc..
        // After the last tile there are again 2 sections
        "roi": [
            // The common start
            {"idx": 1, "label": "start"},
        % for i in range(experiment['n_tiles']):
            {"idx": ${2 * i + 2}, "label": "${f'tile_{i}'}"},
        % endfor
            // The common end
            {"idx": ${2 + experiment['n_tiles'] * 2}, "label": "end"},
        ]
    },
    % endfor
]