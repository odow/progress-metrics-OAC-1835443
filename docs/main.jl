import CSV
import DataFrames
import Dates
import Downloads
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

function download_stats(file)
    url = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/$(file).csv.gz"
    output = "data/$(file).csv.gz"
    Downloads.download(url, output)
    return output
end

function load_stats(file, uuids)
    out = download_stats(file)
    df = CSV.read(out, DataFrames.DataFrame)
    uuid_to_name = DataFrames.DataFrame(
        package_uuid = collect(keys(uuids)),
        name = collect(values(uuids))
    )
    df = leftjoin(df, uuid_to_name; on = :package_uuid)
    filter!(df) do row
        return !ismissing(row.client_type) &&
               row.client_type == "user" &&
               !ismissing(row.name) &&
               occursin("jump-dev/", row.name) &&
               row.status == 200
    end
    return select(df, [:name, :date, :request_count])
end

function update_download_statistics()
    pkg_uuids = Dict{String,String}()
    depot = Pkg.depots1()
    for (root, dirs, files) in walkdir(joinpath(depot, "registries/General"))
        for dir in dirs
            file = joinpath(root, dir, "Package.toml")
            if !isfile(file)
                continue
            end
            data = TOML.parsefile(joinpath(root, dir, "Package.toml"))
            repo = replace(data["repo"], ".git" => "")
            pkg_uuids[data["uuid"]] = replace(repo, "https://github.com/" => "")
        end
    end
    df = load_stats("package_requests_by_region_by_date", pkg_uuids)
    new_df = sort!(
        combine(groupby(df, [:name, :date]), :request_count => sum),
    )
    data = Dict{String,Dict{String,Any}}()
    for g in groupby(new_df, :name)
        key = replace(g[1, :name], "jump-dev/" => "")
        data[key] = Dict{String,Any}(
            "dates" => string.(collect(g.date)),
            "requests" => collect(g.request_count_sum),
        )
    end
    open("download_stats.json", "w") do io
        write(io, JSON.json(data))
    end
    return
end

function update_package_statistics()
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
    return
end

update_download_statistics()
update_package_statistics()
