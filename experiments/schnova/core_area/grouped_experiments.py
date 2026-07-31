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
        {
            'design':   'schnova_synth',
            'name':     'GP-SV8-GRP',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 8,
                'NofFpuBufEntries': 28,
                'AluNofRss': 1,
                'LsuNofRss': 8,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 256,
                'NofPhysGpr': 52,
                'NofPhysFpr': 54,
                'NofRobEntries': 1,
                'UseFreeList': 0,
            }
        },
        {
            'design':   'schnova_synth',
            'name':     'GP-SV8-rob-GRP',
            'hdl_params': {
                'XFREPI': 1,
                'XFREPO': 1,
                'NofAlus': 3,
                'NofLsus': 3,
                'NofFpus': 1,
                'NofAluBufEntries': 16,
                'NofLsuBufEntries': 8,
                'NofFpuBufEntries': 28,
                'AluNofRss': 1,
                'LsuNofRss': 8,
                'FpuNofRss': 1,
                'ICacheFetchDataWidth': 256,
                'NofPhysGpr': 114,
                'NofPhysFpr': 66,
                'NofRobEntries': 128,
                'UseFreeList': 1,
            }
        },
        {
            'design': 'schnizo_synth',
            'name': 'Schnizo-GP-L-GRP',
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
    df['synth_results'] = df['synth_results'].str[FINAL_SYNTH_STAGE]
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
