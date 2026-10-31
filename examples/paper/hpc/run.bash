#!/bin/bash -l
#
# One stage of the paper's runs as a job on one node, threaded, configured by the `AFRICA_*`
# variables of the shell it is submitted from, which `sbatch` passes on. Named by its pipeline
# config, the stage is a data pipeline run, its outputs registered in the local registry, which the
# job starts and stops; named by its script, it is a plain run. Submit from the root of the clone,
# once `setup.bash` has run:
#
#     AFRICA_CELLSIZE=50km sbatch examples/paper/hpc/run.bash examples/paper/burnin.yaml
#     AFRICA_CELLSIZE=50km AFRICA_NEUTRAL=true sbatch examples/paper/hpc/run.bash examples/paper/forward.yaml
#     AFRICA_CELLSIZE=25km sbatch examples/paper/hpc/run.bash examples/paper/burnin.jl
#
# A pipeline run records the commit it ran: the clone must be clean and its commit pushed.
#
# A stage at a time: `examples/paper.jl` runs two in one process, which holds the burn-in's whole
# ecosystem through the forward run, an abundance array and its layers more than either needs.
#
# Always name the cell size: left to choose, a run given a whole node picks a grid finer than the
# node holds, since the choice counts three `species x cells` arrays and a run that records
# diversity holds about five. Every five minutes the job adds Slurm's measure of its memory so far
# to `<job name>-<job ID>.memory` beside its logs, which stays when the job is killed for time or
# memory. The versions it ran with are kept there too, as `<job name>-<job ID>.Manifest.toml`.
#
# The `#SBATCH` lines are for MARS's `smp` nodes and project `project0000`: edit them for yours, or
# override them on the command line. See `README.md` beside this file.

############# SLURM SETTINGS #############
#SBATCH --account=project0000     # the project the job is charged to
#SBATCH --job-name=africa         # the logs are <job name>-<job ID>.out and .err
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
#SBATCH --partition=smp           # one node of 128 cores and 1 TB
#SBATCH --time=2-00:00:00         # d-hh:mm:ss; 7 days at most on `smp`
#SBATCH --mem=400G                # per node; about 55 GB at 50 km, scaling with the cells
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=128       # Julia threads
#SBATCH --threads-per-core=1
#SBATCH --dependency=singleton    # one job of a name at a time: the registry runs on one node at a time

############# ENVIRONMENT #############
if [ ! -f examples/paper/hpc/env.sh ]; then
    echo "Submit this from the root of the AfricaPlants clone, not $PWD" >&2
    exit 1
fi
source examples/paper/hpc/env.sh
set -euo pipefail

############# THE RUN #############
stage="${1:?name the stage to run, such as examples/paper/burnin.yaml}"
logs="${SLURM_JOB_NAME:-africa}-${SLURM_JOB_ID:-local}"

# Brings the environment into line with the clone, should it have moved since `setup.bash`, keeping
# the manifest's versions where it can, and keeps the versions it resolved beside the logs: the
# manifest is not part of the repository.
julia --project=examples/paper -e 'using Pkg; Pkg.resolve(); Pkg.instantiate()'
cp examples/paper/Manifest.toml "$logs.Manifest.toml"

echo "$stage, $(date -u +%FT%TZ), on $(hostname)"
env | grep '^AFRICA_' | sort

if [ -n "${SLURM_JOB_ID:-}" ] && command -v sstat > /dev/null; then
    # A batch job's figures are under `.batch`: `sstat -j <id>` alone answers blank.
    while sleep 300; do
        echo "$(date -u +%FT%TZ) $(sstat --noheader --parsable2 \
            --format=MaxRSS,AveRSS -j "$SLURM_JOB_ID.batch")"
    done >> "$logs.memory" &
    trap "kill $! 2> /dev/null" EXIT
fi

case "$stage" in
*.yaml)
    # `pull` takes `--local`, or it would look the namespace up in the remote registry; `run` does
    # not, so that it checks the commit is on the clone's remote.
    julia --project=examples/paper -e '
        using DataPipeline
        config = only(ARGS)
        fair"registry start"
        try
            fair"pull --local $config"
            fair"run $config"
        finally
            fair"registry stop"
        end' "$stage"
    ;;
*)
    julia --project=examples/paper "$stage"
    ;;
esac
