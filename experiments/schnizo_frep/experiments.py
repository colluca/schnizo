#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments.SimResults import SimRegion
from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from pathlib import Path

# TODO(colluca): which kernels partition the data across cores, and which don't?


class FrepExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        base_axes = eu.derive_axes_from_keys(experiment, keys=['app', 'mode'])
        if experiment['app'] == 'pi_estimation':
            base_axes['app'] = f"{experiment['mc_app']}_{experiment['mc_prng']}"
        if experiment['app'] in ['sz_axpy', 'sz_dot', 'pi_estimation']:
            return {**base_axes, 'size': experiment['data_cfg']['n']}
        if experiment['app'] in ['exp', 'log']:
            return {**base_axes, 'size': experiment['data_cfg']['len']}
        return base_axes

    def derive_data_cfg(self, experiment):
        if experiment['app'] not in ['pi_estimation']:
            template_path = Path(f"data/{experiment['app']}_cfg.json.tpl")
            return eu.derive_data_cfg_from_template(experiment, template_path=template_path)

    def derive_cdefines(self, experiment):
        cdefines = {}
        if experiment['mode'] == 'scalar':
            cdefines['FORCE_HW_LOOP'] = 1
        if experiment['app'] == 'pi_estimation':
            cdefines['N_SAMPLES'] = experiment['data_cfg']['n']
            cdefines['APPLICATION'] = 'APPLICATION_' + experiment['mc_app'].upper()
            cdefines['PRNG'] = 'PRNG_' + experiment['mc_prng'].upper()
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        return cdefines


def gen_experiments():
    experiments = []
    for mode in ['scalar', 'superscalar']:
        for n in [256, 512, 1024, 2048, 4096]:
            experiments.extend([
                {
                    'app': 'sz_dot',
                    'mode': mode,
                    'data_cfg': {
                        'n': n,
                        'funcptr': 'dot_schnizo',
                    },
                    'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_dot/scripts/verify.py'),
                            "${sim_bin}", "${elf}"],
                    'roi': Path("roi/sz_dot_roi.json.tpl")
                },
                {
                    'app': 'sz_axpy',
                    'mode': mode,
                    'data_cfg': {
                        'n': n,
                        'funcptr': 'axpy_baseline' if mode == 'scalar' else 'axpy_schnizo',
                    },
                    'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_axpy/scripts/verify.py'),
                            "${sim_bin}", "${elf}"],
                    'roi': Path("roi/sz_axpy_roi.json.tpl")
                },
                {
                    'app': 'exp',
                    'mode': mode,
                    'data_cfg': {
                        'len': n,
                        'batch_size': n,
                    },
                    'cmd': [str(MK_DIR / 'sw/kernels/misc/exp/scripts/verify.py'),
                            "${sim_bin}", "${elf}"],
                    'roi': Path("roi/exp.json.tpl")
                },
                {
                    'app': 'log',
                    'mode': mode,
                    'data_cfg': {
                        'len': n,
                        'batch_size': n,
                    },
                    'cmd': [str(MK_DIR / 'sw/kernels/misc/log/scripts/verify.py'),
                            "${sim_bin}", "${elf}"],
                    'roi': Path("roi/log.json.tpl")
                },
            ])
            for mc_app in ['pi', 'poly']:
                for mc_prng in ['lcg', 'xoshiro128p']:
                    experiments.append({
                        # TODO(colluca): rename app montecarlo
                        'app': 'pi_estimation',
                        'mc_app': mc_app,
                        'mc_prng': mc_prng,
                        'mode': mode,
                        'data_cfg': {
                            'n': n,
                            'func_ptr': 'calculate_psum_schnizo',
                        },
                        'roi': Path("roi/pi_estimation.json.tpl")
                    })
    return experiments


def main():
    experiments = gen_experiments()

    manager = FrepExperimentManager(experiments=experiments)
    manager.run()

    df = manager.get_results()
    roi = SimRegion('hart_0', 'compute')
    df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
    df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
    print(df)

    # Export dataframe to CSV file
    df.drop(columns=['results'], inplace=True)
    df.to_csv('results.csv', index=False)


if __name__ == '__main__':
    main()
