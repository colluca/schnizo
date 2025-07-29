// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

[
    // Offset for 2nd run (after preheating)
    <% offset = 2 + experiment['n_tiles'] * 2 %>

    // Compute cores
    % for j in range(8):
    {
        "thread": "${f'hart_{j}'}",
        // specify which perf.json region we are interested in.
        // For AXPY the perf regions are:
        // 0: from startup to axpy_job()
        // 1: from axpy_job entry to 1st frep loop
        // 2: 1st tile
        // 3: setup of next tile
        // 4: 2nd tile
        // ...
        // 5: from end of last tile to exit of axpy_job
        // 6: preheat loop and again axpy_job entry
        // 7: from axpy_job entry to 1st frep loop
        // 8: 1st tile
        // 9: setup of next tile
        // 10: 2nd tile
        // ...
        // 11: from end of last tile to exit of axpy_job
        // 12: from axpy_job exit to end
        "roi": [
            // The common start
            {"idx": 1, "label": "preheat_start"},
        % for i in range(experiment['n_tiles']):
            {"idx": ${2 * i + 2}, "label": "${f'preheat_tile_{i}'}"},
        % endfor
            // The common after the barrier
            {"idx": ${2 + experiment['n_tiles'] * 2}, "label": "preheat_loop"},
            // 2nd iteration
            {"idx": ${offset + 1}, "label": "start"},
        % for i in range(experiment['n_tiles']):
            {"idx": ${2 * i + offset + 2}, "label": "${f'tile_{i}'}"},
        % endfor
            // The common after the barrier
            {"idx": ${2 * experiment['n_tiles'] + offset + 2}, "label": "end"},
        ]
    },
    % endfor
]