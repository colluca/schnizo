## Copyright 2026 ETH Zurich and University of Bologna.
## Licensed under the Apache License, Version 2.0, see LICENSE for details.
## SPDX-License-Identifier: Apache-2.0

{
    "input_dim": {"batch_size": 1, "seq_len": 1, "hidden_dim": ${experiment['data_cfg']['size']}},
    "eps": 1e-5,
    "n_tiles": 1,
    "funcptr": "rms_norm_fp32_schnizo"
}
