function Base.map(::typeof(Gridap.Arrays.testitem),
  a::Tuple{<:AbstractVector{<:AbstractVector{<:VectorValue}},<:AbstractVector{<:Gridap.Fields.LinearCombinationFieldVector}})
  a2=Gridap.Arrays.testitem(a[2])
  a1=Vector{eltype(eltype(a[1]))}(undef,size(a2,1))
  a1.=zero(Gridap.Arrays.testitem(a1))
  (a1,a2)
end

# Fixes Err3 (see below)
function Gridap.Geometry.is_change_possible(
strian::Gridap.Geometry.Triangulation,
ttrian::Gridap.Geometry.Triangulation)
  if strian === ttrian || num_cells(strian)==num_cells(ttrian)==0
  return true
  end
  Gridap.Helpers.@check get_background_model(strian) === get_background_model(ttrian) "Triangulations do not point to the same background discrete model!"
  D = num_cell_dims(strian)
  sglue = get_glue(strian,Val(D))
  tglue = get_glue(ttrian,Val(D))
  Gridap.Geometry.is_change_possible(sglue,tglue) # Fails here
end

# Fixes Err3 (see below)
function Gridap.CellData.change_domain(a::CellField,
                        ::ReferenceDomain,
                        ttrian::Gridap.Geometry.Triangulation,
                        ::ReferenceDomain)
  msg = """\n
  We cannot move the given CellField to the reference domain of the requested triangulation.
  Make sure that the given triangulation is either the same as the triangulation on which the
  CellField is defined, or that the latter triangulation is the background of the former.
  """
  strian = get_triangulation(a)
  if strian === ttrian || num_cells(strian)==num_cells(ttrian)==0
  return a
  end
  @assert Gridap.Geometry.is_change_possible(strian,ttrian) msg
  D = num_cell_dims(strian)
  sglue = get_glue(strian,Val(D))
  tglue = get_glue(ttrian,Val(D))
  Gridap.CellData.change_domain_ref_ref(a,ttrian,sglue,tglue)
end

function Gridap.FESpaces.get_cell_fe_data(fun,f,ttrian)
  sface_to_data = fun(f)
  strian = get_triangulation(f)
  if strian === ttrian || num_cells(strian)==num_cells(ttrian)==0
    return sface_to_data
  end
  @assert Gridap.Geometry.is_change_possible(strian,ttrian)
  D = num_cell_dims(strian)
  sglue = get_glue(strian,Val(D))
  tglue = get_glue(ttrian,Val(D))
  Gridap.FESpaces.get_cell_fe_data(fun,sface_to_data,sglue,tglue)
end

function Gridap.Geometry.best_target(trian1::Gridap.Geometry.Triangulation,trian2::Gridap.Geometry.Triangulation)
  if (num_cells(trian1)==num_cells(trian2)==0)
    return trian1
  end
  Gridap.Helpers.@check Gridap.Geometry.is_change_possible(trian1,trian2)
  Gridap.Helpers.@check Gridap.Geometry.is_change_possible(trian2,trian1)
  D1 = num_cell_dims(trian1)
  D2 = num_cell_dims(trian2)
  glue1 = get_glue(trian1,Val(D2))
  glue2 = get_glue(trian2,Val(D1))
  Gridap.Geometry.best_target(trian1,trian2,glue1,glue2)
end


function Gridap.Geometry.is_change_possible(strian::Gridap.Adaptivity.AdaptedTriangulation,ttrian::Gridap.Adaptivity.AdaptedTriangulation)
  (strian === ttrian) && (return true)
  (num_cells(strian)==num_cells(ttrian)==0) && (return true)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.Geometry.is_change_possible(strian.trian,ttrian.trian)
  end
  if typeof(strian.trian) == typeof(ttrian.trian) 
    smodel = Gridap.Adaptivity.get_adapted_model(strian)
    tmodel = Gridap.Adaptivity.get_adapted_model(ttrian)
    a = Gridap.Adaptivity.get_parent(tmodel) === Gridap.Adaptivity.get_model(smodel) # tmodel = refine(smodel)
    b = Gridap.Adaptivity.get_parent(smodel) === Gridap.Adaptivity.get_model(tmodel) # smodel = refine(tmodel)
    return a || b
  end
  @notimplemented
  return false
end

function Gridap.Geometry.is_change_possible(strian::Gridap.Adaptivity.AdaptedTriangulation,ttrian::Gridap.Geometry.Triangulation)
  (num_cells(strian)==num_cells(ttrian)==0) && (return true)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.Geometry.is_change_possible(strian.trian,ttrian)
  end
  if typeof(strian.trian) == typeof(ttrian)
    smodel = Gridap.Adaptivity.get_adapted_model(strian)
    tmodel = get_background_model(ttrian)
    return get_parent(smodel) === tmodel # smodel = refine(tmodel)
  end
  @notimplemented
  return false
end

function Gridap.Geometry.is_change_possible(strian::Gridap.Geometry.Triangulation,ttrian::Gridap.Adaptivity.AdaptedTriangulation)
  (num_cells(strian)==num_cells(ttrian)==0) && (return true)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.Geometry.is_change_possible(strian,ttrian.trian)
  end
  if typeof(strian) == typeof(ttrian.trian)
    smodel = get_background_model(strian)
    tmodel = Gridap.Adaptivity.get_adapted_model(ttrian)
    return Gridap.Adaptivity.get_parent(tmodel) === smodel # tmodel = refine(smodel)
  end
  @notimplemented
  return false
end

function Gridap.Geometry.best_target(strian::Gridap.Adaptivity.AdaptedTriangulation,ttrian::Gridap.Adaptivity.AdaptedTriangulation)
  @check Gridap.Geometry.is_change_possible(strian,ttrian)
  (num_cells(strian)==num_cells(ttrian)==0) && (return strian)

  (strian === ttrian) && (return ttrian)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.Geometry.best_target(strian.trian,ttrian.trian)
  end
  if typeof(strian.trian) == typeof(ttrian.trian)
    smodel = Gridap.Adaptivity.get_adapted_model(strian)
    tmodel = Gridap.Adaptivity.get_adapted_model(ttrian)
    a = Gridap.Adaptivity.get_parent(tmodel) === Gridap.Adaptivity.get_model(smodel) # tmodel = refine(smodel)
    a ? (return ttrian) : (return strian)
  end
  @notimplemented
  return nothing
end

function Gridap.Geometry.best_target(strian::Gridap.Adaptivity.AdaptedTriangulation,ttrian::Gridap.Geometry.Triangulation)
  @check Gridap.Geometry.is_change_possible(strian,ttrian)
  return strian
end

function Gridap.Geometry.best_target(strian::Gridap.Geometry.Triangulation,ttrian::Gridap.Adaptivity.AdaptedTriangulation)
  @check Gridap.Geometry.is_change_possible(strian,ttrian)
  return ttrian
end

function Gridap.CellData.change_domain(a::CellField,ttrian::Gridap.Adaptivity.AdaptedTriangulation,::ReferenceDomain)
  strian = get_triangulation(a)
  if (strian === ttrian) || (num_cells(strian)==num_cells(ttrian)==0)
    return a
  end
  @assert Gridap.Geometry.is_change_possible(strian,ttrian)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.CellData.change_domain(a,ttrian.trian,ReferenceDomain())
  end
  return Gridap.Adaptivity.change_domain_c2f(a,ttrian)
end

function Gridap.CellData.change_domain(a::Gridap.CellData.OperationCellField,ttrian::Gridap.Adaptivity.AdaptedTriangulation,::ReferenceDomain)
  strian = get_triangulation(a)
  if (strian === ttrian) || (num_cells(strian)==num_cells(ttrian)==0)
    return a
  end
  @assert Gridap.Geometry.is_change_possible(strian,ttrian)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.CellDatachange_domain(a,ttrian.trian,ReferenceDomain())
  end
  return Gridap.Adaptivity.change_domain_c2f(a,ttrian)
end

function Gridap.CellData.change_domain(a::CellField,ttrian::Gridap.Adaptivity.AdaptedTriangulation,::PhysicalDomain)
  strian = get_triangulation(a)
  if (strian === ttrian) || (num_cells(strian)==num_cells(ttrian)==0)
    return a
  end
  @assert Gridap.Geometry.is_change_possible(strian,ttrian)
  if (get_background_model(strian) === get_background_model(ttrian))
    return Gridap.Adaptivity.change_domain(a,ttrian.trian,PhysicalDomain())
  end
  @notimplemented
end

function Gridap.Geometry.move_contributions(scell_to_val::AbstractArray, strian::Gridap.Adaptivity.AdaptedTriangulation, ttrian::Gridap.Geometry.Triangulation)
  (num_cells(strian)==num_cells(ttrian)==0) && (return scell_to_val)
  
  smodel = Gridap.Adaptivity.get_adapted_model(strian)
  @check Gridap.Adaptivity.get_parent(smodel) === get_background_model(ttrian)
  tcell_to_val = Gridap.Geometry.move_contributions(scell_to_val,get_adaptivity_glue(smodel))
  return tcell_to_val
end



# This fix is required to be able to integrate in the overlapped mesh underlying patch smoothers
function Gridap.Geometry.get_glue(trian::BodyFittedTriangulation{Dt},::Val{Dt}) where Dt
  tface_to_mface = trian.tface_to_mface
  tface_to_mface_map = FillArrays.Fill(Gridap.Fields.GenericField(identity),num_cells(trian))
  if isa(tface_to_mface,Gridap.Arrays.IdentityVector) && num_faces(trian.model,Dt) == num_cells(trian)
    mface_to_tface = tface_to_mface
  else
    #nmfaces = num_faces(trian.model,Dt)
    # Crashes here!!! It does not support overlapping!!!
    mface_to_tface = nothing #PosNegPartition(tface_to_mface,Int32(nmfaces))
  end
  FaceToFaceGlue(tface_to_mface,tface_to_mface_map,mface_to_tface)
end


function Gridap.Arrays.evaluate!(cache,s::Gridap.CellData.CellDof,f::CellField)
  trian_f = get_triangulation(f)
  trian_s = get_triangulation(s)

  """if num_cells(trian_s)==num_cells(trian_f)==0
    dof_data = Gridap.CellData.get_data(s)
    item = Gridap.Arrays.testitem(dof_data)
    return Fill(item,0)
  end"""

  if trian_f !== trian_s
    @unreachable """\n
    A CellDof can only be evaluated on a CellField defined on the same Triangulation.
    """
  end
  b = change_domain(f,s.domain_style)
  lazy_map(evaluate,Gridap.CellData.get_data(s),Gridap.CellData.get_data(b))
end


function Gridap.CellData.integrate(f::Gridap.CellData.CellField,quad::Gridap.CellData.CellQuadrature) where DDS
  trian_f = get_triangulation(f)
  trian_x = get_triangulation(quad)

  #if num_cells(trian_f)==num_cells(trian_x)==0
  #  return [Float64[]]
  #end

  msg = """\n
    Your are trying to integrate a CellField using a CellQuadrature defined on incompatible
    triangulations. Verify that either the two objects are defined in the same triangulation
    or that the triangulaiton of the CellField is the background triangulation of the CellQuadrature.
    """
  @check is_change_possible(trian_f,trian_x) msg

  b = change_domain(f,quad.trian,quad.data_domain_style)
  x = get_cell_points(quad)
  bx = b(x)
  if quad.data_domain_style == PhysicalDomain() &&
            quad.integration_domain_style == PhysicalDomain()
    lazy_map(Gridap.Fields.IntegrationMap(),bx,quad.cell_weight)
  elseif quad.data_domain_style == ReferenceDomain() &&
            quad.integration_domain_style == PhysicalDomain()
    cell_map = get_cell_map(quad.trian)
    cell_Jt = lazy_map(∇,cell_map)
    cell_Jtx = lazy_map(evaluate,cell_Jt,quad.cell_point)
    lazy_map(Gridap.Fields.IntegrationMap(),bx,quad.cell_weight,cell_Jtx)
  elseif quad.data_domain_style == ReferenceDomain() &&
            quad.integration_domain_style == ReferenceDomain()
    cell_map = Fill(Gridap.Fields.GenericField(identity),length(bx))
    cell_Jt = lazy_map(∇,cell_map)
    cell_Jtx = lazy_map(evaluate,cell_Jt,quad.cell_point)
    lazy_map(Gridap.Fields.IntegrationMap(),bx,quad.cell_weight,cell_Jtx)
  else
    @notimplemented
  end
end