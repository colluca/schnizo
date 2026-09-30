# Schnova experiments

## Performance experiments

```bash
cd ./experiments/schnova/
./perf_experiments.py --actions hw sw run roi -j
```

## Core area experiments

```bash
make nonfree
make cockpit
cd experiments/schnova/
./core_area_experiments.py --actions synth -j
```

To run the experiments on a server, just SSH to a server.
Then cd to the `/usr/scratch/...` folder hosting your repo.
Then prefix all Python commands using `uv run` so that paths are resolved correctly.
