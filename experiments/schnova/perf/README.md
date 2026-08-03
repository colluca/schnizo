# Benchmarks for the Schnova Core

To run RTL experiments, first clean the build, runs and hw folder
Then start the experiment with the desired steps (start from hw) from the experiment folder.
```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./experiments.py --actions hw sw run roi -j
```

## Core confiugration experiments

These experiments basically run RTL experiments but for different configurations.
For example for a fetch width of one, running benchmarks for varying number of
alu slots can be done as follows
```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./pw1_experiments.py --actions hw sw run roi -j --vary alu_slots
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
