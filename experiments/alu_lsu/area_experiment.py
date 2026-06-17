#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import json
import math
import os
import re
import shlex
import shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import pandas as pd

from snitch.util.experiments import common, experiment_utils as eu
from snitch.util.experiments import run


SCRATCH_BASE = Path("/scratch/sem26f5/cache")
CACHE_LINK_ROOT = Path("synth_caches")
GE_AREA = 0.121

EARLY_SYNTH_STAGE = "6"
FINAL_SYNTH_STAGE = "9"

ALU = "schnizo_alu_synth"
LSU = "schnizo_lsu_synth"
ALU_LSU = "schnizo_alu_lsu_synth"
RES_STAT = "schnizo_res_stat_synth"
FU_STAGE = "schnizo_fu_stage_synth"
SCHNIZO = "schnizo_synth"


def clean_name(value):
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value))
    return re.sub(r"_+", "_", value).strip("_")


def verilog_params(params):
    return {key: int(value) if isinstance(value, bool) else value for key, value in params.items()}


def exp(name, design, params=None, sweep=None, **meta):
    name = clean_name(name)
    return {
        "name": name,
        "config": name,
        "design": design,
        "hdl_params": verilog_params(params or {}),
        "sweep": sweep or name,
        **meta,
    }


def fu_stage_separate(slots):
    return {
        "AluNofRss": slots,
        "AluNofConstants": slots,
        "LsuNofRss": slots,
        "LsuNofConstants": 2 * slots,
        "AluLsuNofRsis": 0,
        "AluLsuNofRsrs": 0,
        "AluLsuNofConstants": 0,
        "FpuNofRss": slots,
        "FpuNofConstants": 2 * slots,
    }


def fu_stage_combined(issue_slots, result_slots, constants, res_ports=1, postinc=False):
    return {
        "UseAluLsu": True,
        "PostIncrement": postinc,
        "NofAlus": 0,
        "NofLsus": 0,
        "NofAluLsus": 3,
        "AluLsuNofRsis": issue_slots,
        "AluLsuNofRsrs": result_slots,
        "FpuNofRss": result_slots // 2,
        "AluLsuNofConstants": constants,
        "FpuNofConstants": result_slots,
        "AluLsuNofResPorts": res_ports,
    }


def schnizo_separate(alu_slots, lsu_slots, fpu_slots, alu_const, lsu_const, fpu_const):
    return {
        "UseAluLsu": False,
        "AluNofRss": alu_slots,
        "LsuNofRss": lsu_slots,
        "AluLsuNofRsis": 0,
        "AluLsuNofRsrs": 0,
        "FpuNofRss": fpu_slots,
        "AluNofConstants": alu_const,
        "LsuNofConstants": lsu_const,
        "AluLsuNofConstants": 0,
        "FpuNofConstants": fpu_const,
    }


def schnizo_combined(issue_slots, result_slots, fpu_slots, constants,
                     fpu_const, res_ports=1, postinc=False):
    return {
        "UseAluLsu": True,
        "PostIncrement": postinc,
        "NofAlus": 0,
        "NofLsus": 0,
        "NofAluLsus": 3,
        "AluNofRss": 0,
        "LsuNofRss": 0,
        "AluLsuNofRsis": issue_slots,
        "AluLsuNofRsrs": result_slots,
        "FpuNofRss": fpu_slots,
        "AluNofConstants": 0,
        "LsuNofConstants": 0,
        "AluLsuNofConstants": constants,
        "FpuNofConstants": fpu_const,
        "AluLsuNofResPorts": res_ports,
    }


def res_stat_params(issue, result, constants, operands, consumers, res_ports=1,
                    two_dests=False, use_64bit=True):
    return {
        "NofRsis": issue,
        "NofRsrs": result,
        "NofConstants": constants,
        "NofOperands": operands,
        "NofResRspIfs": 2,
        "ConsumerCount": consumers,
        "NofResPorts": res_ports,
        "HasTwoDests": two_dests,
        "UseSram": False,
        "Use64bit": use_64bit,
    }


def gen_fu_experiments():
    experiments = [
        exp("alu_base", ALU, {"HasBranch": False, "HasMultiplier": False}, sweep="single_fu"),
        exp("alu_branch_mul", ALU, {"HasBranch": True, "HasMultiplier": True}, sweep="single_fu"),
        exp("lsu_base", LSU, sweep="single_fu"),
    ]

    for ports in [1, 2]:
        for postinc in [False, True]:
            for branch_mul in [False, True]:
                suffix = f"rp{ports}"
                if branch_mul:
                    suffix += "_branch_mul"
                if postinc:
                    suffix += "_postinc"

                experiments.append(
                    exp(
                        f"alu_lsu_{suffix}",
                        ALU_LSU,
                        {
                            "NofResPorts": ports,
                            "HasBranch": branch_mul,
                            "HasMultiplier": branch_mul,
                            "PostIncrement": postinc,
                        },
                        sweep="single_fu",
                    )
                )

    return experiments


def gen_res_stat_experiments():
    experiments = []

    for x in [2, 4, 8, 16]:
        cases = [
            ("alu", "alu_x_issue_x_result", x, x, x, 2, x * 18,
             1, False, False, "3alu_3lsu_1fpu"),
            ("lsu", "lsu_x_issue_x_result", x, x, 2 * x, 3, x * 18,
             1, False, True, "3alu_3lsu_1fpu"),
            ("alu_lsu_X2X", "combined_x_issue_2x_result", x, 2 * x, 2 * x,
             3, x * 12, 1, False, True, "3alu_lsu_1fpu"),
            ("alu_lsu_X2X_2D", "combined_x_issue_2x_result_2D", x, 2 * x, 2 * x,
             3, x * 12, 1, True, True, "3alu_lsu_1fpu"),
            ("alu_lsu_X2X_2R", "combined_x_issue_2x_result_2R", x, 2 * x, 2 * x,
             3, x * 12, 2, False, True, "3alu_lsu_1fpu"),
            ("alu_lsu_X2X_2D_2R", "combined_x_issue_2x_result_2R_2D", x, 2 * x, 2 * x,
             3, x * 12, 2, True, True, "3alu_lsu_1fpu"),
            ("alu_lsu_2X2X", "combined_2x_issue_2x_result", 2 * x, 2 * x, 4 * x,
             3, x * 21, 1, False, True, "3alu_lsu_1fpu"),
        ]

        for (sweep, name, issue, result, const, operands,
             consumers, ports, two_dests, use_64bit, units) in cases:
            experiments.append(
                exp(
                    f"{name}_x{x}",
                    RES_STAT,
                    res_stat_params(issue, result, const, operands,
                                    consumers, ports, two_dests, use_64bit),
                    sweep=sweep,
                    x=x,
                    issue_slots=issue,
                    result_slots=result,
                    logical_units=units,
                )
            )

    return experiments


def gen_fu_stage_experiments():
    experiments = []
    variants = [
        ("combined_iso_result_capacity", "combined", 2, 2, 4, 1, False),
        ("combined_half_issue_postinc", "postinc", 1, 2, 2, 2, True),
        ("combined_half_issue", "half_issue", 1, 2, 2, 1, False),
        ("combined_half_issue_2dest", "half_issue_2dest", 1, 2, 2, 1, True),
        ("combined_half_issue_2res", "half_issue_2res", 1, 2, 2, 2, False),
    ]

    for x in [16, 8, 4, 2]:
        experiments.append(
            exp(
                f"separate_units_x{x}",
                FU_STAGE,
                fu_stage_separate(x),
                sweep="separate",
                x=x,
                notes="Separate ALU, LSU, and FPU reservation stations.",
            )
        )

        for name, sweep, issue_mul, result_mul, const_mul, ports, postinc in variants:
            experiments.append(
                exp(
                    f"{name}_x{x}",
                    FU_STAGE,
                    fu_stage_combined(issue_mul * x, result_mul * x, const_mul * x, ports, postinc),
                    sweep=sweep,
                    x=x,
                )
            )

    return experiments


def gen_schnizo_experiments():
    experiments = []

    for x in [2, 4, 8, 16]:
        experiments += [
            exp(
                f"separate_x{x}",
                SCHNIZO,
                schnizo_separate(x, x, x, x, 2 * x, 2 * x),
                sweep="separate",
                x=x,
                notes="Baseline Schnizo with separate ALUs, LSUs, and FPU.",
            ),
            exp(
                f"combined_x{x}",
                SCHNIZO,
                schnizo_combined(2 * x, 2 * x, x, 4 * x, 2 * x, res_ports=1, postinc=False),
                sweep="combined",
                x=x,
            ),
            exp(
                f"postinc_x{x}",
                SCHNIZO,
                schnizo_combined(x, 2 * x, x, 2 * x, 2 * x, res_ports=2, postinc=True),
                sweep="postinc",
                x=x,
            ),
        ]

    return experiments


EXPERIMENTS = {
    "fu": gen_fu_experiments,
    "res_stat": gen_res_stat_experiments,
    "fu_stage": gen_fu_stage_experiments,
    "schnizo": gen_schnizo_experiments,
}


def create_bender_wrapper():
    wrapper = Path.cwd() / CACHE_LINK_ROOT / "bender_wrapper.sh"
    snitch_root = find_repo_root()
    bender = os.environ.get("SN_BENDER", "bender")
    wrapper.parent.mkdir(exist_ok=True)
    wrapper.write_text(
        "#!/bin/bash\n"
        f"exec {shlex.quote(bender)} -d {shlex.quote(str(snitch_root))} \"$@\"\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    os.environ["SN_BENDER"] = str(wrapper)


def find_repo_root():
    starts = [Path(__file__).resolve().parent, Path.cwd().resolve()]

    for start in starts:
        for path in [start, *start.parents]:
            if (path / "Bender.yml").is_file():
                return path

    raise RuntimeError(
        "Could not find Bender.yml. Run this script from inside the repo, "
        "or place it somewhere below the repo root."
    )


def setup_scratch_cache(name):
    local_root = Path.cwd() / CACHE_LINK_ROOT
    link = local_root / name
    scratch = SCRATCH_BASE / name

    local_root.mkdir(exist_ok=True)
    scratch.mkdir(parents=True, exist_ok=True)

    if link.exists() and not link.is_symlink():
        shutil.copytree(link, scratch, dirs_exist_ok=True)
        shutil.rmtree(link)
    if link.is_symlink() or link.exists():
        link.unlink()

    link.symlink_to(scratch, target_is_directory=True)
    return str(CACHE_LINK_ROOT / name)


def synth_target(actions):
    actions = actions or []
    if "synth" in actions or "all" in actions:
        return "synth"
    if "fast_synth" in actions:
        return "fast_synth"
    if "elab" in actions:
        return "elab"
    return None


def result_stage(args):
    if args.final_stage is not None:
        return str(args.final_stage)
    return EARLY_SYNTH_STAGE if synth_target(args.actions) == "fast_synth" else FINAL_SYNTH_STAGE


def hdl_params(params):
    return ":".join(f"{key}={value}" for key, value in params.items())


class ExperimentManager(eu.ExperimentManager):
    def derive_axes(self, experiment):
        return eu.derive_axes_from_keys(experiment, keys=["config"])

    def run(self):
        target = synth_target(self.actions)
        if target is None:
            super().run()
            return

        create_bender_wrapper()

        def run_one(experiment):
            synth_dir = Path(experiment["synth_dir"])
            (synth_dir / "tmp").mkdir(parents=True, exist_ok=True)
            print(f"--- Running {target}: {experiment['name']} ---")
            common.make(
                target=target,
                vars={
                    "DESIGN": experiment["design"],
                    "HDL_PARAMS": hdl_params(experiment["hdl_params"]),
                    "RUNDIR": str(synth_dir),
                },
                sync=True,
            )

        with ThreadPoolExecutor(max_workers=getattr(self.args, "n_procs", 1)) as executor:
            for _ in executor.map(run_one, self.experiments):
                pass


def area_kge(area):
    try:
        return float(area) / GE_AREA / 1000.0
    except Exception:
        return math.nan


def select_experiments(experiments, sweep=None, case=None):
    if sweep:
        experiments = [experiment for experiment in experiments if experiment["sweep"] == sweep]
    if case:
        experiments = [experiment for experiment in experiments if experiment["name"] == case]
    if not experiments:
        raise RuntimeError("No experiments selected.")
    return experiments


def check_experiments(experiments):
    names = [experiment["name"] for experiment in experiments]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise RuntimeError(f"Duplicate experiment names: {', '.join(duplicates)}")


def get_results(manager, experiments, stage):
    synth_results_cls = getattr(eu, "SynthResults", None)
    if synth_results_cls is None:
        df = manager.get_results()
    else:
        rows = []
        for experiment in manager.experiments:
            row = experiment["axes"].copy()
            try:
                row["synth_results"] = synth_results_cls(experiment["synth_dir"])
            except FileNotFoundError:
                row["synth_results"] = {}
            rows.append(row)
        df = pd.DataFrame(rows)

    by_config = {experiment["config"]: experiment for experiment in experiments}
    summary = []

    for _, row in df.iterrows():
        experiment = by_config[row["config"]]
        params = experiment["hdl_params"]
        qor = row.get("synth_results", {}).get(stage, {}).get("qor_summary", {})
        area = qor.get("StdCellArea", math.nan)

        summary.append(
            {
                "name": experiment["name"],
                "design": experiment["design"],
                "sweep": experiment["sweep"],
                "parameters": json.dumps(params, sort_keys=True),
                "StdCellArea": area,
                "AreaKGE": area_kge(area),
                "WNS": qor.get("WNS", math.nan)
            }
        )

    return pd.DataFrame(summary)


def print_experiments(experiments):
    columns = ["name", "design", "sweep", "x", "notes"]
    df = pd.DataFrame(experiments)
    columns = [column for column in columns if column in df.columns]
    print(df[columns].to_string(index=False))


def main():
    parser = run.get_parser()
    parser.add_argument("--actions", nargs="+", default=[], choices=eu.ACTIONS)
    parser.add_argument("--clean", nargs="+", default=[], choices=eu.CLEAN_ACTIONS)
    parser.add_argument("--experiment", required=True, choices=sorted(EXPERIMENTS))
    parser.add_argument("--sweep")
    parser.add_argument("--case")
    parser.add_argument("--final-stage", default=None)
    args = parser.parse_args()

    experiments = select_experiments(EXPERIMENTS[args.experiment](), args.sweep, args.case)
    check_experiments(experiments)

    print_experiments(experiments)
    synth_name = setup_scratch_cache(args.experiment)
    manager = ExperimentManager(experiments=experiments, args=args,
                                parse_args=False, synth_name=synth_name)

    results_dir = Path("results") / f"results_{args.experiment}"
    results_dir.mkdir(parents=True, exist_ok=True)

    if args.dry_run:
        pd.DataFrame(experiments).to_csv(results_dir / "summary_dry_run.csv", index=False)
        return

    manager.run()
    df = get_results(manager, experiments, result_stage(args))
    df.to_csv(results_dir / "summary.csv", index=False)
    print(f"Wrote {results_dir / 'summary.csv'}")


if __name__ == "__main__":
    main()
