#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate synthesis-result tables and area/performance plots.

The module can be imported by the experiment package or executed directly to
generate one or more named plots from the command line.
"""
import argparse

import matplotlib.patches as patches
import matplotlib.pyplot as plt
import pandas as pd
from matplotlib.lines import Line2D

from area_row import AreaRow
from plot_util import PULP_COLORS_BASE, smooth_polygon

try:
    from . import experiments
    from . import grouped_experiments
except ImportError:
    import experiments
    import grouped_experiments


GE = 0.121


def to_ge(area_um2):
    """To ge."""
    return area_um2 / GE


def to_kge(area_um2):
    """To kge."""
    return to_ge(area_um2) / 1000.0


def to_mm2(area_kge):
    """To mm2."""
    return area_kge * 1000.0 * GE / 1000000.0


def results(dir=None):
    """Prints the current synthesis results."""
    df = experiments.results(dir=dir)
    df['timestamp'] = df['synth_results'].str['qor_summary'].str['timestamp']
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    df['CombArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('CombArea')))  # noqa: E501
    df['SeqArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('SeqArea')))  # noqa: E501
    df['CombArea'] = df['CombArea'].round(0).astype('int')
    df['SeqArea'] = df['SeqArea'].round(0).astype('int')
    df['StdCellArea'] = df['synth_results'].str['qor_summary'].str['StdCellArea']  # noqa: E501
    df['StdCellArea'] = df['StdCellArea'].map(to_kge).round(0).astype('int')
    baseline = 128
    df['AreaIncrease'] = (df['StdCellArea'] / baseline).round(1)
    df['CLK'] = 1 - df['synth_results'].str['qor_summary'].str['WNS']
    df['1BitEqSeq'] = df['synth_results'].str['multibit'].str['1BitEqSeq'].astype('int')  # noqa: E501
    df['GE/bit'] = (1000.0 * df['SeqArea'] / df['1BitEqSeq']).round(1)
    df.drop(columns=['hierarchy_details'], inplace=True)
    df.drop(columns=['synth_results'], inplace=True)
    return df


def area_efficiency_plot(cluster=False):
    """Generates the trade-off plot between performance and area efficiency."""
    designs = {'Schnova-ZOL': {'IPC': 0.85, 'CLK': 1.022, 'area': 129},
               'Schnizo-GP-L': {'IPC': 2.52, 'CLK': 2.003, 'area': 1311},
               'Schnizo-LA': {'IPC': 4.834, 'CLK': 1.108, 'area': 304},
               'CVA6S+': {'IPC': 2, 'CLK': 1.164, 'area': 851},
               'C910': {'IPC': 3, 'CLK': 0.757, 'area': 2674},
               'GP-FW1': {'IPC': 0.91, 'CLK': 1.011, 'area': 194},
               'GP-FW2': {'IPC': 1.64, 'CLK': 1.051, 'area': 345},
               'GP-FW4': {'IPC': 2.13, 'CLK': 1.065, 'area': 464},
               'GP-FW8': {'IPC': 2.52, 'CLK': 1.219, 'area': 589},
               'GP-FW1-ROB': {'IPC': 0.91, 'CLK': 1.015, 'area': 330},
               'GP-FW2-ROB': {'IPC': 1.64, 'CLK': 1.051, 'area': 439},
               'GP-FW4-ROB': {'IPC': 2.13, 'CLK': 1.199, 'area': 674},
               'GP-FW8-ROB': {'IPC': 2.52, 'CLK': 1.246, 'area': 815},
               'LA-FW1': {'IPC': 1.0, 'CLK': 1.005, 'area': 182},
               'LA-FW2': {'IPC': 1.77, 'CLK': 1.004, 'area': 245},
               'LA-FW4': {'IPC': 3.479, 'CLK': 1.092, 'area': 342},
               'LA-FW8': {'IPC': 4.915, 'CLK': 1.171, 'area': 543},
               'Spatz-LA': {'IPC': 2.14, 'CLK': 1.0, 'area': 583}}

    # Scale area values to cluster level
    excluded_from_area_scaling = {'CVA6S+', 'C910', 'Spatz-LA'}
    if cluster:
        for name, values in designs.items():
            if name not in excluded_from_area_scaling:
                values['area'] = values['area'] * 8 + 1965
        designs['Spatz-LA']['area'] = 4377
        designs['CVA6S+']['area'] = 2408 * 8
        designs['C910']['area'] = 3992 * 8
    baseline_name = 'Schnova-ZOL'

    # Calculate performance mettrics
    for d in designs.values():
        d['performance_gips'] = d['IPC'] / d['CLK']
        if cluster:
            d['area_efficiency'] = 1000 * 8 * d['performance_gips'] / d['area']
        else:
            d['area_efficiency'] = 1000 * d['performance_gips'] / d['area']
    if baseline_name not in designs:
        raise KeyError(f"Baseline configuration '{baseline_name}' is missing")
    baseline_performance = designs[baseline_name]['performance_gips']
    baseline_efficiency = designs[baseline_name]['area_efficiency']

    # Print the current values to the console
    print()
    print(f"{'Configuration':<18}{'Area [kGE]':>12}{'Perf. [GIPS]':>15}{'Perf. Increase':>17}{'Eff. [MIPS/kGE]':>19}{'Eff. Increase':>16}")  # noqa: E501
    print('-' * 97)
    for name, values in designs.items():
        performance = values['performance_gips']
        efficiency = values['area_efficiency']
        performance_increase = 100.0 * (performance / baseline_performance - 1.0)  # noqa: E501
        efficiency_increase = 100.0 * (efficiency / baseline_efficiency - 1.0)
        values['performance_increase_percent'] = performance_increase
        values['area_efficiency_increase_percent'] = efficiency_increase
        print(f"{name:<18}{values['area']:>12.0f}{performance:>15.3f}{performance_increase:>16.1f}%{efficiency:>19.3f}{efficiency_increase:>15.1f}%")  # noqa: E501
    print()
    print(f'Baseline: {baseline_name}')

    # Generate a scatter plot for the performance vs. area efficiency trade-off
    marker_map = {'Schnova-ZOL': ('tab:blue', 'o'),
                  'Schnizo-LA': ('tab:red', 'd'),
                  'Schnizo-GP-L': ('tab:cyan', 'd'),
                  'Spatz-LA': ('tab:gray', '+'),
                  'CVA6S+': ('tab:pink', 's'),
                  'C910': ('tab:olive', 's'),
                  'GP-FW1-ROB': ('tab:orange', 'o'),
                  'GP-FW2-ROB': ('tab:orange', '*'),
                  'GP-FW4-ROB': ('tab:orange', '^'),
                  'GP-FW8-ROB': ('tab:orange', 'D'),
                  'GP-FW1': ('tab:green', 'o'),
                  'GP-FW2': ('tab:green', '*'),
                  'GP-FW4': ('tab:green', '^'),
                  'GP-FW8': ('tab:green', 'D'),
                  'LA-FW1': ('tab:purple', 'o'),
                  'LA-FW2': ('tab:purple', '*'),
                  'LA-FW4': ('tab:purple', '^'),
                  'LA-FW8': ('tab:purple', 'D')}
    plt.figure(figsize=(10, 4.2))
    for name, d in designs.items():
        perf = d['performance_gips']
        eff = d['area_efficiency']
        color, marker = marker_map[name]
        plt.scatter(perf, eff, s=130, color=color, marker=marker, label=name)
    plt.xlabel('Performance [GIPS]', fontsize=12)
    plt.ylabel('Area Efficiency [MIPS/kGE]', fontsize=12)
    plt.grid(True, alpha=0.35)
    plt.legend(loc='upper left', ncol=4, frameon=True)
    plt.tight_layout()
    plt.savefig('tradeoff_cluster.png' if cluster else 'tradeoff_core.png', bbox_inches='tight', pad_inches=0.1, dpi=300)  # noqa: E501


def extract_hierarchy(tree):
    """Extract hierarchy from synthesis results."""
    rows = []

    def visit(node, path=''):
        """Visit."""
        name = getattr(node, 'name', '')
        full_path = f'{path}/{name}' if path else name
        rows.append({'path': full_path,
                     'level': full_path.count('/'),
                     'CombArea': getattr(node, 'CombArea', None),
                     'SeqArea': getattr(node, 'SeqArea', None),
                     'StdCellArea': getattr(node, 'StdCellArea', None),
                     'MacroBBArea': getattr(node, 'MacroBBArea', None)})
        for child in node.children:
            visit(child, full_path)
    visit(tree)
    return pd.DataFrame(rows)


def connect(ax, gA, idxA, gB, idxB, bar_h, color='gray', alpha=0.2):
    """Connects polygons, helper function."""
    labelsA, widthsA, leftsA, yA = gA.values()
    labelsB, widthsB, leftsB, yB = gB.values()
    x1_left = leftsA[idxA]
    x1_right = leftsA[idxA] + widthsA[idxA]
    x2_left = leftsB[idxB]
    x2_right = leftsB[idxB] + widthsB[idxB]
    p1 = (x1_left, yA + bar_h / 2)
    p2 = (x1_right, yA + bar_h / 2)
    p3 = (x2_right, yB - bar_h / 2)
    p4 = (x2_left, yB - bar_h / 2)
    path = smooth_polygon(p1, p2, p3, p4)
    ax.add_patch(patches.PathPatch(path, facecolor=color, edgecolor='none', alpha=alpha))  # noqa: E501


def plot_rfcnt_core_breakdown(dir=None):
    """Area breakdown for reference counting core."""
    name = 'GP-SV8-GRP'
    results_df = grouped_experiments.results(dir=dir)
    results_df['hierarchy_details'] = results_df['synth_results'].str['hierarchy_details']  # noqa: E501
    hierarchy = results_df['hierarchy_details'].loc[name]
    area_df = extract_hierarchy(hierarchy.tree)
    area_df['CombArea'] = area_df['CombArea'].map(to_kge)
    area_df['SeqArea'] = area_df['SeqArea'].map(to_kge)
    area_df['StdCellArea'] = area_df['StdCellArea'].map(to_kge)
    area_df['area'] = area_df['StdCellArea']

    def get_area(path):
        """Get area."""
        rows = area_df[area_df['path'] == path]
        if rows.empty:
            print(f'Warning: hierarchy path not found: {path}')
            return 0.0
        return rows['area'].iloc[0]
    schnova_area = get_area('./i_schnova')
    fu_stage_area = get_area('./i_schnova/i_fu_stage')
    if schnova_area <= 0:
        raise ValueError('Could not determine the Schnova area.')
    if fu_stage_area <= 0:
        raise ValueError('Could not determine the FU-stage area.')
    schnova_blocks = {'FU Stage': './i_schnova/i_fu_stage',
                      'Refcnt': './i_schnova/gen_phys_reg_manage_gen_refcount_reg_manage_i_refcount',  # noqa: E501
                      'Dispatcher': './i_schnova/i_dispatcher',
                      'FPR': './i_schnova/gen_fp_rf_i_fp_phy_regfile',
                      'GPR': './i_schnova/i_int_phy_regfile',
                      'Rename': './i_schnova/gen_rename_i_rename'}
    row1_names = list(schnova_blocks.keys())
    row1_vals = [get_area(path) for path in schnova_blocks.values()]
    row1_rest = schnova_area - sum(row1_vals)
    if row1_rest < 0 and abs(row1_rest) < 1e-06:
        row1_rest = 0.0
    if row1_rest < 0:
        raise ValueError(f'The explicitly selected Schnova blocks exceed the total Schnova area by {-row1_rest:.2f} kGE.')  # noqa: E501
    row1_names.append('Rest')
    row1_vals.append(row1_rest)
    alu_area = area_df[area_df['path'].str.contains('gen_alus_', na=False) & area_df['path'].str.endswith('i_alu', na=False)]['area'].sum()  # noqa: E501
    fpu_area = area_df[area_df['path'].str.contains('gen_fpus_', na=False) & area_df['path'].str.endswith('_i_fpu', na=False)]['area'].sum()  # noqa: E501
    lsu_area = area_df[area_df['path'].str.contains('gen_lsus_', na=False) & area_df['path'].str.endswith('i_lsu', na=False)]['area'].sum()  # noqa: E501
    rs_area = area_df[area_df['path'].str.endswith('gen_rs_i_res_stat', na=False)]['area'].sum()  # noqa: E501
    row2_names = ['FPU', 'RSs', '3 ALUs', '3 LSUs']
    row2_vals = [fpu_area, rs_area, alu_area, lsu_area]
    print(fpu_area)
    row2_rest = fu_stage_area - sum(row2_vals)
    if row2_rest < 0 and abs(row2_rest) < 1e-06:
        row2_rest = 0.0
    if row2_rest < 0:
        raise ValueError(f'The explicitly selected FU-stage blocks exceed the total FU-stage area by {-row2_rest:.2f} kGE.')  # noqa: E501
    row2_names.append('Rest')
    row2_vals.append(row2_rest)
    row1 = AreaRow(row1_names, total_area=schnova_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row2 = AreaRow(row2_names, total_area=fu_stage_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row1.build(row1_vals, row1_names)
    row2.build(row2_vals, row2_names)
    rows = [row1, row2]
    fig, ax = plt.subplots(figsize=(10, 4), dpi=300)
    bar_height = 0.3
    row_spacing = 1.0
    label_position = 0.65
    percent_position = 0.95
    specs = [(rows[0], 0.0, None), (rows[1], row_spacing, None)]
    ax.set_xlim(0, 1)
    ax.invert_yaxis()
    ax.axis('off')
    geometry = []
    for row, y_position, offset_indices in specs:
        labels, widths, lefts, plotted_y = row.plot(ax, y_position, offset_indices=offset_indices, bar_height=bar_height, pos1=label_position, pos2=percent_position)  # noqa: E501
        geometry.append({'labels': list(labels), 'widths': list(widths), 'lefts': list(lefts), 'y': plotted_y})  # noqa: E501
    upper = geometry[0]
    lower = geometry[1]
    fu_index = upper['labels'].index('FU Stage')
    fu_left = upper['lefts'][fu_index]
    fu_right = fu_left + upper['widths'][fu_index]
    lower_left = min(lower['lefts'])
    lower_right = max((left + width for left, width in zip(lower['lefts'], lower['widths'])))  # noqa: E501
    upper_left_point = (fu_left, upper['y'] + bar_height / 2)
    upper_right_point = (fu_right, upper['y'] + bar_height / 2)
    lower_right_point = (lower_right, lower['y'] - bar_height / 2)
    lower_left_point = (lower_left, lower['y'] - bar_height / 2)
    connector_path = smooth_polygon(upper_left_point, upper_right_point, lower_right_point, lower_left_point)  # noqa: E501
    ax.add_patch(patches.PathPatch(connector_path, facecolor='gray', edgecolor='none', alpha=0.2, zorder=0))  # noqa: E501
    fig.tight_layout()
    fig.savefig('rfcnt_core_breakdown.png', bbox_inches='tight', pad_inches=0.1, dpi=300)  # noqa: E501
    plt.show()
    return {'schnova': dict(zip(row1_names, row1_vals)), 'fu_stage': dict(zip(row2_names, row2_vals))}  # noqa: E501


def plot_rob_core_breakdown(dir=None):
    """Area breakdown for ROB core."""
    name = 'GP-SV8-rob-GRP'
    results_df = grouped_experiments.results(dir=dir)
    results_df['hierarchy_details'] = results_df['synth_results'].str['hierarchy_details']  # noqa: E501
    hierarchy = results_df['hierarchy_details'].loc[name]
    area_df = extract_hierarchy(hierarchy.tree)
    area_df['CombArea'] = area_df['CombArea'].map(to_kge)
    area_df['SeqArea'] = area_df['SeqArea'].map(to_kge)
    area_df['StdCellArea'] = area_df['StdCellArea'].map(to_kge)
    area_df['area'] = area_df['StdCellArea']

    def get_area(path):
        """Get area."""
        rows = area_df[area_df['path'] == path]
        if rows.empty:
            print(f'Warning: hierarchy path not found: {path}')
            return 0.0
        return rows['area'].iloc[0]
    schnova_area = get_area('./i_schnova')
    fu_stage_area = get_area('./i_schnova/i_fu_stage')
    if schnova_area <= 0:
        raise ValueError('Could not determine the Schnova area.')
    if fu_stage_area <= 0:
        raise ValueError('Could not determine the FU-stage area.')
    schnova_blocks = {'FU Stage': './i_schnova/i_fu_stage',
                      'Dispatcher': './i_schnova/i_dispatcher',
                      'FPR': './i_schnova/gen_fp_rf_i_fp_phy_regfile',
                      'GPR': './i_schnova/i_int_phy_regfile',
                      'Rename': './i_schnova/gen_rename_i_rename'}
    row1_names = list(schnova_blocks.keys())
    row1_vals = [get_area(path) for path in schnova_blocks.values()]
    rob_paths = ['./i_schnova/gen_phys_reg_manage_gen_freelist_reg_manage_i_fpr_free_list',
                 './i_schnova/gen_phys_reg_manage_gen_freelist_reg_manage_i_gpr_free_list',
                 './i_schnova/gen_phys_reg_manage_gen_freelist_reg_manage_i_rob']
    rob_areas = [get_area(path) for path in rob_paths]
    rob_area = sum(rob_areas)
    row1_names.insert(1, 'Rob')
    row1_vals.insert(1, rob_area)
    row1_rest = schnova_area - sum(row1_vals)
    if row1_rest < 0 and abs(row1_rest) < 1e-06:
        row1_rest = 0.0
    if row1_rest < 0:
        raise ValueError(f'The explicitly selected Schnova blocks exceed the total Schnova area by {-row1_rest:.2f} kGE.')  # noqa: E501
    row1_names.append('Rest')
    row1_vals.append(row1_rest)
    alu_area = area_df[area_df['path'].str.contains('gen_alus_', na=False) & area_df['path'].str.endswith('i_alu', na=False)]['area'].sum()  # noqa: E501
    fpu_area = area_df[area_df['path'].str.contains('gen_fpus_', na=False) & area_df['path'].str.endswith('_i_fpu', na=False)]['area'].sum()  # noqa: E501
    lsu_area = area_df[area_df['path'].str.contains('gen_lsus_', na=False) & area_df['path'].str.endswith('i_lsu', na=False)]['area'].sum()  # noqa: E501
    rs_area = area_df[area_df['path'].str.endswith('gen_rs_i_res_stat', na=False)]['area'].sum()  # noqa: E501
    row2_names = ['FPU', 'RSs', '3 ALUs', '3 LSUs']
    row2_vals = [fpu_area, rs_area, alu_area, lsu_area]
    print(fpu_area)
    row2_rest = fu_stage_area - sum(row2_vals)
    if row2_rest < 0 and abs(row2_rest) < 1e-06:
        row2_rest = 0.0
    if row2_rest < 0:
        raise ValueError(f'The explicitly selected FU-stage blocks exceed the total FU-stage area by {-row2_rest:.2f} kGE.')  # noqa: E501
    row2_names.append('Rest')
    row2_vals.append(row2_rest)
    row1 = AreaRow(row1_names, total_area=schnova_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row2 = AreaRow(row2_names, total_area=fu_stage_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row1.build(row1_vals, row1_names)
    row2.build(row2_vals, row2_names)
    rows = [row1, row2]
    fig, ax = plt.subplots(figsize=(10, 4), dpi=300)
    bar_height = 0.3
    row_spacing = 1.0
    label_position = 0.65
    percent_position = 0.95
    specs = [(rows[0], 0.0, None), (rows[1], row_spacing, None)]
    ax.set_xlim(0, 1)
    ax.invert_yaxis()
    ax.axis('off')
    geometry = []
    for row, y_position, offset_indices in specs:
        labels, widths, lefts, plotted_y = row.plot(ax, y_position, offset_indices=offset_indices, bar_height=bar_height, pos1=label_position, pos2=percent_position)  # noqa: E501
        geometry.append({'labels': list(labels), 'widths': list(widths), 'lefts': list(lefts), 'y': plotted_y})  # noqa: E501
    upper = geometry[0]
    lower = geometry[1]
    fu_index = upper['labels'].index('FU Stage')
    fu_left = upper['lefts'][fu_index]
    fu_right = fu_left + upper['widths'][fu_index]
    lower_left = min(lower['lefts'])
    lower_right = max((left + width for left, width in zip(lower['lefts'], lower['widths'])))  # noqa: E501
    upper_left_point = (fu_left, upper['y'] + bar_height / 2)
    upper_right_point = (fu_right, upper['y'] + bar_height / 2)
    lower_right_point = (lower_right, lower['y'] - bar_height / 2)
    lower_left_point = (lower_left, lower['y'] - bar_height / 2)
    connector_path = smooth_polygon(upper_left_point, upper_right_point, lower_right_point, lower_left_point)  # noqa: E501
    ax.add_patch(patches.PathPatch(connector_path, facecolor='gray', edgecolor='none', alpha=0.2, zorder=0))  # noqa: E501
    fig.tight_layout()
    fig.savefig('rob_core_breakdown.png', bbox_inches='tight', pad_inches=0.1, dpi=300)  # noqa: E501
    plt.show()
    return {'schnova': dict(zip(row1_names, row1_vals)), 'fu_stage': dict(zip(row2_names, row2_vals))}  # noqa: E501


def plot_schnizo_core_breakdown(dir=None):
    """Plot schnizo core breakdown."""
    name = 'Schnizo-GP-L-GRP'
    results_df = grouped_experiments.results(dir=dir)
    results_df['hierarchy_details'] = results_df['synth_results'].str['hierarchy_details']  # noqa: E501
    hierarchy = results_df['hierarchy_details'].loc[name]
    area_df = extract_hierarchy(hierarchy.tree)
    area_df['CombArea'] = area_df['CombArea'].map(to_kge)
    area_df['SeqArea'] = area_df['SeqArea'].map(to_kge)
    area_df['StdCellArea'] = area_df['StdCellArea'].map(to_kge)
    area_df['area'] = area_df['StdCellArea']

    def get_area(path):
        """Get area."""
        rows = area_df[area_df['path'] == path]
        if rows.empty:
            print(f'Warning: hierarchy path not found: {path}')
            return 0.0
        return rows['area'].iloc[0]
    schnova_area = get_area('./i_schnizo')
    fu_stage_area = get_area('./i_schnizo/i_fu_stage')
    if schnova_area <= 0:
        raise ValueError('Could not determine the Schnova area.')
    if fu_stage_area <= 0:
        raise ValueError('Could not determine the FU-stage area.')
    schnova_blocks = {'FU Stage': './i_schnizo/i_fu_stage'}
    row1_names = list(schnova_blocks.keys())
    row1_vals = [get_area(path) for path in schnova_blocks.values()]
    rf_paths = ['./i_schnizo/gen_fp_rf_i_fp_regfile', './i_schnizo/i_int_regfile']  # noqa: E501
    rf_areas = [get_area(path) for path in rf_paths]
    rf_area = sum(rf_areas)
    row1_names.insert(1, 'RF')
    row1_vals.insert(1, rf_area)
    row1_rest = schnova_area - sum(row1_vals)
    if row1_rest < 0 and abs(row1_rest) < 1e-06:
        row1_rest = 0.0
    if row1_rest < 0:
        raise ValueError(f'The explicitly selected Schnizo blocks exceed the total Schnizo area by {-row1_rest:.2f} kGE.')  # noqa: E501
    row1_names.append('Rest')
    row1_vals.append(row1_rest)
    odn_area = area_df[area_df['path'].str.contains('gen_odn_', na=False) & area_df['path'].str.endswith('xbar', na=False)]['area'].sum()  # noqa: E501
    alu_area = area_df[area_df['path'].str.contains('gen_alus_', na=False) & area_df['path'].str.endswith('i_alu', na=False)]['area'].sum()  # noqa: E501
    fpu_area = area_df[area_df['path'].str.contains('gen_fpus_', na=False) & area_df['path'].str.endswith('_i_fpu', na=False)]['area'].sum()  # noqa: E501
    lsu_area = area_df[area_df['path'].str.contains('gen_lsus_', na=False) & area_df['path'].str.endswith('i_lsu', na=False)]['area'].sum()  # noqa: E501
    rs_area = area_df[area_df['path'].str.endswith('i_fu_block', na=False)]['area'].sum()  # noqa: E501
    row2_names = ['ODN', '3 ALUs', 'FPU', '3 LSUs', 'RSs']
    row2_vals = [odn_area, alu_area, fpu_area, lsu_area, rs_area]
    print(fpu_area)
    row2_rest = fu_stage_area - sum(row2_vals)
    if row2_rest < 0 and abs(row2_rest) < 1e-06:
        row2_rest = 0.0
    if row2_rest < 0:
        raise ValueError(f'The explicitly selected FU-stage blocks exceed the total FU-stage area by {-row2_rest:.2f} kGE.')  # noqa: E501
    row2_names.append('Rest')
    row2_vals.append(row2_rest)
    row1 = AreaRow(row1_names, total_area=schnova_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row2 = AreaRow(row2_names, total_area=fu_stage_area, threshold=0.0, color_source=PULP_COLORS_BASE)  # noqa: E501
    row1.build(row1_vals, row1_names)
    row2.build(row2_vals, row2_names)
    rows = [row1, row2]
    fig, ax = plt.subplots(figsize=(10, 4), dpi=300)
    bar_height = 0.3
    row_spacing = 1.0
    label_position = 0.7
    percent_position = 1.1
    specs = [(rows[0], 0.0, [2]), (rows[1], row_spacing, [1, 3])]
    ax.set_xlim(0, 1)
    ax.invert_yaxis()
    ax.axis('off')
    geometry = []
    for row, y_position, offset_indices in specs:
        labels, widths, lefts, plotted_y = row.plot(ax, y_position, offset_indices=offset_indices, bar_height=bar_height, pos1=label_position, pos2=percent_position)  # noqa: E501
        geometry.append({'labels': list(labels), 'widths': list(widths), 'lefts': list(lefts), 'y': plotted_y})  # noqa: E501
    upper = geometry[0]
    lower = geometry[1]
    fu_index = upper['labels'].index('FU Stage')
    fu_left = upper['lefts'][fu_index]
    fu_right = fu_left + upper['widths'][fu_index]
    lower_left = min(lower['lefts'])
    lower_right = max((left + width for left, width in zip(lower['lefts'], lower['widths'])))  # noqa: E501
    upper_left_point = (fu_left, upper['y'] + bar_height / 2)
    upper_right_point = (fu_right, upper['y'] + bar_height / 2)
    lower_right_point = (lower_right, lower['y'] - bar_height / 2)
    lower_left_point = (lower_left, lower['y'] - bar_height / 2)
    connector_path = smooth_polygon(upper_left_point, upper_right_point, lower_right_point, lower_left_point)  # noqa: E501
    ax.add_patch(patches.PathPatch(connector_path, facecolor='gray', edgecolor='none', alpha=0.2, zorder=0))  # noqa: E501
    fig.tight_layout()
    fig.savefig('schnizo_core_breakdown.png', bbox_inches='tight', pad_inches=0.1, dpi=300)  # noqa: E501
    plt.show()
    return {'schnova': dict(zip(row1_names, row1_vals)), 'fu_stage': dict(zip(row2_names, row2_vals))}  # noqa: E501


def area_timing_plot(reveal_step=None, save_path=None):
    """Plot core area against achievable clock period.

    Parameters
    ----------
    reveal_step : int or None
        Number of configuration families to show. ``None`` shows all
        families. The ordered reveal is baseline, GP-ROB, GP reference
        counting, conventional OoO cores, Schnizo-GP, Schnova-LA,
        Schnizo-LA, and Spatz-LA.
    save_path : str or None
        Output path. A suitable file name is generated when omitted.
    """
    designs = {'Schnova-ZOL': {'CLK': 1.0, 'area': 129},
               'Schnizo-GP-L': {'CLK': 2.003, 'area': 1311},
               'Schnizo-LA': {'CLK': 1.108, 'area': 304},
               'CVA6S+': {'CLK': 1.164, 'area': 851},
               'C910': {'CLK': 0.757, 'area': 2674},
               'GP-FW1': {'CLK': 1.011, 'area': 194},
               'GP-FW2': {'CLK': 1.051, 'area': 345},
               'GP-FW4': {'CLK': 1.065, 'area': 464},
               'GP-FW8': {'CLK': 1.219, 'area': 589},
               'GP-FW1-ROB': {'CLK': 1.015, 'area': 330},
               'GP-FW2-ROB': {'CLK': 1.051, 'area': 439},
               'GP-FW4-ROB': {'CLK': 1.199, 'area': 674},
               'GP-FW8-ROB': {'CLK': 1.246, 'area': 815},
               'LA-FW1': {'CLK': 1.005, 'area': 182},
               'LA-FW2': {'CLK': 1.006, 'area': 245},
               'LA-FW4': {'CLK': 1.092, 'area': 342},
               'LA-FW8': {'CLK': 1.171, 'area': 543},
               'Spatz-LA': {'CLK': 1.0, 'area': 583}}
    families = [{'label': 'Schnova, scalar',
                 'names': ['Schnova-ZOL'],
                 'color': 'tab:blue',
                 'marker': 'o',
                 'connect': False},
                {'label': 'Schnova, GP, ROB',
                    'names': ['GP-FW1-ROB', 'GP-FW2-ROB', 'GP-FW4-ROB', 'GP-FW8-ROB'],
                    'color': 'tab:orange',
                    'marker': 'o',
                    'connect': True},
                {'label': 'Schnova, GP, REF-CNT',
                    'names': ['GP-FW1', 'GP-FW2', 'GP-FW4', 'GP-FW8'],
                    'color': 'tab:green', 'marker': 'o', 'connect': True},
                {'label': 'Schnova, LA', 'names': ['LA-FW1', 'LA-FW2', 'LA-FW4', 'LA-FW8'],
                    'color': 'tab:purple', 'marker': '^', 'connect': True},
                {'label': 'Schnizo, LA',
                    'names': ['Schnizo-LA'],
                    'color': 'tab:red', 'marker': '^', 'connect': False},
                {'label': 'Schnizo, GP',
                    'names': ['Schnizo-GP-L'],
                    'color': 'tab:red', 'marker': 'o', 'connect': False},
                {'label': 'CVA6S+',
                    'names': ['CVA6S+'],
                    'color': 'tab:gray', 'marker': 'o', 'connect': False},
                {'label': 'C910',
                    'names': ['C910'],
                    'color': 'tab:pink', 'marker': 'o', 'connect': False}]
    if reveal_step is None:
        active_families = families
    else:
        if not 1 <= reveal_step <= len(families):
            raise ValueError(f'reveal_step must be between 1 and {len(families)}')  # noqa: E501
        active_families = families[:reveal_step]
    fig, ax = plt.subplots(figsize=(10, 5.2))
    legend_handles = []
    for family in active_families:
        names = family['names']
        x = [designs[name]['CLK'] for name in names]
        y = [designs[name]['area'] for name in names]
        if family['connect']:
            ax.plot(x, y, color=family['color'], linewidth=1.6, alpha=0.8, zorder=2)  # noqa: E501
        ax.scatter(x, y, s=120, color=family['color'], marker=family['marker'], zorder=3)  # noqa: E501
        for name, x_pos, y_pos in zip(names, x, y):
            if 'FW' in name:
                fw = name.split('FW', 1)[1].split('-', 1)[0]
                if 'LA' in name and int(fw) == 1:
                    continue
                if reveal_step is not None and reveal_step > 5 and name not in ['GP-FW1-ROB', 'GP-FW2-ROB', 'GP-FW4-ROB', 'GP-FW8-ROB']:  # noqa: E501
                    continue
                if 'GP-FW1' == name:
                    ax.annotate(f'FW{fw}', (x_pos, y_pos), xytext=(0, -15), textcoords='offset points', fontsize=8)  # noqa: E501
                else:
                    ax.annotate(f'FW{fw}', (x_pos, y_pos), xytext=(-10, 10), textcoords='offset points', fontsize=8)  # noqa: E501
        legend_handles.append(Line2D([0], [0],
                                     color=family['color'] if family['connect'] else 'none',
                                     marker=family['marker'],
                                     markerfacecolor=family['color'],
                                     markeredgecolor=family['color'],
                                     linewidth=1.6 if family['connect'] else 0,
                                     markersize=8, label=family['label']))
    effective_step = len(families) if reveal_step is None else reveal_step
    if effective_step < 6:
        ax.set_xlim(left=0.9, right=1.3)
        ax.set_ylim(bottom=0, top=1000)
    else:
        ax.set_xlim(left=0.7, right=2.1)
        ax.set_ylim(bottom=0, top=2800)
    ax.set_xlabel('Achievable Clock Period [ns]', fontsize=12)
    ax.set_ylabel('Area [kGE]', fontsize=12)
    ax.grid(True, alpha=0.35, zorder=0)
    ax.legend(handles=legend_handles, loc='upper right', ncol=2, frameon=True, fontsize=9)  # noqa: E501
    fig.tight_layout()
    if save_path is None:
        suffix = '' if reveal_step is None else f'_step{reveal_step}'
        save_path = f'area_timing{suffix}.png'
    fig.savefig(save_path, bbox_inches='tight', pad_inches=0.1, dpi=300)
    plt.close(fig)
    print(f'Saved {save_path}')


def area_timing_plot_all_steps():
    """Generate all incremental reveal plots for presentation slides."""
    for step in range(1, 9):
        area_timing_plot(reveal_step=step)


def area_efficiency_plot_stepwise(reveal_step=None, save_path=None):
    """Plot performance against area efficiency with incremental reveals.

    Uses the same family order, colors, markers, and legend style as
    :func:`area_timing_plot`. Axis limits are left to Matplotlib.
    """
    designs = {'Schnova-ZOL': {'IPC': 0.85, 'CLK': 1.022, 'area': 129},
               'Schnizo-GP-L': {'IPC': 2.52, 'CLK': 2.003, 'area': 1311},
               'Schnizo-LA': {'IPC': 4.834, 'CLK': 1.108, 'area': 304},
               'CVA6S+': {'IPC': 2.0, 'CLK': 1.164, 'area': 851},
               'C910': {'IPC': 3.0, 'CLK': 0.757, 'area': 2674},
               'GP-FW1': {'IPC': 0.91, 'CLK': 1.011, 'area': 194},
               'GP-FW2': {'IPC': 1.64, 'CLK': 1.051, 'area': 345},
               'GP-FW4': {'IPC': 2.13, 'CLK': 1.065, 'area': 464},
               'GP-FW8': {'IPC': 2.52, 'CLK': 1.219, 'area': 589},
               'GP-FW1-ROB': {'IPC': 0.91, 'CLK': 1.015, 'area': 330},
               'GP-FW2-ROB': {'IPC': 1.64, 'CLK': 1.051, 'area': 439},
               'GP-FW4-ROB': {'IPC': 2.13, 'CLK': 1.199, 'area': 674},
               'GP-FW8-ROB': {'IPC': 2.52, 'CLK': 1.246, 'area': 815},
               'LA-FW1': {'IPC': 1.0, 'CLK': 1.005, 'area': 182},
               'LA-FW2': {'IPC': 1.77, 'CLK': 1.004, 'area': 245},
               'LA-FW4': {'IPC': 3.479, 'CLK': 1.092, 'area': 342},
               'LA-FW8': {'IPC': 4.915, 'CLK': 1.171, 'area': 543}}
    families = [
                {'label': 'Schnova, scalar',
                 'names': ['Schnova-ZOL'],
                 'color': 'tab:blue', 'marker': 'o', 'connect': False},
                {'label': 'Schnova, GP, ROB',
                 'names': ['GP-FW1-ROB', 'GP-FW2-ROB', 'GP-FW4-ROB', 'GP-FW8-ROB'],
                 'color': 'tab:orange', 'marker': 'o', 'connect': True},
                {'label': 'Schnova, GP, REF-CNT',
                 'names': ['GP-FW1', 'GP-FW2', 'GP-FW4', 'GP-FW8'],
                 'color': 'tab:green', 'marker': 'o', 'connect': True},
                {'label': 'Schnova, LA',
                 'names': ['LA-FW1', 'LA-FW2', 'LA-FW4', 'LA-FW8'],
                 'color': 'tab:purple', 'marker': '^', 'connect': True},
                {'label': 'Schnizo, LA',
                 'names': ['Schnizo-LA'],
                 'color': 'tab:red', 'marker': '^', 'connect': False},
                {'label': 'Schnizo, GP',
                 'names': ['Schnizo-GP-L'],
                 'color': 'tab:red', 'marker': 'o', 'connect': False},
                {'label': 'CVA6S+',
                 'names': ['CVA6S+'],
                 'color': 'tab:gray', 'marker': 'o', 'connect': False},
                {'label': 'C910',
                 'names': ['C910'],
                 'color': 'tab:pink', 'marker': 'o', 'connect': False}
                ]
    for d in designs.values():
        d['performance_gips'] = d['IPC'] / d['CLK']
        d['area_efficiency'] = 1000.0 * d['performance_gips'] / d['area']
    if reveal_step is None:
        active_families = families
    else:
        if not 1 <= reveal_step <= len(families):
            raise ValueError(f'reveal_step must be between 1 and {len(families)}')  # noqa: E501
        active_families = families[:reveal_step]
    fig, ax = plt.subplots(figsize=(10, 5.2))
    legend_handles = []
    for family in active_families:
        names = family['names']
        x = [designs[name]['performance_gips'] for name in names]
        y = [designs[name]['area_efficiency'] for name in names]
        if family['connect']:
            ax.plot(x, y, color=family['color'], linewidth=1.6, alpha=0.8, zorder=2)  # noqa: E501
        ax.scatter(x, y, s=120, color=family['color'], marker=family['marker'], zorder=3)  # noqa: E501
        for name, x_pos, y_pos in zip(names, x, y):
            if 'FW' in name:
                fw = name.split('FW', 1)[1].split('-', 1)[0]
                if 'LA' in name and int(fw) == 1:
                    continue
                if 'GP-FW1' == name:
                    ax.annotate(f'FW{fw}', (x_pos, y_pos), xytext=(-9, 10), textcoords='offset points', fontsize=8)  # noqa: E501
                else:
                    ax.annotate(f'FW{fw}', (x_pos, y_pos), xytext=(5, 5), textcoords='offset points', fontsize=8)  # noqa: E501
        legend_handles.append(Line2D([0], [0],
                                     color=family['color'] if family['connect'] else 'none',
                                     marker=family['marker'],
                                     markerfacecolor=family['color'],
                                     markeredgecolor=family['color'],
                                     linewidth=1.6 if family['connect'] else 0,
                                     markersize=8,
                                     label=family['label']))
    ax.set_xlabel('Performance [GIPS]', fontsize=12)
    ax.set_ylabel('Area Efficiency [MIPS/kGE]', fontsize=12)
    ax.set_xlim(left=0.5, right=4.5)
    ax.set_ylim(bottom=0, top=16)
    ax.grid(True, alpha=0.35, zorder=0)
    ax.legend(handles=legend_handles, loc='upper left', ncol=2, frameon=True, fontsize=9)  # noqa: E501
    fig.tight_layout()
    if save_path is None:
        suffix = '' if reveal_step is None else f'_step{reveal_step}'
        save_path = f'area_efficiency{suffix}.png'
    fig.savefig(save_path, bbox_inches='tight', pad_inches=0.1, dpi=300)
    plt.close(fig)
    print(f'Saved {save_path}')


def area_efficiency_plot_all_steps():
    """Generate all incremental area-efficiency reveal plots."""
    for step in range(1, 9):
        area_efficiency_plot_stepwise(reveal_step=step)


def plot1():
    """Plot1."""
    area_efficiency_plot(False)


def plot2():
    """Plot2."""
    area_efficiency_plot(True)


def plot3():
    """Plot3."""
    plot_rfcnt_core_breakdown()


def plot4():
    """Plot4."""
    plot_rob_core_breakdown()


def plot5():
    """Plot5."""
    plot_schnizo_core_breakdown()


def plot6():
    """Plot6."""
    print(results())


def plot7():
    """Plot7."""
    area_timing_plot()


def plot7_step1():
    """Plot7 step1."""
    area_timing_plot(reveal_step=1)


def plot7_step2():
    """Plot7 step2."""
    area_timing_plot(reveal_step=2)


def plot7_step3():
    """Plot7 step3."""
    area_timing_plot(reveal_step=3)


def plot7_step4():
    """Plot7 step4."""
    area_timing_plot(reveal_step=4)


def plot7_step5():
    """Plot7 step5."""
    area_timing_plot(reveal_step=5)


def plot7_step6():
    """Plot7 step6."""
    area_timing_plot(reveal_step=6)


def plot7_step7():
    """Plot7 step7."""
    area_timing_plot(reveal_step=7)


def plot7_step8():
    """Plot7 step8."""
    area_timing_plot(reveal_step=8)


def plot7_all_steps():
    """Plot7 all steps."""
    area_timing_plot_all_steps()


def plot8():
    """Plot8."""
    area_efficiency_plot_stepwise()


def plot8_step1():
    """Plot8 step1."""
    area_efficiency_plot_stepwise(reveal_step=1)


def plot8_step2():
    """Plot8 step2."""
    area_efficiency_plot_stepwise(reveal_step=2)


def plot8_step3():
    """Plot8 step3."""
    area_efficiency_plot_stepwise(reveal_step=3)


def plot8_step4():
    """Plot8 step4."""
    area_efficiency_plot_stepwise(reveal_step=4)


def plot8_step5():
    """Plot8 step5."""
    area_efficiency_plot_stepwise(reveal_step=5)


def plot8_step6():
    """Plot8 step6."""
    area_efficiency_plot_stepwise(reveal_step=6)


def plot8_step7():
    """Plot8 step7."""
    area_efficiency_plot_stepwise(reveal_step=7)


def plot8_step8():
    """Plot8 step8."""
    area_efficiency_plot_stepwise(reveal_step=8)


def plot8_all_steps():
    """Plot8 all steps."""
    area_efficiency_plot_all_steps()


def main():
    """Main."""
    plots = [plot1,
             plot2,
             plot3,
             plot4,
             plot5,
             plot6,
             plot7,
             plot7_step1,
             plot7_step2,
             plot7_step3,
             plot7_step4,
             plot7_step5,
             plot7_step6,
             plot7_step7,
             plot7_step8,
             plot7_all_steps,
             plot8,
             plot8_step1,
             plot8_step2,
             plot8_step3,
             plot8_step4,
             plot8_step5,
             plot8_step6,
             plot8_step7,
             plot8_step8,
             plot8_all_steps]
    plot_dict = {f.__name__: f for f in plots}
    parser = argparse.ArgumentParser()
    parser.add_argument('plots',
                        nargs='+',
                        choices=plot_dict.keys(),
                        default=plot_dict.keys(),
                        help='Select which plots to show (default: all)')
    args = parser.parse_args()
    for name in args.plots:
        _ = plot_dict[name]()


if __name__ == '__main__':
    main()
