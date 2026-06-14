#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import json5
from pathlib import Path

from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from snitch.util.experiments.SimResults import SimRegion

DATA_DIR = Path(__file__).parent / 'data'

HW = '3x32_3x32_1x64'

VARIANTS = ['zol', 'superscalar']
# VARIANTS = ['naive', 'baseline', 'zol', 'superscalar']

# Maps variant name to the C kernel function suffix (funcptr name).
KERNEL = {
    'naive':       'naive',
    'baseline':    'baseline',
    'zol':         'schnizo',
    'superscalar': 'schnizo',
}

# ELTWISE_OPS = ['ELTWISE_ADD']
ELTWISE_OPS = ['ELTWISE_ADD', 'ELTWISE_MUL', 'ELTWISE_DIV', 'ELTWISE_NEG']

# APPS = ['gelu']
APPS = ['eltwise', 'relu', 'layernorm', 'batchnorm', 'rms_norm', 'softmax', 'silu', 'gelu']


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        app = experiment['op'].lower() if experiment['app'] == 'eltwise' else experiment['app']
        return {'app': app, 'hw': experiment['hw'], 'variant': experiment['variant']}

    def derive_hw_cfg(self, experiment):
        return Path(__file__).parent / f"cfg/{experiment['hw']}.json"

    def derive_data_cfg(self, experiment):
        app = experiment['app']
        default_cfg = MK_DIR / f"sw/kernels/dnn/{app}/data/params.json"
        with open(default_cfg) as f:
            default_params = json5.loads(f.read())
        prefix = '_'.join(default_params['funcptr'].split('_')[:-1])
        overrides = {'funcptr': f"{prefix}_{experiment['kernel']}"}
        if app == 'eltwise':
            overrides['op'] = experiment['op']
        return eu.derive_data_cfg_from_overrides(
            experiment, default_cfg, overrides, root_cfg_dir=DATA_DIR)

    def derive_cdefines(self, experiment):
        if experiment['variant'] == 'zol':
            return {'FORCE_HW_LOOP': 1}
        return {}

    def derive_env(self, experiment):
        env = super().derive_env(experiment)
        env['SN_HW_FDIV'] = '1'
        return env


def gen_experiments():
    sim_bin = str(Path.cwd() / f"hw/{HW}/bin/snitch_cluster.vsim")
    experiments = []

    for variant in VARIANTS:
        for app in APPS:
            if app == 'eltwise':
                for op in ELTWISE_OPS:
                    experiments.append({
                        'app': app,
                        'hw': HW,
                        'variant': variant,
                        'kernel': KERNEL[variant],
                        'op': op,
                        'cmd': [str(MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"),
                                sim_bin, "${elf}"],
                    })
            else:
                verify = MK_DIR / f"sw/kernels/dnn/{app}/scripts/verify.py"
                cmd = [str(verify), sim_bin, "${elf}"] if verify.exists() else [sim_bin, "${elf}"]
                experiments.append({
                    'app': app,
                    'hw': HW,
                    'variant': variant,
                    'kernel': KERNEL[variant],
                    'cmd': cmd,
                })

    return experiments


def results(dir=None):
    if dir is None:
        dir = Path(__file__).parent
    df = ExperimentManager(gen_experiments(), dir=dir, parse_args=False).get_results()
    roi = SimRegion('hart_0', 'compute')
    df['ipc']    = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'),    axis=1)
    df['tstart'] = df.apply(lambda row: row['results'].get_metric(roi, 'tstart'), axis=1)
    df['tend']   = df.apply(lambda row: row['results'].get_metric(roi, 'tend'),   axis=1)
    return df


def main():
    manager = ExperimentManager(experiments=gen_experiments())
    manager.run()


if __name__ == '__main__':
    main()
