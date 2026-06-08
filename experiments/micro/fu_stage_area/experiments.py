#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments import experiment_utils as eu

EARLY_SYNTH_STAGE = '7'
FINAL_SYNTH_STAGE = '9'


class ExperimentManager(eu.ExperimentManager):

    def derive_axes(self, _experiment):
        return {}


def gen_experiments():
    return [{'design': 'schnizo_fu_stage_synth'}]


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
