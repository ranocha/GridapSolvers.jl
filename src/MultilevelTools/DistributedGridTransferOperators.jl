

struct DistributedGridTransferOperator{T,R,M,A,B}
  sh     :: A
  cache  :: B

  function DistributedGridTransferOperator(op_type::Symbol,redist::Bool,restriction_method::Symbol,sh::FESpaceHierarchy,cache)
    T = typeof(Val(op_type))
    R = typeof(Val(redist))
    M = typeof(Val(restriction_method))
    A = typeof(sh)
    B = typeof(cache)
    new{T,R,M,A,B}(sh,cache)
  end
end

### Constructors

function RestrictionOperator(lev::Int,sh::FESpaceHierarchy,qdegree::Int;kwargs...)
  return DistributedGridTransferOperator(lev,sh,qdegree,:restriction;kwargs...)
end

function ProlongationOperator(lev::Int,sh::FESpaceHierarchy,qdegree::Int;kwargs...)
  return DistributedGridTransferOperator(lev,sh,qdegree,:prolongation;kwargs...)
end

function DistributedGridTransferOperator(lev::Int,sh::FESpaceHierarchy,qdegree::Int,op_type::Symbol;
                                         mode::Symbol=:solution,restriction_method::Symbol=:projection)
  mh = sh.mh
  @check lev < num_levels(mh)
  @check op_type ∈ [:restriction, :prolongation]
  @check mode ∈ [:solution, :residual]
  @check restriction_method ∈ [:projection, :interpolation, :dof_mask]

  # Refinement
  if (op_type == :prolongation) || (restriction_method ∈ [:interpolation,:dof_mask])
    cache_refine = _get_interpolation_cache(lev,sh,qdegree,mode)
  else
    cache_refine = _get_projection_cache(lev,sh,qdegree,mode)
  end

  # Redistribution
  redist = has_redistribution(mh,lev)
  cache_redist = _get_redistribution_cache(lev,sh,mode,op_type,cache_refine)

  cache = cache_refine, cache_redist
  return DistributedGridTransferOperator(op_type,redist,restriction_method,sh,cache)
end

function _get_interpolation_cache(lev::Int,sh::FESpaceHierarchy,qdegree::Int,mode::Symbol)
  mh = sh.mh
  cparts = get_level_parts(mh,lev+1)

  if i_am_in(cparts)
    model_h = get_model_before_redist(mh,lev)
    Uh = get_fe_space_before_redist(sh,lev)
    fv_h = PVector(0.0,Uh.gids)
    dv_h = (mode == :solution) ? get_dirichlet_dof_values(Uh) : zero_dirichlet_values(Uh)

    UH = get_fe_space(sh,lev+1)
    fv_H = PVector(0.0,UH.gids)
    dv_H = (mode == :solution) ? get_dirichlet_dof_values(UH) : zero_dirichlet_values(UH)

    cache_refine = model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H
  else
    model_h = get_model_before_redist(mh,lev)
    Uh      = get_fe_space_before_redist(sh,lev)
    cache_refine = model_h, Uh, nothing, nothing, nothing, nothing, nothing
  end

  return cache_refine
end

function _get_projection_cache(lev::Int,sh::FESpaceHierarchy,qdegree::Int,mode::Symbol)
  mh = sh.mh
  cparts = get_level_parts(mh,lev+1)

  if i_am_in(cparts)
    model_h = get_model_before_redist(mh,lev)
    Uh   = get_fe_space_before_redist(sh,lev)
    Ωh   = Triangulation(model_h)
    fv_h = zero_free_values(Uh)
    dv_h = (mode == :solution) ? get_dirichlet_dof_values(Uh) : zero_dirichlet_values(Uh)

    model_H = get_model(mh,lev+1)
    UH   = get_fe_space(sh,lev+1)
    VH   = get_test_space(UH)
    ΩH   = Triangulation(model_H)
    dΩH  = Measure(ΩH,qdegree)
    dΩhH = Measure(ΩH,Ωh,qdegree)

    aH(u,v)  = ∫(v⋅u)*dΩH
    lH(v,uh) = ∫(v⋅uh)*dΩhH
    assem    = SparseMatrixAssembler(UH,VH)

    fv_H   = zero_free_values(UH)
    dv_H   = zero_dirichlet_values(UH)
    u0     = FEFunction(UH,fv_H,true)      # Zero at free dofs
    u00    = FEFunction(UH,fv_H,dv_H,true) # Zero everywhere

    u_dir  = (mode == :solution) ? u0 : u00
    u,v    = get_trial_fe_basis(UH), get_fe_basis(VH)
    data   = collect_cell_matrix_and_vector(UH,VH,aH(u,v),lH(v,u00),u_dir)
    AH,bH0 = assemble_matrix_and_vector(assem,data)
    xH     = PVector(0.0,AH.cols)
    bH     = copy(bH0)

    cache_refine = model_h, Uh, fv_h, dv_h, VH, AH, lH, xH, bH, bH0, assem
  else
    model_h = get_model_before_redist(mh,lev)
    Uh      = get_fe_space_before_redist(sh,lev)
    cache_refine = model_h, Uh, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing
  end

  return cache_refine
end

function _get_redistribution_cache(lev::Int,sh::FESpaceHierarchy,mode::Symbol,op_type::Symbol,cache_refine)
  mh = sh.mh
  redist = has_redistribution(mh,lev)
  if !redist 
    cache_redist = nothing
    return cache_redist
  end

  Uh_red      = get_fe_space(sh,lev)
  model_h_red = get_model(mh,lev)
  fv_h_red    = PVector(0.0,Uh_red.gids)
  dv_h_red    = (mode == :solution) ? get_dirichlet_dof_values(Uh_red) : zero_dirichlet_values(Uh_red)
  glue        = mh.levels[lev].red_glue

  if op_type == :prolongation
    model_h, Uh, fv_h, dv_h = cache_refine
    cache_exchange = get_redistribute_free_values_cache(fv_h_red,Uh_red,fv_h,dv_h,Uh,model_h_red,glue;reverse=false)
  else
    model_h, Uh, fv_h, dv_h = cache_refine
    cache_exchange = get_redistribute_free_values_cache(fv_h,Uh,fv_h_red,dv_h_red,Uh_red,model_h,glue;reverse=true)
  end

  cache_redist = fv_h_red, dv_h_red, Uh_red, model_h_red, glue, cache_exchange

  return cache_redist
end

function setup_transfer_operators(sh::FESpaceHierarchy,qdegree::Integer;kwargs...)
  qdegrees = Fill(qdegree,num_levels(sh))
  return setup_transfer_operators(sh,qdegrees;kwargs...)
end

function setup_transfer_operators(sh::FESpaceHierarchy,qdegrees::AbstractArray{<:Integer};kwargs...)
  @check length(qdegrees) == num_levels(sh)
  mh = sh.mh
  restrictions  = Vector{DistributedGridTransferOperator}(undef,num_levels(sh)-1)
  prolongations = Vector{DistributedGridTransferOperator}(undef,num_levels(sh)-1)
  for lev in 1:num_levels(sh)-1
    parts = get_level_parts(mh,lev)
    if i_am_in(parts)
      qdegree = qdegrees[lev]
      restrictions[lev]  = RestrictionOperator(lev,sh,qdegree;kwargs...)
      prolongations[lev] = ProlongationOperator(lev,sh,qdegree;kwargs...)
    end
  end
  return restrictions, prolongations
end

### Applying the operators:

# A) Prolongation, without redistribution
function LinearAlgebra.mul!(y::PVector,A::DistributedGridTransferOperator{Val{:prolongation},Val{false}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine

  copy!(fv_H,x) # Matrix layout -> FE layout
  uH = FEFunction(UH,fv_H,dv_H)
  uh = interpolate!(uH,fv_h,Uh)
  copy!(y,fv_h) # FE layout -> Matrix layout

  return y
end

# B.1) Restriction, without redistribution, by interpolation
function LinearAlgebra.mul!(y::PVector,A::DistributedGridTransferOperator{Val{:restriction},Val{false},Val{:interpolation}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine

  copy!(fv_h,x) # Matrix layout -> FE layout
  uh = FEFunction(Uh,fv_h,dv_h)
  uH = interpolate!(uh,fv_H,UH)
  copy!(y,fv_H) # FE layout -> Matrix layout

  return y
end

# B.2) Restriction, without redistribution, by projection
function LinearAlgebra.mul!(y::PVector,A::DistributedGridTransferOperator{Val{:restriction},Val{false},Val{:projection}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, VH, AH, lH, xH, bH, bH0, assem = cache_refine

  copy!(fv_h,x) # Matrix layout -> FE layout
  uh = FEFunction(Uh,fv_h,dv_h)
  v  = get_fe_basis(VH)
  vec_data = collect_cell_vector(VH,lH(v,uh))
  copy!(bH,bH0)
  assemble_vector_add!(bH,assem,vec_data) # Matrix layout
  IterativeSolvers.cg!(xH,AH,bH;reltol=1.0e-06)
  copy!(y,xH)
  
  return y
end

# B.3) Restriction, without redistribution, by dof selection (only nodal dofs)
function LinearAlgebra.mul!(y::PVector,A::DistributedGridTransferOperator{Val{:restriction},Val{false},Val{:dof_mask}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine

  copy!(fv_h,x) # Matrix layout -> FE layout
  exchange!(fv_h)
  restrict_dofs!(fv_H,fv_h,dv_h,Uh,UH,get_adaptivity_glue(model_h))
  copy!(y,fv_H) # FE layout -> Matrix layout

  return y
end

# C) Prolongation, with redistribution
function LinearAlgebra.mul!(y::PVector,A::DistributedGridTransferOperator{Val{:prolongation},Val{true}},x::Union{PVector,Nothing})
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine
  fv_h_red, dv_h_red, Uh_red, model_h_red, glue, cache_exchange = cache_redist

  # 1 - Interpolate in coarse partition
  if !isa(x,Nothing)
    copy!(fv_H,x) # Matrix layout -> FE layout
    uH = FEFunction(UH,fv_H,dv_H)
    uh = interpolate!(uH,fv_h,Uh)
  end

  # 2 - Redistribute from coarse partition to fine partition
  redistribute_free_values!(cache_exchange,fv_h_red,Uh_red,fv_h,dv_h,Uh,model_h_red,glue;reverse=false)
  copy!(y,fv_h_red) # FE layout -> Matrix layout

  return y
end

# D.1) Restriction, with redistribution, by interpolation
function LinearAlgebra.mul!(y::Union{PVector,Nothing},A::DistributedGridTransferOperator{Val{:restriction},Val{true},Val{:interpolation}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine
  fv_h_red, dv_h_red, Uh_red, model_h_red, glue, cache_exchange = cache_redist

  # 1 - Redistribute from fine partition to coarse partition
  copy!(fv_h_red,x)
  exchange!(fv_h_red)
  redistribute_free_values!(cache_exchange,fv_h,Uh,fv_h_red,dv_h_red,Uh_red,model_h,glue;reverse=true)

  # 2 - Interpolate in coarse partition
  if !isa(y,Nothing)
    uh = FEFunction(Uh,fv_h,dv_h)
    uH = interpolate!(uh,fv_H,UH)
    copy!(y,fv_H) # FE layout -> Matrix layout
  end

  return y 
end

# D.2) Restriction, with redistribution, by projection
function LinearAlgebra.mul!(y::Union{PVector,Nothing},A::DistributedGridTransferOperator{Val{:restriction},Val{true},Val{:projection}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, VH, AH, lH, xH, bH, bH0, assem = cache_refine
  fv_h_red, dv_h_red, Uh_red, model_h_red, glue, cache_exchange = cache_redist

  # 1 - Redistribute from fine partition to coarse partition
  copy!(fv_h_red,x)
  exchange!(fv_h_red)
  redistribute_free_values!(cache_exchange,fv_h,Uh,fv_h_red,dv_h_red,Uh_red,model_h,glue;reverse=true)

  # 2 - Solve f2c projection coarse partition
  if !isa(y,Nothing)
    uh = FEFunction(Uh,fv_h,dv_h)
    v  = get_fe_basis(VH)
    vec_data = collect_cell_vector(VH,lH(v,uh))
    copy!(bH,bH0)
    assemble_vector_add!(bH,assem,vec_data) # Matrix layout
    IterativeSolvers.cg!(xH,AH,bH;reltol=1.0e-06)
    copy!(y,xH)
  end

  return y 
end

# D.3) Restriction, with redistribution, by dof selection (only nodal dofs)
function LinearAlgebra.mul!(y::Union{PVector,Nothing},A::DistributedGridTransferOperator{Val{:restriction},Val{true},Val{:dof_mask}},x::PVector)
  cache_refine, cache_redist = A.cache
  model_h, Uh, fv_h, dv_h, UH, fv_H, dv_H = cache_refine
  fv_h_red, dv_h_red, Uh_red, model_h_red, glue, cache_exchange = cache_redist

  # 1 - Redistribute from fine partition to coarse partition
  copy!(fv_h_red,x)
  exchange!(fv_h_red)
  redistribute_free_values!(cache_exchange,fv_h,Uh,fv_h_red,dv_h_red,Uh_red,model_h,glue;reverse=true)

  # 2 - Interpolate in coarse partition
  if !isa(y,Nothing)
    restrict_dofs!(fv_H,fv_h,dv_h,Uh,UH,get_adaptivity_glue(model_h))
    copy!(y,fv_H) # FE layout -> Matrix layout
  end

  return y 
end