#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

EARLY_SYNTH_STAGE = '7'
FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        return eu.derive_axes_from_keys(experiment, keys=['num_slots'])


def gen_experiments():
    # Define axes
    num_slots_axis = [1, 4, 32]

    # Generate list of experiments
    experiments = []
    for num_slots in num_slots_axis:
        experiments.append({
            'design': 'schnizo_fu_stage_synth',
            'num_slots': num_slots,
            'hdl_params': {'NofRss': num_slots}
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
