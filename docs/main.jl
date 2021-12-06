import Dates
import GitHub
import JSON

function Repository(repo; since, until, my_auth)
    println("Getting : ", repo)
    return GitHub.issues(
        repo;
        auth = my_auth,
        params = Dict("state" => "all", "since" => since, "until" => until),
    )
end

function get_repos(since, until)
    my_auth = GitHub.authenticate(ENV["PERSONAL_ACCESS_TOKEN"])
    all_repos, _ = GitHub.repos("jump-dev", auth=my_auth);
    return Dict(
        repo => Repository(repo; since = since, until = until, my_auth = my_auth)
        for repo in map(r -> "$(r.name)", all_repos)
    )
end

since = "2013-01-01T00:00:00"
repos = get_repos(since, Dates.now())
data = Dict()
for (k, v) in repos
    if !(endswith(k, ".jl") || k in ("MathOptFormat",))
        continue
    end
    events = Dict{String,Any}[]
    map(v[1]) do issue
        event = Dict(
            "user" => issue.user.login,
            "is_pr" => issue.pull_request !== nothing,
            "type" => "opened",
            "date" => issue.created_at,
        )
        push!(events, event)
        if issue.closed_at !== nothing
            event = copy(event)
            event["type"] = "closed"
            event["date"] = issue.closed_at
            push!(events, event)
        end
        return
    end
    data[k] = sort!(events, by = x -> x["date"])
end

open("data.json", "w") do io
    write(io, JSON.json(data))
end
