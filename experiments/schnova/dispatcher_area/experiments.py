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

    # Generate list of experiments
    experiments = []

    # Pipeline Width of 1
    experiments.append({
        'design': 'schnova_dispatcher_synth',
        'hdl_params': {
            'PipeWidth':        1,
            'NofAlus':          1,
            'NofLsus':          1,
            'NofFpus':          1,
            'NofAluBufEntries': 1,
            'NofLsuBufEntries': 1,
            'NofFpuBufEntries': 1,
        }
    })

    # Pipeline Width of 2
    experiments.append({
        'design': 'schnova_dispatcher_synth',
        'hdl_params': {
            'PipeWidth':        2,
            'NofAlus':          2,
            'NofLsus':          2,
            'NofFpus':          1,
            'NofAluBufEntries': 2,
            'NofLsuBufEntries': 2,
            'NofFpuBufEntries': 2,
        }
    })

    # Pipeline Width of 4
    experiments.append({
        'design': 'schnova_dispatcher_synth',
        'hdl_params': {
            'PipeWidth':        4,
            'NofAlus':          3,
            'NofLsus':          3,
            'NofFpus':          1,
            'NofAluBufEntries': 4,
            'NofLsuBufEntries': 4,
            'NofFpuBufEntries': 4,
        }
    })

    # Pipeline Width of 8
    experiments.append({
        'design': 'schnova_dispatcher_synth',
        'hdl_params': {
            'PipeWidth':        8,
            'NofAlus':          3,
            'NofLsus':          3,
            'NofFpus':          1,
            'NofAluBufEntries': 8,
            'NofLsuBufEntries': 8,
            'NofFpuBufEntries': 8,
        }
    })

    num_buf_entries_axis = [2, 4, 8, 16, 32]

    for num_buf_entries in num_buf_entries_axis:
        experiments.append({
            'design': 'schnova_dispatcher_synth',
            'hdl_params': {
                'PipeWidth':        1,
                'NofAlus':          1,
                'NofLsus':          1,
                'NofFpus':          1,
                'NofAluBufEntries': num_buf_entries_axis,
                'NofLsuBufEntries': 1,
                'NofFpuBufEntries': 1,
            }
        })
        experiments.append({
            'design': 'schnova_dispatcher_synth',
            'hdl_params': {
                'PipeWidth':        1,
                'NofAlus':          1,
                'NofLsus':          1,
                'NofFpus':          1,
                'NofAluBufEntries': 1,
                'NofLsuBufEntries': num_buf_entries_axis,
                'NofFpuBufEntries': 1,
            }
        })
        experiments.append({
            'design': 'schnova_dispatcher_synth',
            'hdl_params': {
                'PipeWidth':        1,
                'NofAlus':          1,
                'NofLsus':          1,
                'NofFpus':          1,
                'NofAluBufEntries': 1,
                'NofLsuBufEntries': 1,
                'NofFpuBufEntries': num_buf_entries_axis,
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
