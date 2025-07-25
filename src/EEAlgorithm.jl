# Use these constants whenever we need to set a large value for the distance or
# metric distance
const large_distance = 16.0 # = 4^2
const large_dij = 1.0e6

"""
    angular_distance(eereco, i, j) -> Float64

Calculate the angular distance between two jets `i` and `j` using the formula
``1 - cos(θ_{ij})``.

# Arguments
- `eereco`: The array of `EERecoJet` objects.
- `i`: The first jet.
- `j`: The second jet.

# Returns
- `Float64`: The angular distance between `i` and `j`, which is ``1 -
  cos\theta``.
"""
@inline function angular_distance(eereco, i, j)
    @inbounds @muladd 1.0 - eereco[i].nx * eereco[j].nx - eereco[i].ny * eereco[j].ny -
                      eereco[i].nz * eereco[j].nz
end

"""
    dij_dist(eereco, i, j, dij_factor)

Calculate the dij distance between two ``e^+e^-``jets.

# Arguments
- `eereco`: The array of `EERecoJet` objects.
- `i`: The first jet.
- `j`: The second jet.
- `dij_factor`: The scaling factor to multiply the dij distance by.

# Returns
- The dij distance between `i` and `j`.
"""
@inline function dij_dist(eereco, i, j, dij_factor)
    # Calculate the dij distance for jet i from jet j
    j == 0 && return large_dij
    @inbounds min(eereco[i].E2p, eereco[j].E2p) * dij_factor * eereco[i].nndist
end

function get_angular_nearest_neighbours!(eereco, algorithm, dij_factor)
    # Get the initial nearest neighbours for each jet
    N = length(eereco)
    # this_dist_vector = Vector{Float64}(undef, N)
    # Nearest neighbour geometric distance
    @inbounds for i in 1:N
        # TODO: Replace the 'j' loop with a vectorised operation over the appropriate array elements?
        # this_dist_vector .= 1.0 .- eereco.nx[i:N] .* eereco[i + 1:end].nx .-
        #     eereco[i].ny .* eereco[i + 1:end].ny .- eereco[i].nz .* eereco[i + 1:end].nz
        # The problem here will be avoiding allocations for the array outputs, which would easily
        # kill performance
        @inbounds for j in (i + 1):N
            this_nndist = angular_distance(eereco, i, j)

            # Using these ternary operators is faster than the if-else block
            better_nndist_i = this_nndist < eereco[i].nndist
            eereco.nndist[i] = better_nndist_i ? this_nndist : eereco.nndist[i]
            eereco.nni[i] = better_nndist_i ? j : eereco.nni[i]
            better_nndist_j = this_nndist < eereco[j].nndist
            eereco.nndist[j] = better_nndist_j ? this_nndist : eereco.nndist[j]
            eereco.nni[j] = better_nndist_j ? i : eereco.nni[j]
        end
    end
    # Nearest neighbour dij distance
    for i in 1:N
        eereco.dijdist[i] = dij_dist(eereco, i, eereco[i].nni, dij_factor)
    end
    # For the EEKt algorithm, we need to check the beam distance as well
    # (This is structured to only check for EEKt once)
    if algorithm == JetAlgorithm.EEKt
        @inbounds for i in 1:N
            beam_closer = eereco[i].E2p < eereco[i].dijdist
            eereco.dijdist[i] = beam_closer ? eereco[i].E2p : eereco.dijdist[i]
            eereco.nni[i] = beam_closer ? 0 : eereco.nni[i]
        end
    end
end

# Update the nearest neighbour for jet i, w.r.t. all other active jets
function update_nn_no_cross!(eereco, i, N, algorithm, dij_factor)
    eereco.nndist[i] = large_distance
    eereco.nni[i] = i
    @inbounds for j in 1:N
        if j != i
            this_nndist = angular_distance(eereco, i, j)
            better_nndist_i = this_nndist < eereco[i].nndist
            eereco.nndist[i] = better_nndist_i ? this_nndist : eereco.nndist[i]
            eereco.nni[i] = better_nndist_i ? j : eereco.nni[i]
        end
    end
    eereco.dijdist[i] = dij_dist(eereco, i, eereco[i].nni, dij_factor)
    if algorithm == JetAlgorithm.EEKt
        beam_close = eereco[i].E2p < eereco[i].dijdist
        eereco.dijdist[i] = beam_close ? eereco[i].E2p : eereco.dijdist[i]
        eereco.nni[i] = beam_close ? 0 : eereco.nni[i]
    end
end

function update_nn_cross!(eereco, i, N, algorithm, dij_factor)
    # Update the nearest neighbour for jet i, w.r.t. all other active jets
    # also doing the cross check for the other jet
    eereco.nndist[i] = large_distance
    eereco.nni[i] = i
    @inbounds for j in 1:N
        if j != i
            this_nndist = angular_distance(eereco, i, j)
            better_nndist_i = this_nndist < eereco[i].nndist
            eereco.nndist[i] = better_nndist_i ? this_nndist : eereco.nndist[i]
            eereco.nni[i] = better_nndist_i ? j : eereco.nni[i]
            if this_nndist < eereco[j].nndist
                eereco.nndist[j] = this_nndist
                eereco.nni[j] = i
                # j will not be revisited, so update metric distance here
                eereco.dijdist[j] = dij_dist(eereco, j, i, dij_factor)
                if algorithm == JetAlgorithm.EEKt
                    if eereco[j].E2p < eereco[j].dijdist
                        eereco.dijdist[j] = eereco[j].E2p
                        eereco.nni[j] = 0
                    end
                end
            end
        end
    end
    eereco.dijdist[i] = dij_dist(eereco, i, eereco[i].nni, dij_factor)
    if algorithm == JetAlgorithm.EEKt
        beam_close = eereco[i].E2p < eereco[i].dijdist
        eereco.dijdist[i] = beam_close ? eereco[i].E2p : eereco.dijdist[i]
        eereco.nni[i] = beam_close ? 0 : eereco.nni[i]
    end
end

function ee_check_consistency(clusterseq, eereco, N)
    # Check the consistency of the reconstruction state
    for i in 1:N
        if eereco[i].nni > N
            @error "Jet $i has invalid nearest neighbour $(eereco[i].nni)"
        end
        for i in 1:N
            jet = clusterseq.jets[eereco[i].index]
            jet_hist = clusterseq.history[jet._cluster_hist_index]
            if jet_hist.child != Invalid
                @error "Jet $i has invalid child $(jet_hist.child)"
            end
        end
    end
    @debug "Consistency check passed at $msg"
end

function fill_reco_array!(eereco, particles, R2, p)
    for i in eachindex(particles)
        eereco.index[i] = i
        eereco.nni[i] = 0
        eereco.nndist[i] = R2
        # eereco.dijdist[i] = UNDEF # Does not need to be initialised
        eereco.nx[i] = nx(particles[i])
        eereco.ny[i] = ny(particles[i])
        eereco.nz[i] = nz(particles[i])
        eereco.E2p[i] = energy(particles[i])^(2p)
    end
end

@inline function insert_new_jet!(eereco, i, newjet_k, R2, merged_jet, p)
    eereco.index[i] = newjet_k
    eereco.nni[i] = 0
    eereco.nndist[i] = R2
    eereco.nx[i] = nx(merged_jet)
    eereco.ny[i] = ny(merged_jet)
    eereco.nz[i] = nz(merged_jet)
    eereco.E2p[i] = energy(merged_jet)^(2p)
end

"""
    copy_to_slot!(eereco, i, j)

Copy the contents of slot `i` in the `eereco` array to slot `j`.
"""
@inline function copy_to_slot!(eereco, i, j)
    eereco.index[j] = eereco.index[i]
    eereco.nni[j] = eereco.nni[i]
    eereco.nndist[j] = eereco.nndist[i]
    eereco.dijdist[j] = eereco.dijdist[i]
    eereco.nx[j] = eereco.nx[i]
    eereco.ny[j] = eereco.ny[i]
    eereco.nz[j] = eereco.nz[i]
    eereco.E2p[j] = eereco.E2p[i]
end

"""
    ee_genkt_algorithm(particles::AbstractVector{T}; algorithm::JetAlgorithm.Algorithm,
                       p::Union{Real, Nothing} = nothing, R = 4.0, recombine = addjets,
                       preprocess = nothing) where {T}

Run an e+e- reconstruction algorithm on a set of initial particles.

# Arguments
- `particles::AbstractVector{T}`: A vector of particles to be clustered.
- `algorithm::JetAlgorithm.Algorithm`: The jet algorithm to use.
- `p::Union{Real, Nothing} = nothing`: The power parameter for the algorithm.
  Must be specified for EEKt algorithm. Other algorithms will ignore this value.
- `R = 4.0`: The jet radius parameter. Not required / ignored for the Durham
  algorithm.
- `recombine`: The recombination scheme to use.
- `preprocess`: Preprocessing function for input particles.

# Returns
- The result of the jet clustering as a `ClusterSequence` object.

# Notes
This is the public interface to the e+e- jet clustering algorithm. The function
will check for consistency between the algorithm and the power parameter as
needed. It will then prepare the internal EDM particles for the clustering
itself, and call the actual reconstruction method `_ee_genkt_algorithm`.

If the algorithm is Durham, `R` is nominally set to 4.
If the algorithm is EEkt, power `p` must be specified.
"""
function ee_genkt_algorithm(particles::AbstractVector{T}; algorithm::JetAlgorithm.Algorithm,
                            p::Union{Real, Nothing} = nothing, R = 4.0, recombine = addjets,
                            preprocess = nothing) where {T}

    # Check for consistency algorithm power
    p = get_algorithm_power(p = p, algorithm = algorithm)

    # Integer p if possible
    p = (round(p) == p) ? Int(p) : p

    # For the Durham algorithm, p=1 and R is not used, but nominally set to 4
    if algorithm == JetAlgorithm.Durham
        R = 4.0
    end

    if isnothing(preprocess)
        if T == EEJet
            # If we don't have a preprocessor, we just need to copy to our own
            # EEJet objects
            recombination_particles = copy(particles)
            sizehint!(recombination_particles, length(particles) * 2)
        else
            # We assume a constructor for EEJet that can ingest the appropriate
            # type of particle
            recombination_particles = EEJet[]
            sizehint!(recombination_particles, length(particles) * 2)
            for (i, particle) in enumerate(particles)
                push!(recombination_particles, EEJet(particle; cluster_hist_index = i))
            end
        end
    else
        # We have a preprocessor function that we need to call to modify the
        # input particles
        recombination_particles = EEJet[]
        sizehint!(recombination_particles, length(particles) * 2)
        for (i, particle) in enumerate(particles)
            push!(recombination_particles,
                  preprocess(particle, EEJet; cluster_hist_index = i))
        end
    end

    # Now call the actual reconstruction method, tuned for our internal EDM
    _ee_genkt_algorithm(particles = recombination_particles, p = p, R = R,
                        algorithm = algorithm,
                        recombine = recombine)
end

"""
    _ee_genkt_algorithm(; particles::AbstractVector{EEJet},
                        algorithm::JetAlgorithm.Algorithm, p::Real, R = 4.0,
                        recombine = addjets)

This function is the actual implementation of the e+e- jet clustering algorithm.
"""
function _ee_genkt_algorithm(; particles::AbstractVector{EEJet},
                             algorithm::JetAlgorithm.Algorithm, p::Real, R = 4.0,
                             recombine = addjets)
    # Bounds
    N::Int = length(particles)

    # R squared
    R2 = R^2

    # Constant factor for the dij metric and the beam distance function
    if algorithm == JetAlgorithm.Durham
        dij_factor = 2.0
    elseif algorithm == JetAlgorithm.EEKt
        if R < π
            dij_factor = 1 / (1 - cos(R))
        else
            dij_factor = 1 / (3 + cos(R))
        end
    else
        throw(ArgumentError("Algorithm $algorithm not supported for e+e-"))
    end

    # For optimised reconstruction generate an SoA containing the necessary
    # jet information and populate it accordingly
    # We need N slots for this array
    eereco = StructArray{EERecoJet}(undef, N)
    fill_reco_array!(eereco, particles, R2, p)

    # Setup the initial history and get the total energy
    history, Qtot = initial_history(particles)

    clusterseq = ClusterSequence(algorithm, p, R, RecoStrategy.N2Plain, particles, history,
                                 Qtot)

    # Run over initial pairs of jets to find nearest neighbours
    get_angular_nearest_neighbours!(eereco, algorithm, dij_factor)

    # Only for debugging purposes...
    # ee_check_consistency(clusterseq, clusterseq_index, N, nndist, nndij, nni, "Start")

    # Now we can start the main loop
    iter = 0
    while N != 0
        iter += 1

        dij_min, ijetA = fast_findmin(eereco.dijdist, N)
        ijetB = eereco[ijetA].nni

        # Now we check if there is a "beam" merge possibility
        if ijetB == 0
            # We have an EEKt beam merge
            ijetB = ijetA
            add_step_to_history!(clusterseq,
                                 clusterseq.jets[eereco[ijetA].index]._cluster_hist_index,
                                 BeamJet, Invalid, dij_min)
        elseif N == 1
            # We have a single jet left
            ijetB = ijetA
            add_step_to_history!(clusterseq,
                                 clusterseq.jets[eereco[ijetA].index]._cluster_hist_index,
                                 BeamJet, Invalid, dij_min)
        else
            # Jet-jet merge
            if ijetB < ijetA
                ijetA, ijetB = ijetB, ijetA
            end

            # Resolve the jet indexes to access the actual jets
            jetA = clusterseq.jets[eereco[ijetA].index]
            jetB = clusterseq.jets[eereco[ijetB].index]

            # Recombine jetA and jetB into the next jet
            merged_jet = recombine(jetA, jetB;
                                   cluster_hist_index = length(clusterseq.history) + 1)

            # Now add the jet to the sequence, and update the history
            push!(clusterseq.jets, merged_jet)
            newjet_k = length(clusterseq.jets)
            add_step_to_history!(clusterseq,
                                 minmax(cluster_hist_index(jetA),
                                        cluster_hist_index(jetB))...,
                                 newjet_k, dij_min)

            # Update the compact arrays, reusing the JetA slot
            insert_new_jet!(eereco, ijetA, newjet_k, R2, merged_jet, p)
        end

        # Squash step - copy the final jet's compact data into the jetB slot
        # unless we are at the end of the array, in which case do nothing
        if ijetB != N
            copy_to_slot!(eereco, N, ijetB)
        end

        # Now number of active jets is decreased by one
        N -= 1

        # Update nearest neighbours step
        for i in 1:N
            # First, if any jet's NN was the old index N, it's now ijetB
            if (ijetB != N + 1) && (eereco[i].nni == N + 1)
                eereco.nni[i] = ijetB
            else
                # Otherwise, if the jet had ijetA or ijetB as their NN, we need to update them
                # plus "belt and braces" check for an invalid NN (>N)
                if (eereco[i].nni == ijetA) || (eereco[i].nni == ijetB) ||
                   (eereco[i].nni > N)
                    update_nn_no_cross!(eereco, i, N, algorithm, dij_factor)
                end
            end
        end

        # Finally, we need to update the nearest neighbours for the new jet, checking both ways
        # (But only if there was a new jet!)
        if ijetA != ijetB
            update_nn_cross!(eereco, ijetA, N, algorithm, dij_factor)
        end

        # Only for debugging purposes...
        # ee_check_consistency(clusterseq, eereco, N)
    end

    # Return the final cluster sequence structure
    clusterseq
end
