module Snopt

export snopt

const snoptlib = joinpath(dirname(@__FILE__), "../deps/src/libsnopt")

const codes = Dict{Int64, String}()
codes[1] = "Finished successfully: optimality conditions satisfied"
codes[2] = "Finished successfully: feasible point found"
codes[3] = "Finished successfully: requested accuracy could not be achieved"
codes[11] = "The problem appears to be infeasible: infeasible linear constraints"
codes[12] = "The problem appears to be infeasible: infeasible linear equalities"
codes[13] = "The problem appears to be infeasible: nonlinear infeasibilities minimized"
codes[14] = "The problem appears to be infeasible: infeasibilities minimized"
codes[21] = "The problem appears to be unbounded: unbounded objective"
codes[22] = "The problem appears to be unbounded: constraint violation limit reached"
codes[31] = "Resource limit error: iteration limit reached"
codes[32] = "Resource limit error: major iteration limit reached"
codes[33] = "Resource limit error: the superbasics limit is too small"
codes[41] =  "Terminated after numerical difficulties: current point cannot be improved"
codes[42] =  "Terminated after numerical difficulties: singular basis"
codes[43] =  "Terminated after numerical difficulties: cannot satisfy the general constraints"
codes[44] =  "Terminated after numerical difficulties: ill-conditioned null-space basis"
codes[51] =  "Error in the user-supplied functions: incorrect objective derivatives"
codes[52] =  "Error in the user-supplied functions: incorrect constraint derivatives"
codes[61] =  "Undefined user-supplied functions: undefined function at the first feasible point"
codes[62] =  "Undefined user-supplied functions: undefined function at the initial point"
codes[63] =  "Undefined user-supplied functions: unable to proceed into undefined region"
codes[71] =  "User requested termination: terminated during function evaluation "
codes[74] =  "User requested termination: terminated from monitor routine"
codes[81] =  "Insufficient storage allocated: work arrays must have at least 500 elements"
codes[82] =  "Insufficient storage allocated: not enough character storage"
codes[83] =  "Insufficient storage allocated: not enough integer storage"
codes[84] =  "Insufficient storage allocated: not enough real storage"
codes[91] =  "Input arguments out of range: invalid input argument"
codes[92] =  "Input arguments out of range: basis file dimensions do not match this problem"
codes[141] =  "System error: wrong number of basic variables"
codes[142] =  "System error: error in basis package"


const PRINTNUM = 18
const SUMNUM = 19

# callback function
function objcon_wrapper(status::Int32, n::Int32, x_::Ptr{Cdouble},
    needf::Int32, nF::Int32, f_::Ptr{Cdouble}, needG::Int32, lenG::Int32,
    G_::Ptr{Cdouble}, cu::Ptr{UInt8}, lencu::Int32, iu::Ptr{Cint},
    leniu::Int32, ru_::Ptr{Cdouble}, lenru::Int32)

    # check if solution finished, no need to calculate more
    if status >= 2
        return
    end

    # unpack design variables
    x = zeros(n)
    for i = 1:n
        x[i] = unsafe_load(x_, i)
    end
    # x = unsafe_load(x_)  # TODO: test this

    # call function
    res = objcon(x)
    if length(res) == 3
        J, c, fail = res
        gradprovided = false
    else
        J, c, gJ, gc, fail = res
        gradprovided = true
    end

    # copy obj and con values into C pointer
    unsafe_store!(f_, J, 1)
    for i = 2:nF
        unsafe_store!(f_, c[i-1], i)
    end

    # gradients  TODO: separate gradient computation in interface?
    if needG > 0 && gradprovided

        for j = 1:n
            # gradients of f
            unsafe_store!(G_, gJ[j], j)
        end

        k = n+1
        for i = 2:nF
            for j = 1:n
                unsafe_store!(G_, gc[i-1, j], k)
                k += 1
            end
        end
    end


    # check if solutions fails
    if fail
        status = -1
    end

    # flush output files to see progress
    ccall( (:flushfiles_, snoptlib), Void,
        (Ref{Cint}, Ref{Cint}),
        PRINTNUM, SUMNUM)


end

# c wrapper to callback function
const usrfun = cfunction(objcon_wrapper, Void, (Ref{Cint}, Ref{Cint}, Ptr{Cdouble},
    Ref{Cint}, Ref{Cint}, Ptr{Cdouble}, Ref{Cint}, Ref{Cint}, Ptr{Cdouble},
    Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint}, Ptr{Cdouble}, Ref{Cint}))



# main call to snopt
function snopt(fun, x0, lb, ub, options;
               printfile = "snopt-print.out", sumfile = "snopt-summary.out")

    # call function
    f, c = fun(x0)

    # TODO: there is a probably a better way than to use a global
    global objcon = fun

    # TODO: set a timer


    # setup
    Start = 0  # cold start  # TODO: allow warm starts
    nF = 1 + length(c)  # 1 objective + constraints
    n = length(x0)  # number of design variables
    ObjAdd = 0.0  # no constant term added to objective (user can add themselves if desired)
    ObjRow = 1  # objective is first thing returned, then constraints

    # linear constraints (none for now)
    iAfun = Int32[1]
    jAvar = Int32[1]
    A = [0.0]  # TODO: change later
    lenA = 1
    neA = 0

    # nonlinear constraints (assume dense jacobian for now)
    lenG = nF*n
    neG = lenG
    iGfun = Array{Int32}(lenG)
    jGvar = Array{Int32}(lenG)
    k = 1
    for i = 1:nF
        for j = 1:n
            iGfun[k] = i
            jGvar[k] = j
            k += 1
        end
    end

    # bound constriaints (no infinite bounds for now)
    xlow = lb
    xupp = ub
    Flow = -1e20*ones(nF)  # TODO: check Infinite Bound size
    Fupp = zeros(nF)  # TODO: currently c <= 0, but perhaps change

    # names
    Prob = "opt prob"  # problem name TODO: change later
    nxname = 1  # TODO: change later
    xnames = Array{UInt8}(nxname, 8)
    # xnames = ["TODOTODO"]
    nFname = 1  # TODO: change later
    Fnames = Array{UInt8}(nFname, 8)
    # Fnames = ["TODOTODO"]

    # starting info
    x = x0
    xstate = zeros(n)
    xmul = zeros(n)
    F = zeros(nF)
    Fstate = zeros(nF)
    Fmul = zeros(nF)
    # INFO = 0
    INFO = Cint[0]
    mincw = 0  # TODO: check that these are sufficient
    miniw = 0
    minrw = 0
    nS = Cint[0]
    nInf = Cint[0]
    sInf = Cdouble[0]
    lencu = 1
    cu = Array{UInt8}(lencu, 8)
    iu = Int32[0]
    leniu = length(iu)
    ru = [0.0]
    lenru = length(ru)

    # open files for printing
    iprint = PRINTNUM
    isumm = SUMNUM
    printerr = Cint[0]
    sumerr = Cint[0]
    ccall( (:openfiles_, snoptlib), Void,
        (Ref{Cint}, Ref{Cint}, Ptr{Cint}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}),
        iprint, isumm, printerr, sumerr, printfile, sumfile)
    if printerr[1] != 0
        println("failed to open print file")
    end
    if sumerr[1] != 0
        println("failed to open summary file")
    end

    # working arrays
    lencw = 500 + (n+nF)*5
    cw = Array{UInt8}(lencw, 8)
    leniw = 500 + 100*(n+nF)*5
    iw = Array{Int32}(leniw)
    lenrw = 500 + 200*(n+nF)*5
    rw = Array{Float64}(lenrw)


    # compilation command I used (OS X with gfortran):
    # gfortran -shared -O2 *.f *.f90 -o libsnopt.dylib -fPIC -v

    # --- initialize ----
    ccall( (:sninit_, snoptlib), Void,
        (Ref{Cint}, Ref{Cint}, Ptr{UInt8}, Ref{Cint}, Ptr{Cint},
        Ref{Cint}, Ptr{Cdouble}, Ref{Cint}),
        iprint, isumm, cw, lencw, iw,
        leniw, rw, lenrw)
    # println("here")

    # --- set options ----

    errors = Cint[0]

    for key in keys(options)
        value = options[key]
        buffer = string(key, repeat(" ", 55-length(key)))  # buffer length is 55 so pad with space.

        if length(key) > 55
            println("warning: invalid option, too long")
            continue
        end

        errors[1] = 0

        if typeof(value) == String

            value = string(value, repeat(" ", 72-length(value)))

            ccall( (:snset_, snoptlib), Void,
                (Ptr{UInt8}, Ref{Cint}, Ref{Cint}, Ptr{Cint},
                Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint}, Ptr{Cdouble}, Ref{Cint}),
                value, iprint, isumm, errors,
                cw, lencw, iw, leniw, rw, lenrw)

        elseif isinteger(value)

            ccall( (:snseti_, snoptlib), Void,
                (Ptr{UInt8}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ptr{Cint},
                Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint}, Ptr{Cdouble}, Ref{Cint}),
                buffer, value, iprint, isumm, errors,
                cw, lencw, iw, leniw, rw, lenrw)

        elseif isreal(value)

            ccall( (:snsetr_, snoptlib), Void,
                (Ptr{UInt8}, Ref{Cdouble}, Ref{Cint}, Ref{Cint}, Ptr{Cint},
                Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint}, Ptr{Cdouble}, Ref{Cint}),
                buffer, value, iprint, isumm, errors,
                cw, lencw, iw, leniw, rw, lenrw)

        end

        # println(errors[1])

    end

    # --- call snopta ----

    ccall( (:snopta_, snoptlib), Void,
        (Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cdouble},
        Ref{Cint}, Ptr{UInt8}, Ptr{Void}, Ptr{Cint}, Ptr{Cint}, Ref{Cint},
        Ref{Cint}, Ptr{Cdouble}, Ptr{Cint}, Ptr{Cint}, Ref{Cint}, Ref{Cint},
        Ptr{Cdouble}, Ptr{Cdouble}, Ptr{UInt8}, Ptr{Cdouble}, Ptr{Cdouble},
        Ptr{UInt8}, Ptr{Cdouble}, Ptr{Cint}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cint},
        Ptr{Cdouble}, Ptr{Cint}, Ref{Cint}, Ref{Cint}, Ref{Cint}, Ptr{Cint},
        Ptr{Cint}, Ptr{Cdouble}, Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint},
        Ptr{Cdouble}, Ref{Cint}, Ptr{UInt8}, Ref{Cint}, Ptr{Cint}, Ref{Cint},
        Ptr{Cdouble}, Ref{Cint}),
        Start, nF, n, nxname, nFname, ObjAdd,
        ObjRow, Prob, usrfun, iAfun, jAvar, lenA,
        neA, A, iGfun, jGvar, lenG, neG,
        xlow, xupp, xnames, Flow, Fupp,
        Fnames, x, xstate, xmul, F, Fstate,
        Fmul, INFO, mincw, miniw, minrw, nS,
        nInf, sInf, cu, lencu, iu, leniu,
        ru, lenru, cw, lencw, iw, leniw,
        rw, lenrw)

    # println("done")

    # close output files
    ccall( (:closefiles_, snoptlib), Void,
        (Ref{Cint}, Ref{Cint}),
        iprint, isumm)


    return x, F[1], INFO[1], xmul  # xstar, fstar, info

end


end  # end module
