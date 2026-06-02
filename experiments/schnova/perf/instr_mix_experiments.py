#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments.SimResults import SimRegion
from snitch.util.experiments import experiment_utils as eu
from snitch.util.experiments.common import MK_DIR
from pathlib import Path


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        base_axes = eu.derive_axes_from_keys(experiment, keys=['app', 'mode', 'hw'])
        if experiment['app'] == 'pi_estimation':
            base_axes['app'] = f"{experiment['mc_app']}_{experiment['mc_prng']}"
        if experiment['app'] in ['sz_axpy', 'sz_dot', 'pi_estimation']:
            base_axes['size'] = experiment['data_cfg']['n']
        if experiment['app'] in ['exp', 'log']:
            base_axes['size'] = experiment['data_cfg']['len']
        if experiment['bal']:
            base_axes['app'] = f"{base_axes['app']}_bal" 
        return base_axes

    def derive_hw_cfg(self, experiment):
        return Path.cwd() / f"cfg/{experiment['hw']}.json"

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

        if experiment['app'] == 'exp' or experiment['app'] == 'log':
            cdefines['FUNC_PTR'] = experiment['data_cfg']['func_ptr']
        return cdefines


def gen_experiments(ci=False):
    # Define experiment axes
    cfgs = [
        'sv_8_3x32_3x32_1x32_32_128_128_256',
    ]

    modes = ['superscalar']
    sizes = [4096]
    bal_mix = [False, True]
    app_filter = None
    core = None

    # Drop failing tests at 256 when running in CI
    # Also drop tests at 512 and 4096, just for CI runtime
    if ci:
        sizes = sizes[2:-1]

    # Generate experiment list
    experiments = []
    for cfg in cfgs:
        # Check if this config targets the schnova core
        is_schnova_core = cfg.startswith('sv')
        core = 'schnova' if is_schnova_core else None
        for mode in modes:
            for size in sizes:
                for bal in bal_mix:
                    sim_bin = str(Path.cwd() / 'hw' / cfg / 'bin/snitch_cluster.vsim')
                    experiments.extend([
                        {
                            'app': 'sz_dot',
                            'hw': cfg,
                            'bal': bal,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'n': size,
                                'funcptr': 'dot_schnova' if bal else 'dot_schnizo',
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_dot/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/sz_dot_roi.json.tpl")
                        },
                        {
                            'app': 'sz_axpy',
                            'hw': cfg,
                            'bal': bal,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'n': size,
                                'funcptr': 'axpy_schnova',
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/blas/sz_axpy/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/sz_axpy_roi.json.tpl")
                        },
                    ])
                    experiments.extend([
                        {
                            'app': 'exp',
                            'hw': cfg,
                            'bal': bal,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'len': size,
                                'batch_size': size,
                                'func_ptr': 'vexpf_schnova' if bal else 'vexpf_schnizo'
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/misc/exp/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/exp.json.tpl")
                        },
                        {
                            'app': 'log',
                            'hw': cfg,
                            'bal': bal,
                            'mode': mode,
                            'core': core,
                            'data_cfg': {
                                'len': size,
                                'batch_size': size,
                                'func_ptr': 'vlogf_schnova' if bal else 'vlogf_schnizo'
                            },
                            'cmd': [str(MK_DIR / 'sw/kernels/misc/log/scripts/verify.py'),
                                    sim_bin, "${elf}"],
                            'roi': Path("roi/log.json.tpl")
                        },
                    ])
                    for mc_app in ['pi', 'poly']:
                        for mc_prng in ['lcg', 'xoshiro128p']:
                            experiments.append({
                                # TODO(colluca): rename app montecarlo
                                'app': 'pi_estimation',
                                'hw': cfg,
                                'bal': bal,
                                'mc_app': mc_app,
                                'mc_prng': mc_prng,
                                'mode': mode,
                                'core': core,
                                'data_cfg': {
                                    'n': size,
                                    'func_ptr': 'calculate_psum_schnova' if bal else 'calculate_psum_schnizo',
                                },
                                'cmd': [str(MK_DIR / 'sw/kernels/misc/montecarlo/pi_estimation/scripts/verify.py'),  # noqa: E501
                                        sim_bin, "${elf}"],
                                'roi': Path("roi/pi_estimation.json.tpl")
                            })


    # Filter by apps
    if app_filter is not None:
        experiments = [e for e in experiments
                       if e['app'] in app_filter
                       or f"{e.get('mc_app')}_{e.get('mc_prng')}" in app_filter]

    return experiments


def results(dir=None):
    df = ExperimentManager(gen_experiments(), dir=dir, parse_args=False).get_results()
    roi = SimRegion('hart_0', 'compute')
    df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
    df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument('--ci', action='store_true', help='Reduce number of experiments for CI')
    args = parser.parse_args()
    experiments = gen_experiments(ci=args.ci)
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
