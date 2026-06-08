# Benchmarks for the Schnova Core

To run RTL experiments, first clean the build, runs and hw folder
Then start the experiment with the desired steps (start from hw) from the experiment folder.
```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./experiments.py --actions hw sw run roi -j
```
## Allocation metrics
1. Make sure to use enough slots, physcial registers and ROB entries
1. Tests were run with 32 ALU/LSU slots, 64 FPU slots, 128 ROB entries, 128 physical registers
1. Run the experiments like normal with the alloc flag

```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./experiments.py --actions hw sw run roi alloc -j
```

## Power

To do Power measurements, first clean the build, runs and hw  folde
Then just start the followign flow

```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./experiments.py --actions pln hw sw run roi pl-hw vcd power
```

Note the pln runs the entire backend for all the hardware configurations defined in the experiments
this can take quite some time.

A manual process is explained in the Snitch tutorial.
