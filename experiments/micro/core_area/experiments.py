#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

EARLY_SYNTH_STAGE = '7'
FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return eu.derive_axes_from_keys(experiment, keys=['name'])


def gen_experiments(designs=None):
    # Generate list of experiments
    # IMPORTANT: HDL parameters should be listed in the same order they appear in the RTL
    experiments = [
        # Sn.
        {
            'design': 'snitch_synth',
            'name': 'snitch'
        },
        # Sc.
        {
            'design': 'schnizo_synth',
            'name': 'scalar',
            'hdl_params': {
                'Xfrep': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 0,
                'MulInAlu0': 0,
            }
        },
        # FP-Sc.
        {
            'design': 'schnizo_synth',
            'name': 'scalar+mul+fpu',
            'hdl_params': {
                'Xfrep': 0,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
            }
        },
        # S
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_1x1_1x1_1x1',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
                'AluNofConstants': 1,
                'LsuNofConstants': 1,
                'FpuNofConstants': 1,
            }
        },
        # LA
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_3x4_3x4_1x4',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'AluNofRss': 4,
                'LsuNofRss': 4,
                'FpuNofRss': 4,
                'AluNofConstants': 4,
                'LsuNofConstants': 4,
                'FpuNofConstants': 4,
            }
        },
        # MC
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_3x32_1x0_2x32',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 3,
                'NofLsus': 1,
                'NofFpus': 2,
                'AluNofRss': 32,
                'LsuNofRss': 0,
                'FpuNofRss': 32,
                'AluNofConstants': 16,
                'LsuNofConstants': 4,  # Unused
                'FpuNofConstants': 16,
                'LsuNofResRspPorts': 0
            }
        },
        # TR
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_2x32_1x32_2x32',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 2,
                'NofLsus': 1,
                'NofFpus': 2,
                'AluNofRss': 32,
                'LsuNofRss': 32,
                'FpuNofRss': 32,
                'AluNofConstants': 16,
                'LsuNofConstants': 64,
                'FpuNofConstants': 16,
            }
        },
        # GP-M
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_1x128_1x32_1x64',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 128,
                'LsuNofRss': 32,
                'FpuNofRss': 64,
                'AluNofConstants': 32,
                'LsuNofConstants': 64,
                'FpuNofConstants': 32,
            }
        },
        # GP-L
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_3x32_3x32_1x64',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'AluNofRss': 32,
                'LsuNofRss': 32,
                'FpuNofRss': 64,
                'AluNofConstants': 16,
                'LsuNofConstants': 64,
                'FpuNofConstants': 32,
            }
        },
    ]
    if designs is not None:
        experiments = [experiment for experiment in experiments if experiment['name'] in designs]
    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
    df = df.set_index('name')
    df['synth_results'] = df['synth_results'].str[EARLY_SYNTH_STAGE]
    return df


def main():
    parser = ExperimentManager.parser()
    parser.add_argument('--designs', nargs='+')
    args = parser.parse_args()
    experiments = gen_experiments(designs=args.designs)
    manager = ExperimentManager(experiments=experiments, args=args, parse_args=False)

    manager.run()


if __name__ == '__main__':
    main()
