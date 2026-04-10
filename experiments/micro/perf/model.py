#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import pandas as pd
import math

SCHNIZO_XL = {
    'alu': 3,
    'lsu': 3,
    'fpu': 1
}
SCHNIZO_LA = SCHNIZO_XL
SCHNIZO_TR = {
    'alu': 2,
    'lsu': 1,  # 2 LSUs would be beneficial, but can't be used for memory consistency issues
    'fpu': 2
}
SCHNIZO_MC = {
    'alu': 3,
    'lsu': 1,
    'fpu': 2
}
SCHNIZO_CFGS = [
    ('Schnizo-LA', SCHNIZO_LA),
    ('Schnizo-TR', SCHNIZO_TR),
    ('Schnizo-MC', SCHNIZO_MC),
]

BENCHMARK_INSNS = {
    'superscalar': {
        'sz_axpy':          {'alu':  3, 'fpu':  1, 'lsu':  3},
        'sz_dot':           {'alu':  2, 'fpu':  4, 'lsu':  8},
        'exp':              {'alu': 22, 'fpu': 40, 'lsu': 28},
        'log':              {'alu': 34, 'fpu': 40, 'lsu': 16},
        'pi_lcg':           {'alu': 20, 'fpu': 28, 'lsu':  0},
        'pi_xoshiro128p':   {'alu': 84, 'fpu': 28, 'lsu':  0},
        'poly_lcg':         {'alu': 20, 'fpu': 40, 'lsu':  0},
        'poly_xoshiro128p': {'alu': 84, 'fpu': 40, 'lsu':  0},
    }
}
BENCHMARK_INSNS['scalar'] = BENCHMARK_INSNS['superscalar'].copy()
BENCHMARK_INSNS['scalar']['sz_axpy'] = {'alu':  3, 'fpu':  4, 'lsu':  12}


def insns_per_fu(insns, cfg, fu):
    return math.ceil(insns[fu] / cfg[fu])


def ideal_ipc(insns, cfg):
    """Compute ideal IPC based on instruction mix and FU counts (bottleneck analysis)."""
    total = sum(insns.values())
    cycles = max(insns_per_fu(insns, cfg, fu) for fu in cfg if insns.get(fu, 0))
    return total / cycles


def ideal_fpu_util(insns):
    return insns['fpu'] / sum(insns.values())


def theoretical_metrics(cfg=None):
    d = {
        'fpu_util': {
            'scalar': {
                app: ideal_fpu_util(BENCHMARK_INSNS['scalar'][app])
                for app in ['sz_axpy', 'sz_dot']
            }
        }
    }
    if cfg is not None:
        d['ipc'] = {
                'superscalar': {
                    app: ideal_ipc(BENCHMARK_INSNS['superscalar'][app], cfg)
                    for app in BENCHMARK_INSNS['superscalar']
                }
            }
    return d


def main():
    rows = {}

    for app, insns in BENCHMARK_INSNS['superscalar'].items():
        row = {}

        for cfg_name, cfg in SCHNIZO_CFGS:
            row[(cfg_name, 'ipc')] = ideal_ipc(insns, cfg)
            for fu in cfg:
                row[(cfg_name, fu)] = insns_per_fu(insns, cfg, fu)

        rows[app] = row

    df = pd.DataFrame.from_dict(rows, orient='index')

    # Turn tuple columns into a proper MultiIndex
    df.columns = pd.MultiIndex.from_tuples(df.columns, names=['config', 'metric'])

    # Optional: enforce metric order inside each config
    metric_order = ['alu', 'lsu', 'fpu', 'ipc']
    config_order = [name for name, _ in SCHNIZO_CFGS]
    df = df.reindex(
        columns=pd.MultiIndex.from_product(
            [config_order, metric_order],
            names=['config', 'metric']
        )
    )

    print(df)


if __name__ == '__main__':
    main()
