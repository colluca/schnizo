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
    num_slots_axis = [4, 8, 16, 32, 64]
    num_operands_axis = [2, 3]
    consumer_count_axis = [64, 512]

    # Generate list of experiments
    experiments = []
    for num_slots in num_slots_axis:
        for num_operands in num_operands_axis:
            for consumer_count in consumer_count_axis:
                experiments.append({
                    'design': 'schnizo_res_stat_synth',
                    'hdl_params': {
                        'NofRss': num_slots,
                        'NofOperands': num_operands,
                        'ConsumerCount': consumer_count
                    }
                })
    return experiments


def get_results():
    manager = ExperimentManager(gen_experiments())
    df = manager.get_results()
    df['synth_results'] = df['synth_results'].str[FINAL_SYNTH_STAGE]
    return df


def main():
    experiments = gen_experiments()
    manager = ExperimentManager(experiments=experiments)

    manager.run()


if __name__ == '__main__':
    main()
