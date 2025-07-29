#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from snitch.target.SimResults import SimRegion
from snitch.target.experiment_utils import ExperimentManager
import random

from mako.template import Template
from pathlib import Path
from datetime import datetime
from collections import defaultdict

# How to run this experiment:
# ./experiments.py --actions sw run traces roi perf --hw schnizo -j

VSIM_BINS = {
    'schnizo':   str(Path.cwd() / 'hw/schnizo/bin/snitch_cluster.vsim'),
    'snitch':   str(Path.cwd() / 'hw/snitch/bin/snitch_cluster.vsim'),
}
DATA_DIR = Path('data').absolute()

# Naming of perf.json metrics
METRIC_CYCLES = {
    'schnizo': 'cycles',
    'snitch': 'cycles',
}
METRIC_IPC = {
    'schnizo': 'total_ipc',
    'snitch': 'total_ipc',
}
METRIC_FPU_UTIL = {
    'schnizo': 'schnizo_fpu_occupancy',
    'snitch': 'fpss_fpu_occupancy',
}
METRIC_START = 'start'
METRIC_END = 'end'
NUM_CORES = 8


class FrepExperimentManager(ExperimentManager):

    def derive_axes(self, experiment):
        if (experiment['app'] == "sz_axpy" or experiment['app'] == "axpy"):
            return {
                'hw': experiment['hw'],
                'app': experiment['app'],
                'n': experiment['n'],
                'n_tiles': experiment['n_tiles'],
            }
        elif (experiment['app'] == "sz_dot" or experiment['app'] == "dot"):
            return {
                'hw': experiment['hw'],
                'app': experiment['app'],
                'n': experiment['n'],
            }

    def derive_data_cfg(self, experiment):
        # Create parent directory for configuration file
        cfg_path = DATA_DIR / experiment['name'] / 'cfg.json'
        cfg_path.parent.mkdir(parents=True, exist_ok=True)

        # Fill in configuration template and write configuration file
        with open(f"{experiment['app']}_cfg.json.tpl") as f:
            cfg = Template(f.read()).render(experiment=experiment)
        with open(cfg_path, 'w') as f:
            f.write(cfg)
        return cfg_path

    def derive_hw_cfg(self, experiment):
        return Path.cwd() / 'cfg' / f'{experiment["hw"]}.json'

    def derive_roi_template(self, experiment):
        return self.dir / f"{experiment['app']}_roi.json.tpl"


def gen_experiments(hardware):
    axpy_app_name = 'sz_axpy' if hardware == 'schnizo' else 'axpy'
    dot_app_name = 'sz_dot' if hardware == 'schnizo' else 'dot'
    experiments = [
        {'app': axpy_app_name, 'n': 2560, 'n_tiles': 2},
        {'app': axpy_app_name, 'n': 2560, 'n_tiles': 5},
        # Sweep tiles
        {'app': axpy_app_name, 'n': 4096, 'n_tiles': 2},
        {'app': axpy_app_name, 'n': 4096, 'n_tiles': 4},
        {'app': axpy_app_name, 'n': 4096, 'n_tiles': 8},
        # Sweep number of elements
        {'app': axpy_app_name, 'n': 1024, 'n_tiles': 2},
        {'app': axpy_app_name, 'n': 2048, 'n_tiles': 2},
        {'app': axpy_app_name, 'n': 3072, 'n_tiles': 2},
        # {'app': axpy_app_name, 'n': 4096, 'n_tiles': 2},  # already included above

        {'app': dot_app_name, 'n': 1024},
        {'app': dot_app_name, 'n': 2048},
        {'app': dot_app_name, 'n': 4096},
    ]

    for experiment in experiments:
        if experiment['app'] == "sz_dot" or experiment['app'] == "dot":
            assert (experiment['n'] % (NUM_CORES * 4)) == 0, "n must be an integer " \
                   f"multiple of the number of cores times the unrolling factor (cores = {NUM_CORES}, unrolling factor = 4)"
        if experiment['app'] == "sz_axpy" or experiment['app'] == "axpy":
            assert experiment['n'] % experiment['n_tiles'] == 0, "n must be " \
                   "an integer multiple of n_tiles"
            n_per_tile = experiment['n'] // experiment['n_tiles']
            assert (n_per_tile % NUM_CORES) == 0, "n must be an integer multiple of " \
                   f"the number of cores ({NUM_CORES})"

    return experiments


def extract_sz_axpy_results(df):
    # extract duration, ipc and fpu utilization of each tile for each core
    for _, exp_res in df.iterrows():
        # results per core per tile
        results = defaultdict(lambda: defaultdict(dict))
        for core in range(NUM_CORES):
            result_cols = {}
            for tile_i in range(int(exp_res['n_tiles'])):
                cycle = exp_res['results'].get_metric(SimRegion(f'hart_{core}', f'tile_{tile_i}'), METRIC_CYCLES[exp_res['hw']])
                ipc = exp_res['results'].get_metric(SimRegion(f'hart_{core}', f'tile_{tile_i}'), METRIC_IPC[exp_res['hw']])
                fpu_util = exp_res['results'].get_metric(SimRegion(f'hart_{core}', f'tile_{tile_i}'), METRIC_FPU_UTIL[exp_res['hw']])
                # store the results in a dictionary
                results[core][tile_i] = {
                    'cycles': cycle,
                    'ipc': ipc,
                    'fpu_util': fpu_util
                }
                # Add a new column to the row / dataframe df with the data cycle and ipc
                result_cols[f'hart_{core}_tile_{tile_i}_cycles'] = cycle
                result_cols[f'hart_{core}_tile_{tile_i}_ipc'] = ipc
                result_cols[f'hart_{core}_tile_{tile_i}_fpu_util'] = fpu_util
            # create an average cycle and ipc value over all tiles
            avg_cycle = sum(value for key, value in result_cols.items() if f'hart_{core}_tile' in key and 'cycles' in key) / exp_res['n_tiles']
            avg_ipc = sum(value for key, value in result_cols.items() if f'hart_{core}_tile' in key and 'ipc' in key) / exp_res['n_tiles']
            avg_fpu_util = sum(value for key, value in result_cols.items() if f'hart_{core}_tile' in key and 'fpu_util' in key) / exp_res['n_tiles']
            result_cols[f'hart_{core}_cycles_avg'] = avg_cycle
            result_cols[f'hart_{core}_ipc_avg'] = avg_ipc
            result_cols[f'hart_{core}_fpu_util_avg'] = avg_fpu_util
            for col, value in result_cols.items():
                df.at[exp_res.name, col] = value
            # extract the total cycles
            start = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'start'), 'start')
            end = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'end'), 'start')
            df.at[exp_res.name, f'hart_{core}_total_cycles'] = end - start
        # compute the mean and stddev over all clusters
        # for each tile
        for tile_i in range(int(exp_res['n_tiles'])):
            cycles_mean = 0
            ipc_mean = 0
            fpu_util_mean = 0
            for core in range(NUM_CORES):
                cycles_mean += results[core][tile_i]['cycles']
                ipc_mean += results[core][tile_i]['ipc']
                fpu_util_mean += results[core][tile_i]['fpu_util']
            cycles_mean /= NUM_CORES
            ipc_mean /= NUM_CORES
            fpu_util_mean /= NUM_CORES
            # standard deviation
            cycles_stddev = 0
            ipc_stddev = 0
            fpu_util_stddev = 0
            for core in range(NUM_CORES):
                cycles_stddev += (cycles_mean - results[core][tile_i]['cycles']) ** 2
                ipc_stddev += (ipc_mean - results[core][tile_i]['ipc']) ** 2
                fpu_util_stddev += (fpu_util_mean - results[core][tile_i]['fpu_util']) ** 2
            cycles_stddev = (cycles_stddev / NUM_CORES) ** 0.5
            ipc_stddev = (ipc_stddev / NUM_CORES) ** 0.5
            fpu_util_stddev = (fpu_util_stddev / NUM_CORES) ** 0.5
            # add to the dataframe
            df.at[exp_res.name, f'tile{tile_i}_cycles_avg'] = cycles_mean
            df.at[exp_res.name, f'tile{tile_i}_cycles_stddev'] = cycles_stddev
            df.at[exp_res.name, f'tile{tile_i}_ipc_avg'] = ipc_mean
            df.at[exp_res.name, f'tile{tile_i}_ipc_stddev'] = ipc_stddev
            df.at[exp_res.name, f'tile{tile_i}_fpu_util_avg'] = fpu_util_mean
            df.at[exp_res.name, f'tile{tile_i}_fpu_util_stddev'] = fpu_util_stddev
        # for all tiles combined
        cycles_mean = 0
        ipc_mean = 0
        fpu_util_mean = 0
        for tile_i in range(int(exp_res['n_tiles'])):
            cycles_mean += df.at[exp_res.name, f'tile{tile_i}_cycles_avg']
            ipc_mean += df.at[exp_res.name, f'tile{tile_i}_ipc_avg']
            fpu_util_mean += df.at[exp_res.name, f'tile{tile_i}_fpu_util_avg']
        cycles_mean /= exp_res['n_tiles']
        ipc_mean /= exp_res['n_tiles']
        fpu_util_mean /= exp_res['n_tiles']
        # standard deviation
        cycles_stddev = 0
        ipc_stddev = 0
        fpu_util_stddev = 0
        for tile_i in range(int(exp_res['n_tiles'])):
            for core in range(NUM_CORES):
                cycles_stddev += (cycles_mean - results[core][tile_i]['cycles']) ** 2
                ipc_stddev += (ipc_mean - results[core][tile_i]['ipc']) ** 2
                fpu_util_stddev += (fpu_util_mean - results[core][tile_i]['fpu_util']) ** 2
        cycles_stddev = (cycles_stddev / (NUM_CORES * exp_res['n_tiles'])) ** 0.5
        ipc_stddev = (ipc_stddev / (NUM_CORES * exp_res['n_tiles'])) ** 0.5
        fpu_util_stddev = (fpu_util_stddev / (NUM_CORES * exp_res['n_tiles'])) ** 0.5
        # add to the dataframe
        df.at[exp_res.name, 'cycles_avg'] = cycles_mean
        df.at[exp_res.name, 'cycles_stddev'] = cycles_stddev
        df.at[exp_res.name, 'ipc_avg'] = ipc_mean
        df.at[exp_res.name, 'ipc_stddev'] = ipc_stddev
        df.at[exp_res.name, 'fpu_util_avg'] = fpu_util_mean
        df.at[exp_res.name, 'fpu_util_stddev'] = fpu_util_stddev
        # Total execution cycles over all harts
        total_cycles_mean = 0
        for core in range(NUM_CORES):
            total_cycles_mean += df.at[exp_res.name, f'hart_{core}_total_cycles']
        total_cycles_mean /= NUM_CORES
        total_cycles_stddev = 0
        for core in range(NUM_CORES):
            total_cycles_stddev += (total_cycles_mean - df.at[exp_res.name, f'hart_{core}_total_cycles']) ** 2
        total_cycles_stddev = (total_cycles_stddev / NUM_CORES) ** 0.5
        df.at[exp_res.name, 'total_cycles_avg'] = total_cycles_mean
        df.at[exp_res.name, 'total_cycles_stddev'] = total_cycles_stddev

    return df


def extract_sz_dot_results(df):
    for _, exp_res in df.iterrows():
        for core in range(NUM_CORES):
            start = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'compute'), METRIC_START)
            end = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'end'), METRIC_START)
            df.at[exp_res.name, f'hart_{core}_total_cycles'] = end - start
            compute_ipc = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'compute'), METRIC_IPC[exp_res['hw']])
            df.at[exp_res.name, f'hart_{core}_compute_ipc'] = compute_ipc
            compute_cycles = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'compute'), METRIC_CYCLES[exp_res['hw']])
            df.at[exp_res.name, f'hart_{core}_compute_cycles'] = compute_cycles
            compute_fpu_util = exp_res['results'].get_metric(SimRegion(f'hart_{core}', 'compute'), METRIC_FPU_UTIL[exp_res['hw']])
            df.at[exp_res.name, f'hart_{core}_compute_fpu_util'] = compute_fpu_util
        # compute the mean and stddev over all cores
        compute_cycles_mean = 0
        compute_ipc_mean = 0
        compute_fpu_util_mean = 0
        total_cycles_mean = 0
        for core in range(NUM_CORES):
            compute_cycles_mean += df.at[exp_res.name, f'hart_{core}_compute_cycles']
            compute_ipc_mean += df.at[exp_res.name, f'hart_{core}_compute_ipc']
            compute_fpu_util_mean += df.at[exp_res.name, f'hart_{core}_compute_fpu_util']
            total_cycles_mean += df.at[exp_res.name, f'hart_{core}_total_cycles']
        compute_cycles_mean /= NUM_CORES
        compute_ipc_mean /= NUM_CORES
        compute_fpu_util_mean /= NUM_CORES
        total_cycles_mean /= NUM_CORES
        # standard deviation
        compute_cycles_stddev = 0
        compute_ipc_stddev = 0
        compute_fpu_util_stddev = 0
        total_cycles_stddev = 0
        for core in range(NUM_CORES):
            compute_cycles_stddev += (compute_cycles_mean - df.at[exp_res.name, f'hart_{core}_compute_cycles']) ** 2
            compute_ipc_stddev += (compute_ipc_mean - df.at[exp_res.name, f'hart_{core}_compute_ipc']) ** 2
            compute_fpu_util_stddev += (compute_fpu_util_mean - df.at[exp_res.name, f'hart_{core}_compute_fpu_util']) ** 2
            total_cycles_stddev += (total_cycles_mean - df.at[exp_res.name, f'hart_{core}_total_cycles']) ** 2
        compute_cycles_stddev = (compute_cycles_stddev / NUM_CORES) ** 0.5
        compute_ipc_stddev = (compute_ipc_stddev / NUM_CORES) ** 0.5
        compute_fpu_util_stddev = (compute_fpu_util_stddev / NUM_CORES) ** 0.5
        total_cycles_stddev = (total_cycles_stddev / NUM_CORES) ** 0.5
        # add to the dataframe
        df.at[exp_res.name, 'compute_cycles_avg'] = compute_cycles_mean
        df.at[exp_res.name, 'compute_cycles_stddev'] = compute_cycles_stddev
        df.at[exp_res.name, 'compute_ipc_avg'] = compute_ipc_mean
        df.at[exp_res.name, 'compute_ipc_stddev'] = compute_ipc_stddev
        df.at[exp_res.name, 'compute_fpu_util_avg'] = compute_fpu_util_mean
        df.at[exp_res.name, 'compute_fpu_util_stddev'] = compute_fpu_util_stddev
        df.at[exp_res.name, 'total_cycles_avg'] = total_cycles_mean
        df.at[exp_res.name, 'total_cycles_stddev'] = total_cycles_stddev
    return df


def main():
    seed = 22
    random.seed(seed)

    parser = FrepExperimentManager.parser()
    parser.add_argument('--hw',
                        type=str,
                        help='Specify the hardware configuration to use.',
                        default='schnizo')
    args = parser.parse_args()

    # Fall back to some default experiments in case no yaml file is provided.
    # The Experiment Manager first checks if the argument "testlist" is provided.
    # If so, it will read the experiments from the yaml file.
    # If not, it will use the experiments which were passed at construction
    # (i.e., these defined here).
    experiments = gen_experiments(args.hw)

    # Define HW configuration
    for experiment in experiments:
        experiment['hw'] = args.hw
        experiment['cmd'] = [VSIM_BINS[experiment['hw']], "${elf}"]

    manager = FrepExperimentManager(experiments, args=args)
    manager.run()

    df = manager.get_results()

    app_results = []

    if manager.perf_results_available:
        # for each app, extract its results into a separate dataframe
        for app in df['app'].unique():
            app_df = df[df['app'] == app].copy(deep=True)
            if app == "sz_axpy" or app == "axpy":
                app_df = extract_sz_axpy_results(app_df)
            elif app == "sz_dot" or app == "dot":
                app_df = extract_sz_dot_results(app_df)
            app_results.append(app_df)

    # create the folder results if it does not exist
    results_dir = Path('results')
    results_dir.mkdir(parents=True, exist_ok=True)
    if df is not None:
        print("Overall results:")
        df.drop(columns=['results'], inplace=True)
        print(df)
        df.to_csv(results_dir / f'results_{datetime.now().strftime("%Y%m%d_%H%M%S")}.csv', index=False)
    if app_results is not None:
        print("\nResults per app:")
        for app_df in app_results:
            app_df.drop(columns=['results'], inplace=True)
            print(app_df)
            app_df.to_csv(results_dir / f'results_{app_df["app"].iloc[0]}_{datetime.now().strftime("%Y%m%d_%H%M%S")}.csv', index=False)


if __name__ == '__main__':
    main()
