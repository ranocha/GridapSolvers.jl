module DistributedPatchFESpacesHDivTests

using LinearAlgebra
using Test
using PartitionedArrays
using Gridap
using Gridap.Helpers
using Gridap.Arrays
using Gridap.Geometry
using Gridap.ReferenceFEs
using GridapDistributed
using FillArrays

using GridapSolvers
import GridapSolvers.PatchBasedSmoothers as PBS

#= 
backend = SequentialBackend()
ranks = (1,2)
parts = get_part_ids(backend,ranks)
=#

function run(parts)
  domain = (0.0,1.0,0.0,1.0)
  partition = (2,4)
  model = CartesianDiscreteModel(parts,domain,partition)

  order = 0
  reffe = ReferenceFE(raviart_thomas,Float64,order)
  Vh = TestFESpace(model,reffe)
  PD = PBS.PatchDecomposition(model)
  Ph = PBS.PatchFESpace(model,reffe,DivConformity(),PD,Vh)


  # ---- Testing Prolongation and Injection ---- #

  w, w_sums = PBS.compute_weight_operators(Ph,Vh);

  xP = PVector(1.0,Ph.gids)
  yP = PVector(0.0,Ph.gids)
  x = PVector(1.0,Vh.gids)
  y = PVector(0.0,Vh.gids)

  PBS.prolongate!(yP,Ph,x)
  PBS.inject!(y,Ph,yP,w,w_sums)
  @test x ≈ y

  PBS.inject!(x,Ph,xP,w,w_sums)
  PBS.prolongate!(yP,Ph,x)
  @test xP ≈ yP

  # ---- Assemble systems ---- #

  sol(x) = VectorValue(x[1],x[2])
  f(x) = VectorValue(2.0*x[2]*(1.0-x[1]*x[1]),2.0*x[1]*(1-x[2]*x[2]))

  α = 1.0
  biform(u,v,dΩ)  = ∫(v⋅u)dΩ + ∫(α*divergence(v)⋅divergence(u))dΩ
  liform(v,dΩ)    = ∫(v⋅f)dΩ

  Ω  = Triangulation(model)
  dΩ = Measure(Ω,2*order+1)
  a(u,v) = biform(u,v,dΩ)
  l(v) = liform(v,dΩ)

  assembler = SparseMatrixAssembler(Vh,Vh)
  Ah = assemble_matrix(a,assembler,Vh,Vh)
  fh = assemble_vector(l,assembler,Vh)

  sol_h = solve(LUSolver(),Ah,fh)

  Ωₚ  = Triangulation(PD)
  dΩₚ = Measure(Ωₚ,2*order+1)
  ap(u,v) = biform(u,v,dΩₚ)
  lp(v) = liform(v,dΩₚ)

  assembler_P = SparseMatrixAssembler(Ph,Ph,FullyAssembledRows())
  Ahp = assemble_matrix(ap,assembler_P,Ph,Ph)
  fhp = assemble_vector(lp,assembler_P,Ph)

  sol_hp = solve(LUSolver(),Ahp,fhp)

  # ---- Define solvers ---- #

  LU   = LUSolver()
  LUss = symbolic_setup(LU,Ahp)
  LUns = numerical_setup(LUss,Ahp)

  M   = PBS.PatchBasedLinearSolver(ap,Ph,Vh,LU)
  Mss = symbolic_setup(M,Ah)
  Mns = numerical_setup(Mss,Ah)

  R   = RichardsonSmoother(M,10,1.0/3.0)
  Rss = symbolic_setup(R,Ah)
  Rns = numerical_setup(Rss,Ah)

  # ---- Manual solve using LU ---- # 

  x1_mat = PVector(0.5,Ah.cols)
  r1_mat = fh-Ah*x1_mat
  exchange!(r1_mat)

  r1 = PVector(0.0,Vh.gids)
  x1 = PVector(0.0,Vh.gids)
  rp = PVector(0.0,Ph.gids)
  xp = PVector(0.0,Ph.gids)
  rp_mat = PVector(0.0,Ahp.cols)
  xp_mat = PVector(0.0,Ahp.cols)

  copy!(r1,r1_mat)
  exchange!(r1)
  PBS.prolongate!(rp,Ph,r1) # OK

  copy!(rp_mat,rp)
  exchange!(rp_mat)
  solve!(xp_mat,LUns,rp_mat)
  copy!(xp,xp_mat) # Some big numbers appear here....

  w, w_sums = PBS.compute_weight_operators(Ph,Vh);
  PBS.inject!(x1,Ph,xp,w,w_sums) # Problem here!!
  copy!(x1_mat,x1)

  # ---- Same using the PatchBasedSmoother ---- #

  x2_mat = PVector(0.5,Ah.cols)
  r2_mat = fh-Ah*x2_mat
  exchange!(r2_mat)
  solve!(x2_mat,Mns,r2_mat)

  # ---- Smoother inside Richardson

  x3_mat = PVector(0.5,Ah.cols)
  r3_mat = fh-Ah*x3_mat
  exchange!(r3_mat)
  solve!(x3_mat,Rns,r3_mat)
  exchange!(x3_mat)

  # Outputs 
  res = Dict{String,Any}()
  res["sol_h"]  = sol_h
  res["sol_hp"] = sol_hp

  res["r1"]     = r1
  res["x1"]     = x1
  res["r1_mat"] = r1_mat
  res["x1_mat"] = x1_mat
  res["rp"]     = rp
  res["xp"]     = xp
  res["rp_mat"] = rp_mat
  res["xp_mat"] = xp_mat

  res["w"]      = w
  res["w_sums"] = w_sums

  return model,PD,Ph,Vh,res
end

backend = SequentialBackend()

parts = get_part_ids(backend,(1,1))
Ms,PDs,Phs,Vhs,res_single = run(parts);

parts = get_part_ids(backend,(1,2))
Mm,PDm,Phm,Vhm,res_multi = run(parts);

println(repeat('#',80))

map_parts(local_views(Ms)) do model
  cell_ids = get_cell_node_ids(model)
  cell_coords = get_cell_coordinates(model)
  display(reshape(cell_ids,length(cell_ids)))
  display(reshape(cell_coords,length(cell_coords)))
end;
println(repeat('-',80))

cell_gids   = get_cell_gids(Mm)
vertex_gids = get_face_gids(Mm,0)
edge_gids   = get_face_gids(Mm,1)

println(">>> Cell gids")
map_parts(cell_gids.partition) do p
  println(transpose(p.lid_to_ohid))
end;
println(repeat('-',80))

println(">>> Vertex gids")
map_parts(vertex_gids.partition) do p
  println(transpose(p.lid_to_ohid))
end;
println(repeat('-',80))

println(">>> Edge gids")
map_parts(edge_gids.partition) do p
  println(transpose(p.lid_to_ohid))
end;

println(repeat('#',80))

map_parts(local_views(Phs)) do Ph
  display(Ph.patch_cell_dofs_ids)
end;

map_parts(local_views(Phm)) do Ph
  display(Ph.patch_cell_dofs_ids)
end;

println(repeat('#',80))

for key in keys(res_single)
  val_s = res_single[key]
  val_m = res_multi[key]

  println(">>> ", key)
  map_parts(val_s.values) do v
    println(transpose(v))
  end;
  map_parts(val_m.owned_values) do v
    println(transpose(v))
  end;
  println(repeat('-',80))
end

end