module RefinementToolsTests
  using MPI
  using PartitionedArrays
  using Gridap
  using GridapDistributed
  using GridapP4est
  using GridapSolvers
  using Test
  using IterativeSolvers

  function run(parts,num_parts_x_level,num_trees,num_refs_coarse)
    domain       = (0,1,0,1)
    cmodel       = CartesianDiscreteModel(domain,num_trees)

    nlevs        = length(num_parts_x_level)
    level_parts  = GridapSolvers.generate_level_parts(parts,num_parts_x_level)
    coarse_model = OctreeDistributedDiscreteModel(level_parts[nlevs],cmodel,num_refs_coarse)
    mh = ModelHierarchy(coarse_model,level_parts)

    # FE Spaces
    order  = 1
    sol(x) = x[1] + x[2]
    reffe  = ReferenceFE(lagrangian,Float64,order)
    tests  = TestFESpace(mh,reffe,conformity=:H1)#,dirichlet_tags="boundary")
    trials = TrialFESpace(sol,tests)

    quad_order = 2*order+1
    for lev in 1:nlevs-1
      fparts = get_level_parts(mh,lev)
      cparts = get_level_parts(mh,lev+1)

      if GridapP4est.i_am_in(fparts)
        Vh  = get_fe_space_before_redist(tests,lev)
        Uh  = get_fe_space_before_redist(trials,lev)
        Ωh  = get_triangulation(Uh,get_model_before_redist(mh,lev))
        dΩh = Measure(Ωh,quad_order)
        uh  = interpolate(sol,Uh)
        vh  = get_fe_basis(Uh)

        if GridapP4est.i_am_in(cparts)
          VH  = get_fe_space(tests,lev+1)
          UH  = get_fe_space(trials,lev+1)
          ΩH  = get_triangulation(UH,get_model(mh,lev+1))
          dΩH = Measure(ΩH,quad_order)
          uH  = interpolate(sol,UH)
          vH  = get_fe_basis(UH)
          dΩhH = Measure(ΩH,Ωh,quad_order)
        else
          uH = nothing
          vH = nothing
        end

        uH_Ph = change_parts(GridapDistributed.DistributedCellField,uH,fparts)
        vH_Ph = change_parts(GridapDistributed.DistributedCellField,vH,fparts)

        # Coarse FEFunction -> Fine FEFunction, by projection
        ah(u,v) = ∫(v⋅u)*dΩh
        lh(v)   = ∫(v⋅uH_Ph)*dΩh
        Ah = assemble_matrix(ah,Uh,Vh)
        bh = assemble_vector(lh,Vh)

        xh = PVector(0.0,Ah.cols)
        IterativeSolvers.cg!(xh,Ah,bh;verbose=i_am_main(parts),reltol=1.0e-06)
        uhH = FEFunction(Uh,xh)

        eh = sum(∫(uh-uhH)*dΩh)
        i_am_main(parts) && println("Error H2h: ", eh)

        # Fine FEFunction -> Coarse FEFunction, by projection
        if GridapP4est.i_am_in(cparts)
          uh_PH = change_parts(GridapDistributed.DistributedCellField,uh,cparts)

          aH(u,v) = ∫(v⋅u)*dΩH
          lH(v)   = ∫(v⋅uh_PH)*dΩhH
          AH = assemble_matrix(aH,UH,VH)
          bH = assemble_vector(lH,VH)

          xH = PVector(0.0,AH.cols)
          IterativeSolvers.cg!(xH,AH,bH;verbose=i_am_main(parts),reltol=1.0e-06)
          uHh = FEFunction(UH,xH)

          eh = sum(∫(uH-uHh)*dΩH)
          i_am_main(parts) && println("Error h2H: ", eh)
        else
          uHh = nothing
        end
        uHh_Ph = change_parts(GridapDistributed.DistributedCellField,uHh,fparts) 

      end
    end

  end


  num_parts_x_level = [4,2,2]   # Procs in each refinement level
  num_trees         = (1,1)     # Number of initial P4est trees
  num_refs_coarse   = 2         # Number of initial refinements
  
  ranks = num_parts_x_level[1]
  prun(run,mpi,ranks,num_parts_x_level,num_trees,num_refs_coarse)
  MPI.Finalize()
end
