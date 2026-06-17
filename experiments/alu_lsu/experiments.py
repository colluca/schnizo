#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.util.experiments.SimResults import SimRegion
from snitch.util.experiments import experiment_utils as eu
from pathlib import Path
import os


class FrepExperimentManager(eu.ExperimentManager):

    def derive_axes(self, experiment):
        base_keys = eu.derive_axes_from_keys(experiment, keys=['hw', 'app', 'mode'])
        if experiment['app'] in ['sz_axpy', 'sz_dot']:
            return {**base_keys, 'size': experiment['data_cfg']['n']}
        return base_keys

    def derive_data_cfg(self, experiment):
        template_path = Path(f"data/{experiment['app']}_cfg.json.tpl")
        return eu.derive_data_cfg_from_template(experiment, template_path=template_path)

    def derive_cdefines(self, experiment):
        cdefines = {}
        if experiment['mode'] == 'scalar':
            cdefines['FORCE_HW_LOOP'] = 1
        return cdefines

    def derive_hw_cfg(self, experiment):
        return self.dir / Path(f"configs/{experiment['hw']}.json")


def gen_experiments(hardwares, sizes, axpy_modes, dot_modes):
    schnizo_dir = os.path.expanduser("/home/sem26f5/schnizo")
    mode_to_funcptr = {
        'scalar': '_baseline',
        'superscalar': '_schnizo',
        'unrolled': '_unrolled_schnizo',
        'peeled': '_peeled_schnizo',
        'AluLsuOpt': '_AluLsuOpt_schnizo',
        'naive': '_naive',
        'post_increment': '_post_increment_schnizo'
    }

    experiments = []

    app = 'sz_axpy'
    for hw in hardwares:
        for mode in axpy_modes:
            if hw == 'sz_baseline' and mode == 'post_increment':
                continue
            for n in sizes:
                verify_script = Path(f"{schnizo_dir}/sw/kernels/blas/{app}/scripts/verify.py")
                experiments.extend([
                    {
                        'app': app,
                        'roi': Path(f"roi/{app}_roi.json.tpl"),
                        'mode': mode,
                        'data_cfg': {
                            'n': n,
                            'funcptr': app.lstrip("sz_") + mode_to_funcptr[mode],
                        },
                        'hw': hw,
                        'verify_script': verify_script
                    },
                ])

    app = 'sz_dot'
    for hw in hardwares:
        for mode in dot_modes:
            if hw == 'sz_baseline' and mode == 'post_increment':
                continue
            for n in sizes:
                verify_script = Path(f"{schnizo_dir}/sw/kernels/blas/{app}/scripts/verify.py")
                experiments.extend([
                    {
                        'app': app,
                        'roi': Path(f"roi/{app}_roi.json.tpl"),
                        'mode': mode,
                        'data_cfg': {
                            'n': n,
                            'funcptr': app.lstrip("sz_") + mode_to_funcptr[mode],
                        },
                        'hw': hw,
                        'verify_script': verify_script
                    },
                ])

    return experiments


def main():
    experiments = []
    sizes = [64]

    # Baseline Test
    hw_baseline = ['sz_baseline']
    axpy_baseline = ['scalar', 'superscalar']
    dot_baseline = ['scalar', 'superscalar']
    experiments.extend(gen_experiments(hw_baseline, sizes, axpy_baseline, dot_baseline))

    # ALU/LSU test
    hw_intermediate = ['sz_alu_lsu']
    axpy_intermediate = ['scalar', 'superscalar', 'peeled', 'unrolled']
    dot_intermediate = ['scalar', 'superscalar', 'AluLsuOpt']
    experiments.extend(gen_experiments(hw_intermediate, sizes, axpy_intermediate, dot_intermediate))

    # Post-Increment test
    hw_post_inc = ['sz_alu_lsu_post_increment']
    axpy_post_inc = ['superscalar', 'post_increment']
    dot_post_inc = ['superscalar', 'post_increment']
    experiments.extend(gen_experiments(hw_post_inc, sizes, axpy_post_inc, dot_post_inc))

    manager = FrepExperimentManager(experiments=experiments)
    manager.run()

    try:
        df = manager.get_results()
        roi = SimRegion('hart_0', 'compute')
        df['ipc'] = df.apply(lambda row: row['results'].get_metric(roi, 'ipc'), axis=1)
        df['fpu_util'] = df.apply(lambda row: row['results'].get_metric(roi, 'fpu_util'), axis=1)
        print(df)

        # Export dataframe to CSV file
        df.drop(columns=['results'], inplace=True)
        df.to_csv(f'{manager.run_dir}/results.csv', index=False)
    except Exception:
        pass


if __name__ == '__main__':
    main()
