// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

[
    // Compute cores
    % for j in range(8):
    {
        "thread": "${f'hart_{j}'}",
        // specify which perf.json region we are interested in.
        "roi": [
            {"idx": 0, "label": "start"},
            {"idx": 1, "label": "compute"},
            {"idx": 2, "label": "reduction"},
            {"idx": 3, "label": "end"},
        ]
    },
    % endfor
]