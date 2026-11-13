# Canonical tests

A canonical test records what the model produced on a fixed input and checks that it keeps producing
it: it asks *has this changed?*, where the rest of the suite asks *is this right?* The blessed values
are in `reference.toml`; the machinery is `canonical.jl`, after EcoSISTEM's `test/canonical/`.

There are two:

| test | input | runs | catches |
|---|---|---|---|
| `smoke/*`, in `runtests.jl`'s "Choosing a grid" | a synthetic pool of 20 species on WorldClim's annual mean temperature, Africa's bounding box at the coarsest grid, one year | with the unit suite, on CI too | a change in EcoSISTEM's dynamics, or its dependencies', on a fixed synthetic input |
| `chain/*`, `test_chain.jl` | the small-scale chain of one replicate (burn-in, held year, forward run, control; seed 1) on the real ERA5 months, records, widths, seeding grid and envelopes | on request, where the data is (`data/` is not in the repository, so never on CI) | a change in what a run of this package computes: layers, species, seeding, the stage scripts in `examples/paper/` |

Run the chain test, which takes some minutes:

    julia --project -e 'using Pkg; Pkg.test(test_args = ["canonical"])'

## Re-blessing

When a change is meant to move what the model computes, bless the new values:

    AFRICA_BLESS=true julia --project -e 'using Pkg; Pkg.test(test_args = ["canonical"])'
    AFRICA_BLESS=true julia --project -e 'using Pkg; Pkg.test()'

The first blesses `chain/*`, the second `smoke/*`; the file is merged, so each leaves the other's
values alone. The diff to `reference.toml` is the statement of what the change did, and is reviewed
with the code: did exactly what was expected move, and nothing else?

**Re-blessing is never a way to make a failing test pass.** A value that moves must be explained
before it is blessed. Two things move values without the model changing:

- **The data.** `chain/input/*` blesses the SHA-256 of every table the drivers read and one digest
  over the ERA5 files' contents (not their names). If an output moved and an input did too, the data
  changed. EarthEnv's land cover and Natural Earth's outline, which EcoSISTEM fetches itself, are not
  digested.
- **A dependency.** A different sampler draws the same seed differently, so absolute counts
  (`individuals`, `species_end`, `by_species`) move while counts of what survives and where
  (`surviving_end`, `occupied_end`, `surviving`, `occupied_cells`) usually do not; holding the
  dependency at its old version in a scratch environment and rerunning settles it. The chain runs
  its stages in the paper's environment, `examples/paper/`, as a job does, so it is that manifest's
  versions that count there. No manifest is committed, so CI resolves the newest compatible
  versions: a `smoke/*` failure on CI with none locally means a dependency moved.

An unblessed key is reported as broken, not failed. The tolerance is `rtol = 1e-8`; strings (the
digests) must match exactly.

What each cannot see. In the smoke run every active cell stays occupied, so its cell counts cannot
move and `by_species` carries the check. In the small chain the forward run is one year, and that
year's climate is 1940's, so the forward run and its control are identical: a change confined to how
the climate changes through time needs the medium scale.
