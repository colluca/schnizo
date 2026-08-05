#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return experiment['hdl_params']


def gen_experiments():
    # Define axes
    num_slots_axis = [1, 2, 4, 8, 16, 32, 64]

    # Generate list of experiments
    experiments = []
    for num_slots in num_slots_axis:
        experiments.append({
            'design': 'schnova_alu_res_stat_synth',
            'name': f'rs_alu_{num_slots}',
            'hdl_params': {
                'UseFreeList': 0,
                'NofRss': num_slots,
            }
        })

        experiments.append({
            'design': 'schnova_lsu_res_stat_synth',
            'name': f'rs_lsu_{num_slots}',
            'hdl_params': {
                'UseFreeList': 0,
                'NofRss': num_slots,
            }
        })

        experiments.append({
            'design': 'schnova_fpu_res_stat_synth',
            'name': f'rs_fpu_{num_slots}',
            'hdl_params': {
                'UseFreeList': 0,
                'NofRss': num_slots,
            }
        })

    return experiments


def results(dir=None):
    manager = ExperimentManager(gen_experiments(), dir=dir, parse_args=False)
    df = manager.get_results()
    df['synth_results'] = df['synth_results'].str[FINAL_SYNTH_STAGE]
    return df


def main():
    experiments = gen_experiments()
    manager = ExperimentManager(experiments=experiments)

    manager.run()


if __name__ == '__main__':
    main()
