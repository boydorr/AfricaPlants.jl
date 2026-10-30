#!/bin/bash -l
#
# Set up the paper's runs on an HPC, once: instantiate and precompile the package's and the paper's
# environments on the kind of node that runs them, fetch what a run downloads for itself
# (`fetch.jl`), then run the blessing test, which checks the digest of every data file and that this
# machine, with these versions, gives the blessed values. Submit from the root of the clone, once
# `transfer.txt`'s files are copied into it:
#
#     sbatch examples/paper/hpc/setup.bash
#
# The `#SBATCH` lines are for MARS's `smp` nodes and project `project0000`: edit them for yours, or
# override them on the command line. See `README.md` beside this file.

############# SLURM SETTINGS #############
#SBATCH --account=project0000     # the project the job is charged to
#SBATCH --job-name=africa-setup   # the logs are <job name>-<job ID>.out and .err
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err
#SBATCH --partition=smp           # the partition the runs use, so the compiled code suits its CPUs
#SBATCH --time=0-03:00:00         # d-hh:mm:ss
#SBATCH --mem=128G                # per node; the blessing test peaked at 62 GiB on a laptop
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16        # precompilation tasks, then the blessing test's threads

############# ENVIRONMENT #############
if [ ! -f examples/paper/hpc/env.sh ]; then
    echo "Submit this from the root of the AfricaPlants clone, not $PWD" >&2
    exit 1
fi
source examples/paper/hpc/env.sh
set -euo pipefail

# The blessing test skips itself where the data is missing, so a copy that left something out would
# pass unchecked: stop here instead.
missing=0
while read -r entry; do
    if [[ "$entry" == data/* && ! -e "$entry" ]]; then
        echo "Not copied here: $entry (see examples/paper/hpc/transfer.txt)" >&2
        missing=1
    fi
done < examples/paper/hpc/transfer.txt
[ "$missing" = 0 ] || exit 1

############# SET-UP #############
# The depot may be one other jobs set up earlier, its copy of the registry as old as theirs: one that
# does not know the manifests' versions makes the blessing test re-resolve to older ones.
julia -e 'using Pkg; Pkg.Registry.update()'
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/paper -e 'using Pkg; Pkg.instantiate()'
julia --project=examples/paper examples/paper/hpc/fetch.jl
julia --project=. -e 'using Pkg; Pkg.test(test_args = ["canonical"])'
