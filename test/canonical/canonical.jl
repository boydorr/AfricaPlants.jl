# SPDX-License-Identifier: LGPL-3.0-or-later
#
# The blessing machinery the canonical tests share, after EcoSISTEM's `test/canonical/canonical.jl`.
# See README.md in this directory for what a canonical test is for and how to re-bless one.

module Canonical

using Test
using TOML

export canonical, blessing

# Where the blessed values live: one file, so that a re-blessing is one reviewable diff.
const REFERENCE = joinpath(@__DIR__, "reference.toml")

"""
    blessing()

Return whether this is a re-blessing run, `AFRICA_BLESS=true`, in which the canonical tests record
what they produce instead of checking it.
"""
blessing() = get(ENV, "AFRICA_BLESS", "false") == "true"

# The blessed values, read once, or an empty dict before anything is blessed.
const _CACHE = Ref{Union{Nothing, Dict{String, Any}}}(nothing)
function _reference()
    isnothing(_CACHE[]) &&
        (_CACHE[] = isfile(REFERENCE) ? TOML.parsefile(REFERENCE) :
                    Dict{String, Any}())
    return _CACHE[]
end

# A value as TOML holds it: a real or an array of reals as floats, or a string such as a file's
# digest. A `Quantity` is refused, so that the unit a blessed number is in is stated at the call site.
function _plain(name, value)
    value isa Real && return float(value)
    value isa AbstractArray{<:Real} && return float.(collect(value))
    value isa AbstractString && return String(value)
    return error("canonical value `$name` is a $(typeof(value)); a blessed value must be a real, " *
                 "an array of reals or a string. Strip a unit explicitly - `ustrip(K, x)` - so " *
                 "that the reference records which unit it is in.")
end

"""
    canonical(name, value; rtol = 1e-8)

Check `value` against the value blessed as `name` in `reference.toml`, or record it there when
re-blessing. `value` is a real, an array of reals or a string; a string is checked exactly. An
unblessed `name` is reported as broken rather than failed. `rtol` is tight because the test exists
to notice change: widen it only where a value is genuinely reproducible to fewer digits, and say why
at the call site.
"""
function canonical(name::AbstractString, value; rtol = 1e-8)
    key = String(name)
    plain = _plain(key, value)
    if blessing()
        _writethrough(key, plain)
        return @test true
    end
    ref = _reference()
    if !haskey(ref, key)
        @info "canonical value `$key` is not blessed: rerun with AFRICA_BLESS=true"
        return @test_broken false
    end
    same = plain isa String ? plain == ref[key] :
           isapprox(plain, ref[key], rtol = rtol)
    same ||
        @error "canonical value `$key` differs from its blessed value" value=plain blessed=ref[key]
    return @test same
end

# Merge one value into the reference file as it is blessed, so that a run blessing only some keys
# keeps the rest. Keys are sorted by `TOML.print` itself, so adding one moves no other line.
function _writethrough(key, plain)
    merged = merge(_reference(), Dict(key => plain))
    _CACHE[] = merged
    open(REFERENCE, "w") do io
        println(io,
                "# Blessed canonical values - regenerate with AFRICA_BLESS=true, and read")
        println(io,
                "# test/canonical/README.md before committing a change to this file.")
        return TOML.print(io, merged, sorted = true)
    end
    return nothing
end

end
