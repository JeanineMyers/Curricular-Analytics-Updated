using MultiJuMP, JuMP
using Gurobi
using LinearAlgebra
using LightGraphs
using CSV
using DataFrames
include("CSVUtilities.jl")
#using MathOptInterface
#const MOI = JuMP.MathOptInterface
function getVertex(courseID, curric)
    for course in curric.courses
        if course.id == courseID
            return course.vertex_id[curric.id]
        end
    end
    return 0
end

function find_min_terms_opt(curric::Curriculum, additional_courses::Array{Course}=Array{Course,1}(); 
    min_terms::Int=1, max_terms::Int, max_credits_per_term::Int)
    m = Model(with_optimizer(Gurobi.Optimizer))
    courses = curric.courses
    credit = [c.credit_hours for c in curric.courses]
    c_count = length(courses)
    mask = [i for i in 1:max_terms]
    @variable(m, x[1:c_count, 1:max_terms], Bin)
    terms = [sum(dot(x[k,:],mask)) for k = 1:c_count]
    vertex_map = Dict{Int,Int}(c.id => c.vertex_id[curric.id] for c in curric.courses)
    @constraints m begin
        #output must include all courses once
        tot[i=1:c_count], sum(x[i,:]) == 1
        #Each term must include more or equal than min credit and less or equal than max credit allowed for a term
        term[j=1:max_terms], sum(dot(credit,x[:,j])) <= max_credits_per_term
    end
    for c in courses
        for req in c.requisites
            if req[2] == pre
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))-1))
            elseif req[2] == co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            elseif req[2] == strict_co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) == (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            else
                println("req type error")
            end
        end   
    end
    @objective(m, Min, sum(terms[:]))
    status = optimize!(m)
    output = value.(x)
    if termination_status(m) == MOI.OPTIMAL
        optimal_terms = Term[]
        for j=1:max_terms
            if sum(dot(credit,output[:,j])) > 0 
                term = Course[]
                for course in 1:length(courses)
                    if round(output[course,j]) == 1
                        push!(term, courses[course])
                    end 
                end
                push!(optimal_terms, Term(term))
            end
        end
        return true, optimal_terms, length(optimal_terms)
    end
    return false, nothing, nothing
end
function balance_terms_opt(curric::Curriculum, additional_courses::Array{Course}=Array{Course,1}();       
    min_terms::Int=1, max_terms::Int,min_credits_per_term::Int=1, max_credits_per_term::Int)
    m = Model(with_optimizer(Gurobi.Optimizer))
    courses = curric.courses
    credit = [c.credit_hours for c in curric.courses]
    c_count = length(courses)
    mask = [i for i in 1:max_terms]
    @variable(m, x[1:c_count, 1:max_terms], Bin)
    terms = [sum(dot(x[k,:],mask)) for k = 1:c_count]
    vertex_map = Dict{Int,Int}(c.id => c.vertex_id[curric.id] for c in curric.courses)
    total_credit_term = [sum(dot(credit,x[:,j])) for j=1:max_terms]
    @variable(m, 0 <= y[1:max_terms] <= max_credits_per_term)
    @constraints m begin
        #output must include all courses once
        tot[i=1:c_count], sum(x[i,:]) == 1
        #Each term must include more or equal than min credit and less or equal than max credit allowed for a term
        term_upper[j=1:max_terms], sum(dot(credit,x[:,j])) <= max_credits_per_term
        term_lower[j=1:max_terms], sum(dot(credit,x[:,j])) >= min_credits_per_term
        abs_val[i=2:max_terms], y[i] >= total_credit_term[i]-total_credit_term[i-1]
        abs_val2[i=2:max_terms], y[i] >= -(total_credit_term[i]-total_credit_term[i-1])
    end
    for c in courses
        for req in c.requisites
            if req[2] == pre
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))-1))
            elseif req[2] == co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            elseif req[2] == strict_co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) == (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            else
                println("req type error")
            end
        end   
    end
    @objective(m, Min, sum(y[:]))
    status = optimize!(m)
    output = value.(x)
    if termination_status(m) == MOI.OPTIMAL
        optimal_terms = Term[]
        for j=1:max_terms
            if sum(dot(credit,output[:,j])) > 0 
                term = Course[]
                for course in 1:length(courses)
                    if round(output[course,j]) == 1
                        push!(term, courses[course])
                    end 
                end
                push!(optimal_terms, Term(term))
            end
        end
        return true, optimal_terms, length(optimal_terms)
    end
    return false, nothing, nothing
end

function term_count_obj(m, mask, x, c_count, multi=true)
    terms = [sum(dot(x[k,:],mask)) for k = 1:c_count]
    if multi
        exp = @expression(m, sum(terms[:]))
        obj = SingleObjective(exp, sense = :Min)
        return obj
    else
        @objective(m, Min, sum(terms[:]))
        return true
    end
    
end
function balance_obj(m, max_credits_per_term,termCount,x,y,credit, multi=true)
    total_credit_term = [sum(dot(credit,x[:,j])) for j=1:termCount]
    @constraints m begin
        abs_val[i=2:termCount], y[i] >= total_credit_term[i]-total_credit_term[i-1]
        abs_val2[i=2:termCount], y[i] >= -(total_credit_term[i]-total_credit_term[i-1])
    end
    if multi
        exp = @expression(m, sum(y[:]))
        obj = SingleObjective(exp, sense = :Min)
        return obj
    else
        @objective(m, Min, sum(y[:]))
        return true
    end
end

function toxicity_obj(toxic_score_file, m, c_count, curric, termCount,x,ts, multi=true)
    toxicFile = readfile(toxic_score_file)
    comboDict = Dict()
    for coursePair in toxicFile[2:end] 
        coursePair = split(coursePair, ",")
        comboDict[replace(coursePair[1], " "=> "")*"_"*replace(coursePair[2], " "=> "")] = parse(Float64,coursePair[9])+1
    end
    toxicity_scores = zeros((c_count, c_count))
    for course in curric.courses
        for innerCourse in curric.courses
            if course != innerCourse 
                if course.prefix*course.num*"_"*innerCourse.prefix*innerCourse.num in keys(comboDict)
                    toxicity_scores[course.vertex_id[curric.id],innerCourse.vertex_id[curric.id]] = comboDict[course.prefix*course.num*"_"*innerCourse.prefix*innerCourse.num]
                end
            end
        end
    end
    for j=1:termCount
        push!(ts, sum((toxicity_scores .* x[:,j]) .* x[:,j]'))
    end
    if multi
        exp = @expression(m, sum(ts[:]))
        obj = SingleObjective(exp, sense = :Min)
        return obj
    else
        @objective(m, Min, sum(ts[:]))
        return true
    end

end

function prereq_obj(m, mask, x, graph, total_distance,  multi=true)
    for edge in collect(edges(graph))
        push!(total_distance, sum(dot(x[dst(edge),:],mask)) - sum(dot(x[src(edge),:],mask)))
    end
    if multi
        exp = @expression(m, sum(total_distance[:]))
        obj = SingleObjective(exp, sense = :Min)
        return obj
    else
        @objective(m, Min, sum(total_distance[:]))
        return true
    end
end

function optimize_plan(config_file, curric_file, toxic_score_file)
    consequtiveCourses, fixedCourses, termRange, termCount, min_credits_per_term, max_credits_per_term, obj_order = 
        read_Opt_Config(config_file)
    curric = read_csv(curric_file)

    m = Model(solver = GurobiSolver())
    multi = length(obj_order) > 1
    if multi
        m = multi_model(solver = GurobiSolver(), linear = true)
    end
    println("Number of courses in curriculum: "*string(length(curric.courses)))
    println("Total credit hours: "*string(total_credits(curric)))
    
    courses = curric.courses
    c_count = length(courses)
    vertex_map = Dict{Int,Int}(c.id => c.vertex_id[curric.id] for c in curric.courses)
    
    credit = [c.credit_hours for c in curric.courses]
    mask = [i for i in 1:termCount]
    @variable(m, x[1:c_count, 1:termCount], Bin)
    @variable(m, 0 <= y[1:termCount] <= max_credits_per_term)
    ts=[]
    total_distance = []
    for c in courses
        for req in c.requisites
            if req[2] == pre
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))-1))
            elseif req[2] == co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) <= (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            elseif req[2] == strict_co
                @constraint(m, sum(dot(x[vertex_map[req[1]],:],mask)) == (sum(dot(x[c.vertex_id[curric.id],:],mask))))
            else
                println("req type error")
            end
        end   
    end
    @constraints m begin
        #output must include all courses once
        tot[i=1:c_count], sum(x[i,:]) == 1
        #Each term must include more or equal than min credit and less or equal than max credit allowed for a term
        term_upper[j=1:termCount], sum(dot(credit,x[:,j])) <= max_credits_per_term
        term_lower[j=1:termCount], sum(dot(credit,x[:,j])) >= min_credits_per_term
    end
    if length(keys(fixedCourses)) > 0
        for courseID in keys(fixedCourses)
            vID = getVertex(courseID, curric)
            if vID != 0
                @constraint(m, x[vID,fixedCourses[courseID]] >= 1)
            else
                println("Vertex ID cannot be found for course: "* courseName)
            end
        end
    end
    if length(keys(consequtiveCourses)) > 0
        for (first, second) in consequtiveCourses
            vID_first = getVertex(first, curric)
            vID_second = getVertex(second, curric)
            if vID_first != 0 && vID_second != 0
                @constraint(m, sum(dot(x[vID_second,:],mask)) - sum(dot(x[vID_first,:],mask)) <= 1)
                @constraint(m, sum(dot(x[vID_second,:],mask)) - sum(dot(x[vID_first,:],mask)) >= 1)
            else
                println("Vertex ID cannot be found for course: "* first * " or " * second)
            end
        end
    end
    if length(keys(termRange)) > 0
        for (courseID,(lowTerm, highTerm)) in termRange
            vID_Course = getVertex(courseID, curric)
            if vID_Course != 0
                @constraint(m, sum(dot(x[vID_Course,:],mask)) >= lowTerm)
                @constraint(m, sum(dot(x[vID_Course,:],mask)) <= highTerm)
            end
        end
    end
    """objectives = []
    if "Toxicity" in obj_order
        obj=toxicity_obj(toxic_score_file, m,c_count, curric ,termCount, x,ts, multi)
        if multi
            push!(objectives,obj)
        end
    end
    if "Balance" in obj_order
        obj=balance_obj(m,max_credits_per_term, termCount, x,y, credit, multi)
        if multi
            push!(objectives,obj)
        end
    end
    if "Prereq" in obj_order
        obj=prereq_obj(m, mask, x, curric.graph, total_distance, multi)
        if multi
            push!(objectives,obj)
        end
    end
    if multi
        multim = get_multidata(m)
        print(obj_order)
        obj_dict = Dict("Toxicity"=>1,"Balance"=>2,"Prereq"=>3)
        obj_order_ = [obj_dict[x] for x in obj_order]
        multim.objectives = objectives[obj_order_]
    end"""
    if multi
        objectives =[]
        for objective in obj_order
            if objective == "Toxicity"
                push!(objectives, toxicity_obj(toxic_score_file, m,c_count, curric ,termCount, x,ts, multi))
            end
            if objective == "Balance"
                push!(objectives, balance_obj(m,max_credits_per_term, termCount, x,y, credit, multi))
            end
            if objective == "Prereq"
                push!(objectives, prereq_obj(m, mask, x, curric.graph, total_distance, multi))
            end
        end
        multim = get_multidata(m)
        multim.objectives = objectives
    else
        if obj_order[1] == "Toxicity"
            toxicity_obj(toxic_score_file, m,c_count, curric ,termCount, x,ts, multi)
        end
        if obj_order[1] == "Balance"
            balance_obj(m,max_credits_per_term, termCount, x,y, credit, multi)
        end
        if obj_order[1] == "Prereq"
            prereq_obj(m, mask, x, curric.graph, total_distance, multi)
        end
    end
    status = solve(m)
    if status == :Optimal
        output = getvalue(x)
        if "Balance" in obj_order
            println(sum(getvalue(y)))
        end
        if "Toxicity" in obj_order
            println(sum(getvalue(ts)))
        end
        if "Prereq" in obj_order
            println(sum(getvalue(total_distance)))
        end
        #println(ts)
        optimal_terms = Term[]
        for j=1:termCount
            if sum(dot(credit,output[:,j])) > 0 
                term = Course[]
                for course in 1:length(courses)
                    if round(output[course,j]) == 1
                        push!(term, courses[course])
                    end 
                end
                push!(optimal_terms, Term(term))
            end
        end
        dp = DegreePlan("", curric, optimal_terms)
        visualize(dp, notebook=true)
    else
        println("not optimal")
    end
end