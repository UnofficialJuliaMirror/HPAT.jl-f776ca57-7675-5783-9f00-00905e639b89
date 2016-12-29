#=
Copyright (c) 2016, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
THE POSSIBILITY OF SUCH DAMAGE.
=#

function recreate_parfor_pre(body, linfo)
    @dprintln(3,"DistPass recreate_parfor_pre ast", linfo, body)
    lives = computeLiveness(body, linfo)
    # arrays that their allocations added to prev
    pre_alloc_arrs = LHSVar[]
    # for each basic block:
    # for each parfor, find its write array, add allocation to prestatements
    # remove meta and line numbers
    for bb in collect(values(lives.basic_blocks))
        for i in length(bb.statements):-1:1
            stmt = bb.statements[i].tls.expr
            if isBareParfor(stmt)
                parfor = stmt.args[1]
                rws = CompilerTools.ReadWriteSet.from_exprs(parfor.body, ParallelAccelerator.ParallelIR.pir_rws_cb, linfo)
                write_arrays = collect(keys(rws.writeSet.arrays))
                # fix to include reduction variable generated by 2nd gemm pattern
                # TODO: generalize rws somehow, or use liveness instead?
                #if length(parfor.preParFor)>=1 && isCall(parfor.preParFor[1]) &&
                #    parfor.preParFor[1].args[1]==GlobalRef(ParallelAccelerator.API,:set_zeros)
                #    push!(write_arrays, parfor.preParFor[1].args[2])
                #end
                @dprintln(3,"DistPass recreate_parfor_pre parfor found: ", parfor, rws, "\nwrite arrs: ",write_arrays)
                # only parfors with one write supported
                # TODO: generalize?
                if length(write_arrays)==1
                    arr = toLHSVar(write_arrays[1])
                    @dprintln(3,"DistPass recreate_parfor_pre write array: ", arr)
                    for j in i-1:-1:1
                        prev_stmt = bb.statements[j].tls.expr
                        if isAllocationAssignment(prev_stmt) && prev_stmt.args[1]==arr
                            @dprintln(3,"DistPass recreate_parfor_pre allocation for parfor found: ", prev_stmt)
                            parfor.preParFor = [prev_stmt; parfor.preParFor]
                            push!(pre_alloc_arrs, arr)
                            break
                        elseif in(arr,bb.statements[j].use) || in(arr,bb.statements[j].def)
                            break
                        end
                    end
                end
            end
        end
    end
    @dprintln(3,"DistPass recreate_parfor_pre pre_alloc_arrs: ", pre_alloc_arrs)
    out = Any[]
    for i in 1:length(body.args)
        node = body.args[i]
        if !isMeta(node) && !(isAllocationAssignment(node) && in(node.args[1], pre_alloc_arrs))
            push!(out, node)
        end
        if isBareParfor(node)
            fix_parfor_for_fusion(node.args[1], length(out), linfo)
        end
    end
    body.args = out
end

function fix_parfor_for_fusion(parfor::PIRParForAst, new_top_level_number, linfo)
    @dprintln(3,"DistPass fix_parfor_for_fusion parfor ", parfor)
    parfor.top_level_number = [new_top_level_number]
    empty!(parfor.array_aliases)
    # remove array assignment from post statements generated by expanding gemm
    if length(parfor.postParFor)==2 && isa(parfor.postParFor[1],Expr) &&
         parfor.postParFor[1].head==:(=) && isa(parfor.postParFor[1].args[2],LHSVar)
        @assert length(parfor.preParFor)>=1 && isAllocationAssignment(parfor.preParFor[1]) "invalid parfor for expanded gemm matched"
        @dprintln(3,"DistPass fix_parfor_for_fusion remove assignment from expanded gemm ")
        lhs_var = parfor.postParFor[1].args[1]
        out_var = parfor.postParFor[1].args[2]
        replaceExprWithDict!(parfor, Dict{LHSVar,Any}(out_var=>lhs_var), linfo, ParallelIR.AstWalk)
        parfor.postParFor = Any[0]
    end
    # use rws to update first_input, which is used for finding correlation in fusion
    # reverse order to match access array
    parfor_indices = [ toLHSVar(parfor.loopNests[i].indexVariable) for i in length(parfor.loopNests):-1:1 ]
    rws = CompilerTools.ReadWriteSet.from_exprs(parfor.body, ParallelAccelerator.ParallelIR.pir_rws_cb, linfo)
    @dprintln(3,"DistPass fix_parfor_for_fusion parfor indices ", parfor_indices)
    @dprintln(3,"DistPass fix_parfor_for_fusion rws arrays ", union(rws.readSet.arrays, rws.writeSet.arrays))

    for (arr,inds) in union(rws.readSet.arrays, rws.writeSet.arrays)
        # TODO: is this sufficient condition for parfor/array correlation?
        indices = map(x->isa(x,Colon)?x:toLHSVar(x), inds[1])
        if indices==parfor_indices
            @dprintln(3,"DistPass fix_parfor_for_fusion updating first_input.array from ",
                 parfor.first_input.array, " to ", arr)
            parfor.first_input.array = arr
            break
        end
    end
end

function dist_optimize(body::Expr, state::DistPassState)
    @assert body.head==:body "invalid body in dist_optimize"
    out_body = Any[]
    for i in 1:length(body.args)
        new_node = dist_optimize_node(body.args[i], i, state)
        if isa(new_node, Array)
            append!(out_body, new_node)
        else
            push!(out_body, new_node)
        end
    end
    body.args = out_body
    recreate_parfor_pre(body, state.LambdaVarInfo)
    @dprintln(3, "dist_optimize after optimizing but before fusion ", body)
    state.LambdaVarInfo, body = ParallelAccelerator.ParallelIR.fusion_pass("dist_opt", state.LambdaVarInfo, body)
    return body
end

function dist_optimize_node(node::Expr, top_level_number, state)
    @dprintln(3,"DistPass optimize node ", top_level_number, " ", node)
    if isAssignmentNode(node)
        #@dprintln(3,"DistPass optimize assignment: ", node)
        lhs = toLHSVar(node.args[1])
        rhs = node.args[2]
        return dist_optimize_assignment(node, state, top_level_number, lhs, rhs)
    elseif node.head==:parfor
#        if top_level_number == 58
#            return doParforInterchange(node, state)
#        else
        parfor = node.args[1]
        new_body = dist_optimize(Expr(:body, parfor.body...), state)
        parfor.body = new_body.args
        end
    end
    return node
end

function dist_optimize_node(node::ANY, top_level_number, state)
    return node
end

function dist_optimize_assignment(node::Expr, state::DistPassState, top_level_number, lhs::LHSVar, rhs::RHSVar)
    return node
end

function dist_optimize_assignment(node::Expr, state::DistPassState, top_level_number, lhs::LHSVar, rhs::Expr)
    if rhs.head==:call && isBaseFunc(rhs.args[1],:gemm_wrapper!)
        @dprintln(3,"DistPass optimize gemm found: ", node)
        out = toLHSVar(rhs.args[2])
        arr1 = toLHSVar(rhs.args[5])
        t1 = (rhs.args[3]=='T')
        arr2 = toLHSVar(rhs.args[6])
        t2 = (rhs.args[4]=='T')
        # weight multipied by samples (e.g. w*points)
        if isSEQ(arr1,state) && isONE_D(arr2,state) && !t1 && !t2
            @dprintln(3,"DistPass optimize weight times points pattern found")
            return expand_gemm_sp(lhs, out, arr1, arr2, top_level_number, state)
        # labels multipied by samples (e.g. labels*points')
        elseif isSEQ(out,state) && isONE_D(arr1,state) && isONE_D(arr2,state) && !t1 && t2
            @dprintln(3,"DistPass optimize labels times points transpose pattern found")
            return expand_gemm_pp(lhs, out, arr1, arr2, top_level_number, state)
        end
    end
    return node
end

function dist_optimize_assignment(node::Expr, state::DistPassState, top_level_number, lhs::ANY, rhs::ANY)
    return node
end

function expand_gemm_sp(lhs, out, arr1, arr2, top_level_number, state)
    size1 = state.arrs_dist_info[arr2].dim_sizes[end]
    size2 = state.arrs_dist_info[arr1].dim_sizes[1]
    size3 = state.arrs_dist_info[arr1].dim_sizes[end]
    # outer loop over samples, inner loop over functions
    parfor_index1 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_parfor_"*string(getDistNewID(state))*"_index1"), Int, ISASSIGNED,state.LambdaVarInfo))
    parfor_index2 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_parfor_"*string(getDistNewID(state))*"_index2"), Int, ISASSIGNED,state.LambdaVarInfo))
    loop_index = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_loop_"*string(getDistNewID(state))*"_index"), Int, ISASSIGNED,state.LambdaVarInfo))
    elem_typ = eltype(CompilerTools.LambdaHandling.getType(arr1, state.LambdaVarInfo))
    temp_var1 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp1_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))
    temp_var2 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp2_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))
    temp_var3 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp3_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))

    loopNests = PIRLoopNest[ PIRLoopNest(parfor_index1, 1, size1, 1), PIRLoopNest(parfor_index2, 1, size2, 1) ]
    parfor_id = getDistNewID(state)
    first_input_info = InputInfo(out)
    first_input_info.dim = 2
    #first_input_info.indexed_dims = ones(Int64, first_input_info.dim)
    first_input_info.indexed_dims = [true,true] # loop over last dimension
    first_input_info.out_dim = 2
    first_input_info.elementTemp = temp_var2
    out_body = Any[]
    pre_statements  = Any[]
    post_statements = Any[ Expr(:(=), lhs, out), 0 ]

    push!(out_body, Expr(:(=), temp_var3, 0))
    # inner loop k dimension
    push!(out_body, Expr(:loophead, loop_index, 1, size3))
    # tmp1 = w[j,k]
    push!(out_body, Expr(:(=), temp_var1, mk_call(GlobalRef(Base,:unsafe_arrayref),[arr1, parfor_index2, loop_index])))
    # tmp2 = points[k,i]
    push!(out_body, Expr(:(=), temp_var2, mk_call(GlobalRef(Base,:unsafe_arrayref),[arr2, loop_index, parfor_index1])))
    push!(out_body, Expr(:(=), temp_var3, mk_add_float_expr(temp_var3, mk_mult_float_expr(temp_var1,temp_var2))))
    push!(out_body, Expr(:loopend, loop_index))
    push!(out_body, mk_call(GlobalRef(Base,:unsafe_arrayset),[out, temp_var3, parfor_index2, parfor_index1]))

    new_parfor = ParallelAccelerator.ParallelIR.PIRParForAst(
        first_input_info,
        out_body,
        pre_statements,
        loopNests,
        PIRReduction[],
        post_statements,
        [ParallelAccelerator.ParallelIR.DomainOperation(:mmap!,Any[])], # empty domain_oprs
        top_level_number,
        parfor_id,
        Set{LHSVar}(), #arrays_written_past_index
        Set{LHSVar}()) #arrays_read_past_index
    @dprintln(3,"DistPass optimize new_parfor ", new_parfor)
    state.parfor_partitioning[parfor_id] = ONE_D
    state.parfor_arrays[parfor_id] = [lhs,arr2]
    return Expr(:parfor, new_parfor)
end

function expand_gemm_pp(lhs, out, arr1, arr2, top_level_number, state)
    size1 = state.arrs_dist_info[arr2].dim_sizes[end]
    size2 = state.arrs_dist_info[arr1].dim_sizes[1]
    size3 = state.arrs_dist_info[out].dim_sizes[end]
    # outer loop over samples, inner loop over functions
    parfor_index1 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_parfor_"*string(getDistNewID(state))*"_index1"), Int, ISASSIGNED,state.LambdaVarInfo))
    parfor_index2 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_parfor_"*string(getDistNewID(state))*"_index2"), Int, ISASSIGNED,state.LambdaVarInfo))
    loop_index = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_loop_"*string(getDistNewID(state))*"_index"), Int, ISASSIGNED,state.LambdaVarInfo))
    elem_typ = eltype(CompilerTools.LambdaHandling.getType(arr1, state.LambdaVarInfo))
    temp_var1 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp1_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))
    temp_var2 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp2_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))
    temp_var3 = toLHSVar(CompilerTools.LambdaHandling.addLocalVariable(
        Symbol("_dist_gemm_tmp3_"*string(getDistNewID(state))), elem_typ, ISASSIGNED | ISPRIVATEPARFORLOOP, state.LambdaVarInfo))

    loopNests = PIRLoopNest[ PIRLoopNest(parfor_index1, 1, size1, 1), PIRLoopNest(parfor_index2, 1, size2, 1) ]

    parfor_id = getDistNewID(state)
    first_input_info = InputInfo(arr2)
    first_input_info.dim = 2
    #first_input_info.indexed_dims = ones(Int64, first_input_info.dim)
    first_input_info.indexed_dims = [true,false] # loop over last dimension
    first_input_info.out_dim = 1
    first_input_info.elementTemp = temp_var2
    out_body = Any[]
    pre_statements  = Any[ mk_call(GlobalRef(ParallelAccelerator.API,:set_zeros),[out]) ]
    post_statements = Any[ Expr(:(=), lhs, out), 0 ]

    # tmp2 = labels[j,i]
    push!(out_body, Expr(:(=), temp_var2, mk_call(GlobalRef(Base,:unsafe_arrayref),[arr1, parfor_index2, parfor_index1])))
    # inner loop k dimension
    push!(out_body, Expr(:loophead, loop_index, 1, size3))
    # tmp1 = points[k,i]
    push!(out_body, Expr(:(=), temp_var1, mk_call(GlobalRef(Base,:unsafe_arrayref),[arr2, loop_index, parfor_index1])))
    # tmp3 = w[j,w]
    push!(out_body, Expr(:(=), temp_var3, mk_call(GlobalRef(Base,:unsafe_arrayref),[out, parfor_index2, loop_index])))
    push!(out_body, Expr(:(=), temp_var3, mk_add_float_expr(temp_var3, mk_mult_float_expr(temp_var1,temp_var2))))
    push!(out_body, mk_call(GlobalRef(Base,:unsafe_arrayset),[out, temp_var3, parfor_index2, loop_index]))
    push!(out_body, Expr(:loopend, loop_index))

    new_parfor = ParallelAccelerator.ParallelIR.PIRParForAst(
        first_input_info,
        out_body,
        pre_statements,
        loopNests,
        [PIRReduction(out, 0, GlobalRef(Base,:(+)))],
        post_statements,
        [ParallelAccelerator.ParallelIR.DomainOperation(:mmap!,Any[])], # empty domain_oprs
        top_level_number,
        parfor_id,
        Set{LHSVar}(), #arrays_written_past_index
        Set{LHSVar}()) #arrays_read_past_index
    @dprintln(3,"DistPass optimize new_parfor ", new_parfor)
    state.parfor_partitioning[parfor_id] = ONE_D
    state.parfor_arrays[parfor_id] = [lhs,arr2]
    return Expr(:parfor, new_parfor)
end


function genLoopHeadFromParfor(parfor)
    ret = Any[]

    for i = 1:length(parfor.loopNests)
        push!(ret, Expr(:loophead, parfor.loopNests[i].indexVariable, parfor.loopNests[i].lower, parfor.loopNests[i].upper))
    end

    return ret
end

function genLoopEndFromParfor(parfor)
    ret = Any[]

    for i = length(parfor.loopNests):-1:1
        push!(ret, Expr(:loopend, parfor.loopNests[i].indexVariable))
    end

    return ret
end

function getParforIndices(parfor)
    ret = Any[]

    for i = 1:length(parfor.loopNests)
        push!(ret, parfor.loopNests[i].indexVariable)
    end

    return ret
end

function genAddInt(x, val)
    return Expr(:call, GlobalRef(Base, :box), Int64, Expr(:call, GlobalRef(Base, :add_int), deepcopy(x), deepcopy(val)))
end
function genSubInt(x, val)
    return Expr(:call, GlobalRef(Base, :box), Int64, Expr(:call, GlobalRef(Base, :sub_int), deepcopy(x), deepcopy(val)))
end

function getParforSizes(parfor)
    ret = Union{RHSVar,Int,Expr}[]

    for i = 1:length(parfor.loopNests)
        if parfor.loopNests[i].step != 1
            throw(string("Skip not yet supported in getParforSizes."))
        end

        if parfor.loopNests[i].lower == 1
            push!(ret, deepcopy(parfor.loopNests[i].upper))
        else
            push!(ret, genAddInt(genSubInt(parfor.loopNests[i].upper, parfor.loopNests[i].lower), 1))
        end
    end

    return ret
end

type InterchangeState
    index_vars
    to_array
end

function interchangeArrayify(node::LHSVar, state::InterchangeState, top_level_number, is_top_level, read)
    if haskey(state.to_array, node)
        if read
            return Expr(:call, GlobalRef(Base, :arrayref), state.to_array[node], state.index_vars...)
        else
            throw(string("Don't handle case of write to arrayified symbol outside lhs of assignment."))
        end
    end
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function interchangeArrayify(node::ANY, state::InterchangeState, top_level_number, is_top_level, read)
    return CompilerTools.AstWalker.ASTWALK_RECURSE
end

function doParforInterchange(parfor_node::Expr, state::DistPassState)
    @dprintln(3, "doParforInterchange ", parfor_node, " ", state)
    ret = Any[]
    new_array_allocs = Any[]
    for_pre = Any[]
    num_inner = 0

    outer_parfor = parfor_node.args[1]

    body_lives = CompilerTools.LivenessAnalysis.from_lambda(state.LambdaVarInfo, outer_parfor.body, ParallelIR.pir_live_cb, state.LambdaVarInfo)
    @dprintln(3, "body_lives = ", body_lives)
    non_nested_region = true

    index_vars = reverse(getParforIndices(outer_parfor))
    sizes = reverse(getParforSizes(outer_parfor))
    num_dims = length(index_vars)
    @dprintln(3, "index_vars = ", index_vars, " num_dims = ", num_dims, " sizes = ", sizes)

    to_array = Dict{LHSVar,LHSVar}()

    append!(for_pre, genLoopHeadFromParfor(outer_parfor))

    for i = 1:length(outer_parfor.body)
        node = outer_parfor.body[i]
        @dprintln(3, "Processing ", node, " ", non_nested_region)

        if ParallelAccelerator.ParallelIR.isParforAssignmentNode(node)
            throw(string("Parfor assignment nodes not yet supported in doParforInterchange."))
        elseif ParallelAccelerator.ParallelIR.isBareParfor(node)
            num_inner += 1
            if num_inner > 1
                @dprintln(1, "Multiple nested inner parfors not supported so reverting to original parfor.")
                return parfor_node
            end

            @dprintln(3, "isBareParfor ", non_nested_region)
            if non_nested_region
                append!(for_pre, genLoopEndFromParfor(outer_parfor))
                non_nested_region = false
            end
            inner_parfor = node.args[1]
            @dprintln(3, "isBareParfor ", non_nested_region, " ", inner_parfor)
            new_outer_parfor = deepcopy(inner_parfor)
            new_inner_parfor = deepcopy(outer_parfor)
            new_inner_parfor.body = deepcopy(inner_parfor.body)
            new_outer_parfor.body = Any[Expr(:parfor, new_inner_parfor)]
            new_outer_parfor.top_level_number = deepcopy(outer_parfor.top_level_number)
            for j = 1:length(new_outer_parfor.reductions)
                @dprintln(3, "Processing reduction ",  new_outer_parfor.reductions[j])
                rdsvar = toLHSVar(new_outer_parfor.reductions[j].reductionVar)
                if haskey(to_array, rdsvar)
                    new_outer_parfor.reductions[j].reductionVar = to_array[rdsvar]
                    @dprintln(3, "Changed to ",  new_outer_parfor.reductions[j])
                else
                    throw(string("During parfor interchange, reduction variable ", rdsvar, " on inner parfor did not become an array during interchange."))
                end
            end
            for j = 1:length(new_inner_parfor.body)
                inner_node = new_inner_parfor.body[j]
                @dprintln(3, "Processing inner parfor body node ", inner_node)

                if isAssignmentNode(inner_node)
                    lhs = toLHSVar(inner_node.args[1])
                    rhs = inner_node.args[2]
                    @dprintln(3, "Assignment node: ", lhs)
                    if haskey(to_array, lhs)
                        new_rhs = deepcopy(rhs)
                        new_inner_parfor.body[j] = Expr(:call, GlobalRef(Base, :arrayset), to_array[lhs], ParallelIR.AstWalk(new_rhs, interchangeArrayify, InterchangeState(index_vars, to_array)), index_vars...)
                    else
                        acopy = deepcopy(inner_node)
                        new_inner_parfor.body[j] = ParallelIR.AstWalk(acopy, interchangeArrayify, InterchangeState(index_vars, to_array))
                    end
                else
                    acopy = deepcopy(inner_node)
                    new_inner_parfor.body[j] = ParallelIR.AstWalk(acopy, interchangeArrayify, InterchangeState(index_vars, to_array))
                end
            end
            append!(new_outer_parfor.preParFor, for_pre)
            push!(ret, Expr(:parfor, new_outer_parfor))
        else
            @dprintln(3, "Node is not a parfor ", non_nested_region)
            if !non_nested_region
                append!(ret, genLoopHeadFromParfor(outer_parfor))
                non_nested_region = true
            end

            if isAssignmentNode(node)
                lhs = toLHSVar(node.args[1])
                rhs = node.args[2]
                @dprintln(3, "Assignment node: ", lhs)
                if !haskey(to_array, lhs)
                    lhs_type = CompilerTools.LambdaHandling.getType(lhs, state.LambdaVarInfo)
                    atype = Array{lhs_type, num_dims}
                    new_array_name = Symbol(string("HPAT_",lhs,"_",outer_parfor.unique_id))
                    CompilerTools.LambdaHandling.addLocalVariable(new_array_name, atype, ISASSIGNED, state.LambdaVarInfo)
                    new_array_lhsvar = toLHSVar(new_array_name, state.LambdaVarInfo)
                    @dprintln(3, "New array needed: ", lhs, " ", lhs_type, " ", new_array_name)
                    push!(new_array_allocs, ParallelAccelerator.ParallelIR.mk_assignment_expr(new_array_lhsvar, ParallelAccelerator.ParallelIR.mk_alloc_array_expr(lhs_type, atype, sizes...), state.LambdaVarInfo))
                    @dprintln(3, "new_array_allocs = ", new_array_allocs)
                    to_array[lhs] = new_array_lhsvar
                    @dprintln(3, "to_array = ", to_array)
                    state.arrs_dist_info[new_array_lhsvar] = ArrDistInfo(num_dims)
                    state.arrs_dist_info[new_array_lhsvar].partitioning = SEQ
                    state.arrs_dist_info[new_array_lhsvar].dim_sizes = sizes
                end
                new_rhs = deepcopy(rhs)
                push!(num_inner == 0 ? for_pre : ret, Expr(:call, GlobalRef(Base, :arrayset), new_array_lhsvar, ParallelIR.AstWalk(new_rhs, interchangeArrayify, InterchangeState(index_vars, to_array)), index_vars...))
            else
                acopy = deepcopy(node)
                push!(num_inner == 0 ? for_pre : ret, ParallelIR.AstWalk(acopy, interchangeArrayify, InterchangeState(index_vars, to_array)))
            end
        end
    end

    if non_nested_region
        append!(ret, genLoopEndFromParfor(outer_parfor))
    end

    @dprintln(3, "Output new_array_allocs = ", new_array_allocs)
    @dprintln(3, "Output regular code = ", ret)

    return [new_array_allocs..., ret...]
end

