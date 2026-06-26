#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return experiment['hdl_params']


def gen_experiments(designs=None):

    experiments = []

    num_fu_axis = [1, 2, 3, 4]
    num_rss_axis = [1, 2, 4, 8, 16, 32]

    for num_fu in num_fu_axis:
        for num_rss in num_rss_axis:
            experiments.append({
                                    'design': 'schnova_fu_stage_synth',
                                    'hdl_params': {
                                        'UseFreeList': 0,
                                        'NofAlus':   num_fu,
                                        'AluNofRss': num_rss,
                                        'NofLsus':   1,
                                        'LsuNofRss': 1,
                                        'NofFpus':   1,
                                        'FpuNofRss': 1,
                                    }
                                })
            experiments.append({
                                    'design': 'schnova_fu_stage_synth',
                                    'hdl_params': {
                                        'UseFreeList': 0,
                                        'NofAlus':   1,
                                        'AluNofRss': 1,
                                        'NofLsus':   num_fu,
                                        'LsuNofRss': num_rss,
                                        'NofFpus':   1,
                                        'FpuNofRss': 1,
                                    }
                                })
            experiments.append({
                                    'design': 'schnova_fu_stage_synth',
                                    'hdl_params': {
                                        'UseFreeList': 0,
                                        'NofAlus':   1,
                                        'AluNofRss': 1,
                                        'NofLsus':   1,
                                        'LsuNofRss': 1,
                                        'NofFpus':   num_fu,
                                        'FpuNofRss': num_rss,
                                    }
                                })

    if designs is not None:
        experiments = [experiment for experiment in experiments if experiment['name'] in designs]
    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
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
