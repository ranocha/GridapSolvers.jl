struct FESpaceHierarchyLevel{A,B}
  level        :: Int
  fe_space     :: A
  fe_space_red :: B
end

struct FESpaceHierarchy
  mh     :: ModelHierarchy
  levels :: Vector{FESpaceHierarchyLevel}
end


function Base.getindex(fh::FESpaceHierarchy,level::Integer)
  fh.levels[level]
end

function Base.length(fh::FESpaceHierarchy)
  length(fh.levels)
end

function num_levels(fh::FESpaceHierarchy)
  length(fh)
end

function get_fe_space(a::FESpaceHierarchyLevel{A,Nothing}) where {A}
  a.fe_space
end

function get_fe_space(a::FESpaceHierarchyLevel{A,B}) where {A,B}
  a.fe_space_red
end

function get_fe_space(fh::FESpaceHierarchy,lev::Int)
  get_fe_space(fh[lev])
end

function get_fe_space_before_redist(a::FESpaceHierarchyLevel)
  a.fe_space
end

function get_fe_space_before_redist(fh::FESpaceHierarchy,lev::Int)
  get_fe_space_before_redist(fh[lev])
end

function Gridap.FESpaces.TestFESpace(
      mh::ModelHierarchyLevel{A,B,C,Nothing},args...;kwargs...) where {A,B,C}
  Vh = TestFESpace(get_model(mh),args...;kwargs...)
  FESpaceHierarchyLevel(mh.level,Vh,nothing)
end

function Gridap.FESpaces.TestFESpace(
      mh::ModelHierarchyLevel{A,B,C,D},args...;kwargs...) where {A,B,C,D}
  Vh     = TestFESpace(get_model_before_redist(mh),args...;kwargs...)
  Vh_red = TestFESpace(get_model(mh),args...;kwargs...)
  FESpaceHierarchyLevel(mh.level,Vh,Vh_red)
end

function Gridap.FESpaces.TrialFESpace(a::FESpaceHierarchyLevel{A,Nothing},u) where {A}
  Uh = TrialFESpace(a.fe_space,u)
  FESpaceHierarchyLevel(a.level,Uh,nothing)
end

function Gridap.FESpaces.TrialFESpace(a::FESpaceHierarchyLevel{A,B},u) where {A,B}
  Uh     = TrialFESpace(a.fe_space,u)
  Uh_red = TrialFESpace(a.fe_space_red,u)
  FESpaceHierarchyLevel(a.level,Uh,Uh_red)
end

function Gridap.FESpaces.TestFESpace(mh::ModelHierarchy,args...;kwargs...)
  test_spaces = Vector{FESpaceHierarchyLevel}(undef,num_levels(mh))
  for i = 1:num_levels(mh)
    parts = get_level_parts(mh,i)
    if i_am_in(parts)
      Vh = TestFESpace(get_level(mh,i),args...;kwargs...)
      test_spaces[i] = Vh
    end
  end
  FESpaceHierarchy(mh,test_spaces)
end

function Gridap.FESpaces.TestFESpace(
                      mh::ModelHierarchy,
                      arg_vector::AbstractVector{<:Union{ReferenceFE,Tuple{<:Gridap.ReferenceFEs.ReferenceFEName,Any,Any}}};
                      kwargs...)
  @check length(arg_vector) == num_levels(mh)
  test_spaces = Vector{FESpaceHierarchyLevel}(undef,num_levels(mh))
  for i = 1:num_levels(mh)
    parts = get_level_parts(mh,i)
    if i_am_in(parts)
      args = arg_vector[i]
      Vh   = TestFESpace(get_level(mh,i),args;kwargs...)
      test_spaces[i] = Vh
    end
  end
  FESpaceHierarchy(mh,test_spaces)
end

function Gridap.FESpaces.TrialFESpace(a::FESpaceHierarchy,u)
  trial_spaces = Vector{FESpaceHierarchyLevel}(undef,num_levels(a.mh))
  for i = 1:num_levels(a.mh)
    parts = get_level_parts(a.mh,i)
    if i_am_in(parts)
      Uh = TrialFESpace(a[i],u)
      trial_spaces[i] = Uh
    end
  end
  FESpaceHierarchy(a.mh,trial_spaces)
end

function Gridap.FESpaces.TrialFESpace(a::FESpaceHierarchy)
  trial_spaces = Vector{FESpaceHierarchyLevel}(undef,num_levels(a.mh))
  for i = 1:num_levels(a.mh)
    parts = get_level_parts(a.mh,i)
    if i_am_in(parts)
      Uh = TrialFESpace(a[i])
      trial_spaces[i] = Uh
    end
  end
  FESpaceHierarchy(a.mh,trial_spaces)
end

function compute_hierarchy_matrices(trials::FESpaceHierarchy,a::Function,l::Function,qdegree::Integer)
  return compute_hierarchy_matrices(trials,a,l,Fill(qdegree,num_levels(trials)))
end

function compute_hierarchy_matrices(trials::FESpaceHierarchy,a::Function,l::Function,qdegree::AbstractArray{<:Integer})
  nlevs = num_levels(trials)
  mh    = trials.mh

  @check length(qdegree) == nlevs

  A = nothing
  b = nothing
  mats = Vector{PSparseMatrix}(undef,nlevs)
  for lev in 1:nlevs
    parts = get_level_parts(mh,lev)
    if i_am_in(parts)
      model = get_model(mh,lev)
      U = get_fe_space(trials,lev)
      V = get_test_space(U)
      Ω = Triangulation(model)
      dΩ = Measure(Ω,qdegree[lev])
      ai(u,v) = a(u,v,dΩ)
      if lev == 1
        li(v) = l(v,dΩ)
        op    = AffineFEOperator(ai,li,U,V)
        A, b  = get_matrix(op), get_vector(op)
        mats[lev] = A
      else
        mats[lev] = assemble_matrix(ai,U,V)
      end
    end
  end
  return mats, A, b
end
