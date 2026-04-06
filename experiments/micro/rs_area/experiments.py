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
    num_constants_axis = [4, 8, 16, 32, 64]
    num_res_ports_axis = [1]
    num_operands_axis = [2, 3]
    consumer_count_axis = [64]

    # Generate list of experiments
    experiments = []
    for num_slots in num_slots_axis:
        for num_constants in num_constants_axis:
            if num_slots != 4 and num_constants != 4:
                continue
            for num_operands in num_operands_axis:
                for num_res_ports in num_res_ports_axis:
                    for consumer_count in consumer_count_axis:
                        experiments.append({
                            'design': 'schnizo_res_stat_synth',
                            'hdl_params': {
                                'NofRss': num_slots,
                                'NofConstants': num_constants,
                                'NofOperands': num_operands,
                                'NofResRspIfs': num_res_ports,
                                'ConsumerCount': consumer_count
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
