# The settings every job of the paper's run on an HPC shares, for `setup.bash` and `run.bash`, which
# source it from the root of the clone. Source it yourself to use the same Julia and depot by hand:
#
#     source examples/paper/hpc/env.sh
#
# The first two can be set beforehand, in `~/.bashrc` say, rather than edited here, so that the clone
# stays as it was committed.

# Where everything large lives: the Julia depot, with EcoSISTEM's cache of the layers it fetches and
# of the aggregates it builds from them, and the runs. On MARS, project storage: home's quota would
# not hold them.
export AFRICA_HPC_ROOT="${AFRICA_HPC_ROOT:-/mnt/data/project0000/$USER}"
# The juliaup channel to run, as `juliaup add` named it: `juliaup add 1.13.3` makes `1.13.3`.
export JULIAUP_CHANNEL="${JULIAUP_CHANNEL:-1.13.3}"
# The port the local registry listens on. Not 8000: a node is shared, and another user's server
# there would stop the registry starting. `fair` keeps one local registry for each user, so this and
# the registry's directory below must be what any other set-up on the account gave it: EcoSISTEM's
# paper set-up uses the same.
export AFRICA_HPC_PORT="${AFRICA_HPC_PORT:-8030}"

# MARS provides juliaup as a module; elsewhere it is expected on the path already.
if type module > /dev/null 2>&1; then
    module load apps/juliaup/1.18.9
fi

# The trailing colon keeps Julia's own depots after this one, or every standard library recompiles.
export JULIA_DEPOT_PATH="$AFRICA_HPC_ROOT/julia:"
# Where `fair registry install` puts the registry; once `fair init` has run, its configuration says.
export FAIR_REGISTRY_DIR="$AFRICA_HPC_ROOT/fair/registry"
# The local registry is reached directly, never through a web proxy: MARS sets `http_proxy` on every
# node, and `fair` then takes the proxy's answer for another registry's and will not start its own.
export no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
# Where a run writes, unless the job is given somewhere else.
export AFRICA_SAVEDIR="${AFRICA_SAVEDIR:-$AFRICA_HPC_ROOT/runs}"
# A compute node has no display: GR draws the figures without one.
export GKSwstype=100
# Keep threaded system libraries to one thread each, under Julia's own threads.
export OMP_NUM_THREADS=1
# Inside a job, as many Julia threads, and precompilation tasks, as cores were allocated.
if [ -n "${SLURM_CPUS_PER_TASK:-}" ]; then
    export JULIA_NUM_THREADS="$SLURM_CPUS_PER_TASK"
    export JULIA_NUM_PRECOMPILE_TASKS="$SLURM_CPUS_PER_TASK"
fi
