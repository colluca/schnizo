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
        # {
        #     'design': 'snitch_synth',
        #     'name': 'snitch'
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'scalar',
        #     'hdl_params': {
        #         'Xfrep': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 0,
        #         'MulInAlu0': 0,
        #     }
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'scalar+mul',
        #     'hdl_params': {
        #         'Xfrep': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 0,
        #     }
        # },
        # {
        #     'design': 'schnizo_synth',
        #     'name': 'scalar+mul+fpu',
        #     'hdl_params': {
        #         'Xfrep': 0,
        #         'NofAlus': 1,
        #         'NofLsus': 1,
        #         'NofFpus': 1,
        #     }
        # },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_small',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 1,
                'LsuNofRss': 1,
                'FpuNofRss': 1,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_medium',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 4,
                'LsuNofRss': 4,
                'FpuNofRss': 4,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_medium_96slots',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 32,
                'LsuNofRss': 32,
                'FpuNofRss': 32,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_medium-1AluRss',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 3,
                'LsuNofRss': 4,
                'FpuNofRss': 4,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_medium-1LsuRss',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 4,
                'LsuNofRss': 3,
                'FpuNofRss': 4,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_medium-1FpuRss',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 1,
                'NofLsus': 1,
                'NofFpus': 1,
                'AluNofRss': 4,
                'LsuNofRss': 4,
                'FpuNofRss': 3,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'superscalar_large',
            'hdl_params': {
                'Xfrep': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
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
