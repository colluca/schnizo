# Benchmarks for the Schnova Core

To run RTL experiments, first clean the build, runs and hw folder
Then start the experiment with the desired steps (start from hw) from the experiment folder.
```
cd ./experiments/schnova/perf/
source clean_experiments.sh
./experiments.py --actions hw sw run roi -j
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
