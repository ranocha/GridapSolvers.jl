# ON another note. Related to FE assembly. We are going to need:
# "Por otra parte, tb podemos tener metodos q reciben una patch-cell array y la
# aplanan para q parezca una cell array (aunq con cells repetidas). Combinando las
# patch-cell local matrices y cell_dofs aplanadas puedes usar el assembly verbatim si
# quieres ensamblar la matriz."

# Another note. During FE assembly we may end computing the cell matrix of a given cell
# more than once due to cell overlapping among patches (recall the computation of these
# matrices is lazy, it occurs on first touch). Can we live with that or should we pay
# attention on how to avoid this? I think that Gridap already includes tools for
# taking profit of this, I think it is called MemoArray, but it might be something else
# (not 100% sure, to investigate)


struct PatchBasedLinearSolver{A,B} <: Gridap.Algebra.LinearSolver
  bilinear_form  :: Function
  Ph             :: A
  Vh             :: B
  M              :: Gridap.Algebra.LinearSolver
end

struct PatchBasedSymbolicSetup <: Gridap.Algebra.SymbolicSetup
  solver :: PatchBasedLinearSolver
end

function Gridap.Algebra.symbolic_setup(ls::PatchBasedLinearSolver,mat::AbstractMatrix)
  return PatchBasedSymbolicSetup(ls)
end

struct PatchBasedSmootherNumericalSetup{A,B,C,D,E,F} <: Gridap.Algebra.NumericalSetup
  solver         :: PatchBasedLinearSolver
  Ap             :: A
  nsAp           :: B
  rp             :: C
  dxp            :: D
  w              :: E
  w_sums         :: F
end

function Gridap.Algebra.numerical_setup(ss::PatchBasedSymbolicSetup,A::AbstractMatrix)
  Ph, Vh = ss.solver.Ph, ss.solver.Vh
  assembler = SparseMatrixAssembler(Ph,Ph)
  Ap        = assemble_matrix(ss.solver.bilinear_form,assembler,Ph,Ph)
  solver    = ss.solver.M
  ssAp      = symbolic_setup(solver,Ap)
  nsAp      = numerical_setup(ssAp,Ap)
  rp        = _allocate_row_vector(Ap)
  dxp       = _allocate_col_vector(Ap)
  w, w_sums = compute_weight_operators(Ph,Vh)
  return PatchBasedSmootherNumericalSetup(ss.solver,Ap,nsAp,rp,dxp,w,w_sums)
end

function _allocate_col_vector(A::AbstractMatrix)
  zeros(size(A,2))
end

function _allocate_row_vector(A::AbstractMatrix)
  zeros(size(A,1))
end

function _allocate_col_vector(A::PSparseMatrix)
  PVector(0.0,A.cols)
end

function _allocate_row_vector(A::PSparseMatrix)
  PVector(0.0,A.rows)
end

function Gridap.Algebra.numerical_setup!(ns::PatchBasedSmootherNumericalSetup, A::AbstractMatrix)
  Gridap.Helpers.@notimplemented
end

function Gridap.Algebra.solve!(x::AbstractVector,ns::PatchBasedSmootherNumericalSetup,r::AbstractVector)
  Ap, nsAp, rp, dxp, w, w_sums = ns.Ap, ns.nsAp, ns.rp, ns.dxp, ns.w, ns.w_sums
  Ph = ns.solver.Ph

  prolongate!(rp,Ph,r)
  solve!(dxp,nsAp,rp)
  inject!(x,Ph,dxp,w,w_sums)
  return x
end
