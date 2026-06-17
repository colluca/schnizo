To verify all kernels (recommended):

./experiments.py --clean hw sw verify --actions hw sw verify traces annotate perf roi -j --run-dir verifications

To generate area experiment e.g.:

./area_experiment.py --actions synth --experiment fu_stage -j 4

available experiments: fu, res_stat, fu_stage, schnizo
actions: synth, fast_synth, (elab)