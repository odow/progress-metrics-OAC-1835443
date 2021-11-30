import CSV
import DataFrames
import Dates
import GitHub
import HTTP
import JSON
import Pkg
import Plots

const ALTERNATE_NAMES = Dict(
    "jump-dev/JuMP.jl" => ["JuliaOpt/JuMP.jl"],
    "jump-dev/MathOptInterface.jl" => ["JuliaOpt/MathOptInterface.jl"],
)


function data_dir(filename::String)
    if endswith(filename, ".csv")
        return joinpath("data", "csv", filename)
    elseif endswith(filename, ".json")
        return joinpath("data", "json", filename)
    elseif endswith(filename, ".pdf")
        return joinpath("data", "pdf", filename)
    else
        return filename
    end
end

esc_repo_name(repo) = replace(replace(repo, "/" => "_"), "." => "_")

"""
    build_issue_dataset(repo, my_auth)

Return a DataFrame containing a list of all GitHub issues and pull requests.
(GitHub's web API treats PRs as issues.)

## DataFrame columns

 * number
 * title
 * login
 * created_at
 * closed_at
 * is_pr
"""
function build_issue_dataset(repo, my_auth, force = true)
    @show repo
    esc_repo = esc_repo_name(repo)
    if !force && isfile(data_dir(esc_repo * ".csv"))
        return
    end
    @info "Summarizing issues of $(repo)"
    issues, _ = GitHub.issues(
        repo;
        auth = my_auth,
        params = Dict("state" => "all"),
    )
    _replace_nothing(x) = x
    _replace_nothing(::Nothing) = ""
    df = DataFrames.DataFrame(
        number = map(i -> i.number, issues),
        title = map(i -> i.title, issues),
        login = map(i -> i.user.login, issues),
        created_at = map(i -> i.created_at, issues),
        closed_at = map(i -> _replace_nothing(i.closed_at), issues),
        is_pr = map(i -> i.pull_request !== nothing, issues),
    )
    CSV.write(data_dir(esc_repo * ".csv"), df)
    return
end

"""
    number_open(df, is_pr, year)

Given the `df` from `build_issue_dataset`, return a count of the number of open
issues (if `!is_pr`) or pull requests (if `is_pr`) that were created before
December 31 of `year`.
"""
function number_open(df, is_pr, year)
    return sum(
        (df[!, :created_at] .<= Dates.Date(year, 12, 31)) .&
        (df[!, :is_pr] .== is_pr)
    )
end

"""
    number_users(df, is_pr, year)

Given the `df` from `build_issue_dataset`, return a count of the number of users
who opened an issue (if `!is_pr`) or pull request (if `is_pr`) that was created
before December 31 of `year`.
"""
function number_users(df, is_pr, year)
    return length(
        unique(
            df[
                (df[!, :created_at] .<= Dates.Date(year, 12, 31)) .&
                (df[!, :is_pr] .== is_pr),
                :login
            ]
        )
    )
end

"""
    get_stargazers(repo, auth)

Return a list of dates at which the repository `repo` was starred.

## Examples

```julia

my_auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
get_stargazers("jump-dev/JuMP.jl", my_auth)
"""
function get_stargazers(repo::String, auth::GitHub.OAuth2)
    stars, _ = GitHub.gh_get_paged_json(
        GitHub.DEFAULT_API,
        "/repos/$(GitHub.name(repo))/stargazers";
        auth = auth,
        headers = Dict(
            "Accept" => "application/vnd.github.v3.star+json"
        )
    )
    return map(s -> Dates.Date(s["starred_at"], "YYYY-mm-ddTHH:MM:SSZ"), stars)
end

"""
    get_uuid(registry::String, repo::String)

Walk the registry located at the path `registry` until the repository `repo` is
found, and return the corresponding package UUID.
"""
function get_uuid(registry::String, repo::String)
    for (root, dirs, files) in walkdir(registry)
        filename = if "Package.toml" in files
            joinpath(root, "Package.toml")
        elseif "package.toml" in files
            joinpath(root, "package.toml")
        else
            continue
        end
        pkg = Pkg.TOML.parsefile(filename)
        if occursin(repo, pkg["repo"])
            return pkg["uuid"]
        elseif haskey(ALTERNATE_NAMES, repo)
            if any(v -> occursin(v, pkg["repo"]), ALTERNATE_NAMES[repo])
                return pkg["uuid"]
            end
        end
    end
    @warn "No UUID found for $(repo)"
    return ""
end

function uuid_to_name(registry::String)
    d = Dict{String, String}()
    for (root, dirs, files) in walkdir(registry)
        filename = if "Package.toml" in files
            joinpath(root, "Package.toml")
        elseif "package.toml" in files
            joinpath(root, "package.toml")
        else
            continue
        end
        pkg = Pkg.TOML.parsefile(filename)
        d[pkg["uuid"]] = url_to_name(pkg["repo"])
    end
    return d
end

"""
    url_to_name(url::String)

Given a url, return the corresponding Julia package name.

## Examples

```julia
> url_to_name("https://github.com/jump-dev/JuMP.jl.git")
jump-dev/JuMP.jl
```
"""
function url_to_name(url::String)
    m = match(r"https://github.com/(.+).git", url)
    if m !== nothing
        return String(m[1])
    end
    m = match(r"https://GitHub.com/(.+).git", url)
    return m === nothing ? "" : String(m[1])
end

"""
    list_of_dependencies(
        registry::String,
        repo::String,
        uuid_to_repo = Dict{String, String}();
        recursive = true,
    )

Extract all registered dependencies of `repo` located in the local registry
located at `registry`.
"""
function list_of_dependencies(
    registry::String,
    repo::String,
    uuid_to_repo = Dict{String, String}();
    recursive = true,
)
    uuid = get_uuid(registry, repo)
    if isempty(uuid)
        return String[]
    end
    uuid_to_repo[uuid] = repo
    for (root, dirs, files) in walkdir(registry)
        latest = true
        if "Deps.toml" in files
            latest = true
        elseif "dependencies.toml" in files
            latest = false
        else
            continue
        end
        deps_file = joinpath(root, latest ? "Deps.toml" : "dependencies.toml")
        pkg_file = joinpath(root, latest ? "Package.toml" : "package.toml")
        deps = Pkg.TOML.parsefile(deps_file)
        latest_key = if any(k -> endswith(k, "-1"), collect(keys(deps)))
            "1"
        elseif any(k -> endswith(k, "-0"), collect(keys(deps)))
            "0"
        else  # General changed how they represent these during 2019 :(
            split_key = sort([String(split(key, "-")[end]) for key in keys(deps)])
            length(split_key) > 0 ? split_key[end] : ""
        end
        for (key, val) in deps
            # Only add as a dependent if the most-recent version uses it!
            if !(key == latest_key || endswith(key, "-" * latest_key))
                continue
            # elseif uuid in values(val)  # direct dependencies only
            elseif any(k -> k in values(val), keys(uuid_to_repo))  # include transitive
                pkg = Pkg.TOML.parsefile(pkg_file)
                uuid_to_repo[pkg["uuid"]] = String(pkg["repo"])
            end
        end
    end
    if recursive
        n = 0
        while n != length(uuid_to_repo)
            n = length(uuid_to_repo)
            list_of_dependencies(
                registry,
                repo,
                uuid_to_repo;
                recursive = false,
            )
        end
    end
    return sort(
        unique(filter(d -> !isempty(d), url_to_name.(values(uuid_to_repo))))
    )
end

"""
    checkout_registry(f::Function, registry::String, year::Int)

Uses Git to checkout the registry to December 31, `year`. Restores the registry
to `master` on exit.

 ## Examples

```julia
checkout_registry("/Users/Oscar/.julia/registries/General", 2018) do
    # Stuff with registry as at December 31, 2018.
end
"""
function checkout_registry(
    f::Function,
    registry::String,
    year::Int,
)
    current_directory = pwd()
    io = IOBuffer()
    @info "Checking out $(year)"
    try
        cd(registry)
        run(pipeline(`git checkout master`))
        run(pipeline(`git pull`))
        cmd = `git rev-list -n 1 --first-parent --before="$(year + 1)-01-01 00:00" master`
        seekstart(io)
        run(pipeline(cmd; stdout = io))
        seekstart(io)
        git_sha = strip(read(io, String))
        @show git_sha
        run(pipeline(`git checkout $(git_sha)`; stdout = io))
        cd(current_directory)
        return f()
    catch ex
        rethrow(ex)
    finally
        cd(registry)
        run(pipeline(`git checkout master`; stdout = io))
        cd(current_directory)
    end
end

# function compare_years(set_a, set_b)
#     println("Packages added:")
#     for b in set_b
#         if !(b in set_a)
#             println("  ", b)
#         end
#     end
#     println("Packages removed:")
#     for a in set_a
#         if !(a in set_b)
#             println("  ", a)
#         end
#     end
# end

# function dependency_graph(registry, repo, year)
#     uuid_to_name_d = uuid_to_name(registry)
#     uuid = get_uuid(registry, repo)
#     dependents = Set{String}()
#     push!(dependents, uuid)
#     latest = String[uuid]
#     while length(latest) > 0
#         recently_added = copy(latest)
#         # @show recently_added
#         empty!(latest)
#         uuids = _direct_dependents(registry, recently_added, uuid_to_name_d)
#         for u in uuids
#             if !(u in dependents)
#                 push!(dependents, u)
#                 push!(latest, u)
#             end
#         end
#     end
#     return [uuid_to_name_d[d] for d in dependents]
# end

# function _direct_dependents(registry, recently_added, uuid_to_name)
#     dependents = String[]
#     for (root, dirs, files) in walkdir(registry)
#         latest = true
#         if "Deps.toml" in files
#             latest = true
#         elseif "dependencies.toml" in files
#             latest = false
#         else
#             continue
#         end
#         deps_file = joinpath(root, latest ? "Deps.toml" : "dependencies.toml")
#         pkg_file = joinpath(root, latest ? "Package.toml" : "package.toml")
#         deps = Pkg.TOML.parsefile(deps_file)
#         latest_key = if latest
#             "-0"
#         else
#             # General changed how they represent these :(
#             sort([String(split(key, "-")[2]) for key in keys(deps)])[end]
#         end
#         for (key, val) in deps
#             # Only add as a dependent if the most-recent version uses it!
#             if !(key == "0" || endswith(key, latest_key))
#                 continue
#             end
#             i = findfirst(u -> u in values(val), recently_added)
#             if i !== nothing
#                 pkg = Pkg.TOML.parsefile(pkg_file)
#                 push!(dependents, String(pkg["uuid"]))
#                 println(uuid_to_name[recently_added[i]], " => ", url_to_name(pkg["repo"]))
#             end
#         end
#     end
#     return dependents
# end

"""
    dependency_stars(
        registry::String,
        repo::String,
        year::Int,
        auth::GitHub.OAuth2,
    )
"""
function dependency_stars(
    registry::String,
    repo::String,
    year::Int,
    auth::GitHub.OAuth2;
    include_dependents::Bool = false,
)
    dependencies = if include_dependents
        checkout_registry(registry, year) do
            list_of_dependencies(registry, repo)
        end
    else
        String[]
    end
    @info "Found $(length(dependencies)) for $(repo) in $(year)"
    push!(dependencies, repo)
    all_stars = if isfile(data_dir("stars.json"))
        JSON.parsefile(data_dir("stars.json"); use_mmap = false)
    else
        Dict{String, Any}()
    end
    stars = Dict(
        key => all_stars[key] for key in dependencies if haskey(all_stars, key)
    )
    for (key, val) in stars
        stars[key] = Dates.Date.(val)
    end
    i = 0
    my_lock = Threads.SpinLock()
    N = length(dependencies)
    Threads.@threads for d in dependencies
        lock(my_lock) do
            i += 1
        end
        @info "$i / $N: $(d)"
        if haskey(stars, d)
            continue
        end
        try
            stars[d] = get_stargazers(d, auth)
            all_stars[d] = stars[d]
        catch ex
            if ex isa InterruptException
                rethrow(ex)
            elseif occursin("API rate limit", "$(ex)")
                rethrow(ex)
            end
            @warn "Skipping $(d): $ex"
            stars[d] = String[]
        end
    end
    open(data_dir("stars.json"), "w") do io
        write(io, JSON.json(all_stars))
    end
    return stars
end

function build_table(repo, years; use_stars::Bool = true)
    my_auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
    build_issue_dataset(repo, my_auth)

    esc_repo = esc_repo_name(repo)
    data = CSV.read(data_dir(esc_repo * ".csv"), DataFrames.DataFrame)

    registry = joinpath(Pkg.devdir(), "..", "registries", "General")

    stars = Dict(
        year => dependency_stars(
            registry, repo, year, my_auth; include_dependents = use_stars
        )
        for year in years
    )
    # Compute metrics.
    metrics = Any[
        "Number of GitHub stars" =>
            y -> sum(stars[y][repo] .<= Dates.Date(y, 12, 31)),
    ]
    if use_stars
        append!(metrics, [
            "Number of registered dependent packages" =>
                (y) -> length(stars[y]) - 1,
            "Cumulative GitHub stars of dependent packages" =>
                (y) -> begin
                    n = 0
                    for (d, s) in stars[y]
                        if d != repo && length(s) > 0
                            n += sum(s .<= Dates.Date(y, 12, 31))
                        end
                    end
                    return n
                end,
        ])
    end
    append!(metrics, [
        "Number of GitHub issues" =>
            y -> number_open(data, false, y),
        "Number of GitHub pull requests" =>
            y -> number_open(data, true, y),
        "Number of users who have opened a GitHub issue" =>
            y -> number_users(data, false, y),
        "Number of users who have opened a GitHub pull requests" =>
            y -> number_users(data, true, y),
    ])
    # Write metrics to CSV.
    open(data_dir(esc_repo * "_report.csv"), "w") do io
        print(io, repo)
        for y in years
            print(io, ", ", y)
        end
        println(io)
        function diff_string(this, last)
            if last == 0
                return ""
            end
            x = round(Int, 100 * (this / last - 1))
            return " ($(x > 0 ? "+" : "")$(x)%)"
        end
        for (metric, f) in metrics
            print(io, metric)
            ff = f.(years)
            print(io, ", ", ff[1])
            for i = 2:length(ff)
                print(io, ", ", ff[i], diff_string(ff[i], ff[i-1]))
            end
            println(io)
        end
    end
    if use_stars
        summarize_repository(repo, stars[years[end]])
    end
    return
end

"""
    plot_number_issues(df::DataFrames.DataFrame)

Given a DataFrame `df` from `build_issue_dataset`, plot the number of opened
issues and pull requests over time.
"""
function plot_number_issues(df::DataFrames.DataFrame)
    Plots.plot(
        title = "Count of opened\nGithub Issues and Pull Requests",
        xlabel = "Date",
        ylabel = "Count",
        legend = :topleft,
        margin = 10Plots.mm,
    )
    issues = filter(r -> !r[:is_pr], df)
    Plots.plot!(
        reverse(issues[!, :created_at]),
        1:size(issues, 1);
        label = "Issues",
        width = 1,
        color = "#ba4840"
    )
    prs = filter(r -> r[:is_pr], df)
    Plots.plot!(
        reverse(prs[!, :created_at]),
        1:size(prs, 1);
        label = "Pull Requests",
        width = 1,
        linestyle = :dash,
        color = "slategray"
    )
end

function plot_open_issues(df::DataFrames.DataFrame)
    function _count_open(df)
        times = sort(union(df[!, :created_at], skipmissing(df[!, :closed_at])))
        y = map(
            t -> sum(df[!, :created_at] .<= t) -
                 sum(skipmissing(df[!, :closed_at]) .<= t),
            times
        )
        return DataFrames.DataFrame(date = times, open = y)
    end
    issues = _count_open(df[df[!, :is_pr] .== false, :])
    prs = _count_open(df[df[!, :is_pr] .== true, :])
    Plots.plot(
        title = "Count of open\nGithub Issues and Pull Requests",
        xlabel = "Date",
        ylabel = "Count",
        legend = :topleft,
    )
    Plots.plot!(
        issues[!, :date],
        issues[!, :open];
        label = "Issues",
        width = 1,
        color = "#ba4840"
    )
    Plots.plot!(
        prs[!, :date],
        prs[!, :open];
        label = "Pull Requests",
        width = 1,
        linestyle = :dash,
        color = "slategray"
    )
end

"""
    plot_count_users(df::DataFrames.DataFrame)

Given a DataFrame `df` from `build_issue_dataset`, plot the number of unique
users who have opened issues and pull requests over time.
"""
function plot_count_users(df::DataFrames.DataFrame)
    Plots.plot(
        title = "Count of users opening\nGithub Issues and Pull Requests",
        xlabel = "Date",
        ylabel = "Unique User IDs",
        legend = :topleft,
        margin = 10Plots.mm,#5Plots.mm,
    )
    issues = filter(r -> !r[:is_pr], df)
    users_with_issues = DataFrames.combine(
        DataFrames.groupby(issues, :created_at),
    ) do d
        tmp = filter(r -> r[:created_at] <= d[1, :created_at], issues)
        return length(unique(tmp[!, :login]))
    end
    Plots.plot!(
        users_with_issues[!, :created_at],
        users_with_issues[!, :x1];
        label = "Issues",
        width = 1,
        color = "#ba4840"
    )
    prs = filter(r -> r[:is_pr], df)
    users_with_prs = DataFrames.combine(
        DataFrames.groupby(prs, :created_at),
     ) do d
        tmp = filter(r -> r[:created_at] <= d[1, :created_at], prs)
        return length(unique(tmp[!, :login]))
    end
    Plots.plot!(
        users_with_prs[!, :created_at],
        users_with_prs[!, :x1];
        label = "Pull Requests",
        width = 1,
        linestyle = :dash,
        color = "slategray"
    )
end

function summarize_repository(repo, stars)
    esc_repo = esc_repo_name(repo)
    df = CSV.read(data_dir(esc_repo * ".csv"), DataFrames.DataFrame)
    Plots.plot(
        plot_number_issues(df),
        plot_count_users(df),
        plot_open_issues(df),
        size = (1_000, 800)
    )
    Plots.savefig(data_dir(esc_repo * ".pdf"))

    df = DataFrames.DataFrame(
        pkg = collect(keys(stars)),
        stars = length.(values(stars)),
    )
    sort!(df, :stars, rev=true)
    CSV.write(data_dir(esc_repo * "_dependencies.csv"), df)
end

function plot_issue_dashboard(repo)
    esc_repo = esc_repo_name(repo)
    df = CSV.read(data_dir(esc_repo * ".csv"), DataFrames.DataFrame)
    Plots.plot(
        plot_open_issues(df),
        plot_number_issues(df),
        plot_count_users(df),
        layout = (1, 3),
        size = (1_500, 400),
        margin = 10Plots.mm,
    )
    Plots.savefig(data_dir(esc_repo * ".pdf"))
end

# ============================================================================ #
#                                                                              #
#                           Discourse related queries                          #
#                                                                              #
# ============================================================================ #

"""
    build_discourse_dataset(
        url::String = "https://discourse.julialang.org/c/domain/opt/13.json"
    )

Scape every topic given a `url` to a Discourse JSON file as an entry point.

Saves the topics to `discourse_topics.json` and the users to
`discourse_users.json`.
"""
function build_discourse_dataset(
    url::String = "https://discourse.julialang.org/c/domain/opt/13.json",
    topics = Dict{String, Any}[],
    user_ids = Dict{Int, String}()
)
    function next_discourse_url(url)
        if endswith(url, ".json")
            return url * "?page=2"
        end
        page = parse(Int, split(url, "=")[end])
        return replace(url, "?page=$(page)" => "?page=$(page + 1)")
    end
    @info "Scraping $(url)"
    r = HTTP.get(url)
    d = JSON.parse(String(r.body))
    if haskey(d, "users")
        for u in d["users"]
            user_ids[u["id"]] = u["username"]
        end
    end
    if haskey(d, "topic_list")
        for topic in d["topic_list"]["topics"]
            push!(
                topics,
                Dict(
                    "title" => topic["title"],
                    "views" => topic["views"],
                    "created_at" => topic["created_at"],
                    "reply_count" => topic["reply_count"],
                    "users" => String[
                        user_ids[poster["user_id"]]
                        for poster in topic["posters"]
                    ]
                )
            )
        end
    end
    open(data_dir("discourse_topics.json"), "w") do io
        write(io, JSON.json(topics))
    end
    open(data_dir("discourse_users.json"), "w") do io
        write(io, JSON.json(user_ids))
    end
    if haskey(d, "topic_list") && get(d["topic_list"], "more_topics_url", "") != ""
        build_discourse_dataset(next_discourse_url(url), topics, user_ids)
    end
    return
end

"""
    summarize_top_topics(n::Int = 10)

Save a CSV of the top `n` topics to `top_discourse_topics.csv`.

This must be called after `build_discourse_dataset()`.
"""
function summarize_top_topics(n::Int = 10)
    data = JSON.parsefile(data_dir("discourse_topics.json"); use_mmap = false)
    sort!(data, by = d -> d["views"], rev = true)
    open(data_dir("top_discourse_topics.csv"), "w") do io
        println(io, "Title, # Views")
        for i = 1:n
            println(io, data[i]["title"], ", ", data[i]["views"])
        end
    end
end

"""
    plot_discourse_plots()

Plot relevant Discourse-related plots and save to "discourse_analysis.pdf".

This must be called after `build_discourse_dataset()`.
"""
function plot_discourse_plots()
    topics = JSON.parsefile(data_dir("discourse_topics.json"); use_mmap = false)
    reply_count = Dict{String, Int}()
    for t in topics
        for u in t["users"]
            reply_count[u] = get(reply_count, u, 0) + 1
        end
    end
    reply_count_df = DataFrames.DataFrame(
        reply_count = collect(values(reply_count))
    )
    reply_count_df = DataFrames.combine(
        DataFrames.groupby(reply_count_df, :reply_count),
    ) do d
        return size(d, 1)
    end
    reply_count_df = sort(reply_count_df, :reply_count)
    df = DataFrames.DataFrame(
        date = [Dates.Date(t["created_at"], "YYYY-mm-ddTHH:MM:SS.sssZ") for t in topics],
        views = [t["views"] for t in topics],
        replies = [t["reply_count"] for t in topics],
        users = [t["users"] for t in topics],
        title = [t["title"] for t in topics],
    )
    df = DataFrames.sort(df, :date)

    df[!, :orig_user] = [d[1] for d in df[!, :users]]
    df[!, :unique_posters] = [length(unique(df[1:n, :orig_user])) for n = 1:size(df, 1)]

    post_count = DataFrames.sort(
        DataFrames.combine(
            DataFrames.groupby(
                DataFrames.combine(DataFrames.groupby(df, :orig_user)) do d
                    return DataFrames.DataFrame(post = size(d, 1))
                end,
                :post,
            ),
        ) do d
            return size(d, 1)
        end,
        :post
    )

    Plots.plot(
        title = "Number of unique users and posts",
        xlabel = "Date",
        ylabel = "Count",
        legend = :topleft
    )
    Plots.plot!(
        df[!, :date],
        df[!, :unique_posters],
        label = "Unique posters",
        color = "slategray",
        linestyle = :dot,
        w = 3
    )
    p = Plots.plot!(
        df[!, :date],
        1:size(df, 1),
        label = "Unique posts",
        color = "#ba4840",
        w = 3
    )
    Plots.plot(
        p,
        Plots.bar(
            post_count[!, :post],
            post_count[!, :x1],
            color = "#ba4840",
            title = "Count of posts per user",
            xlabel = "# Posts",
            ylabel = "# Users",
            legend = false
        ),
        Plots.plot(
            df[!, :date], df[!, :replies],
            title = "Number of replies per post",
            xlabel = "Date of orignal post",
            ylabel = "# Replies",
            color = "#ba4840",
            legend = false,
            w = 3
        ),
        Plots.plot(
            df[!, :date], df[!, :views],
            title = "Number of views per post",
            xlabel = "Date of original post",
            ylabel = "# Views",
            color = "#ba4840",
            legend = false,
            w = 3
        ),
        size = (1000, 600)
    )
    Plots.savefig(data_dir("discourse_analysis.pdf"))
end

"""
    summarize_discourse()

Main entry point for summarizing the Discourse community forum.
"""
function summarize_discourse()
    build_discourse_dataset()
    summarize_top_topics()
    plot_discourse_plots()
    return
end

# ============================================================================ #
#                                                                              #
#                             Main calls below here                            #
#                                                                              #
# ============================================================================ #

if !haskey(ENV, "GITHUB_AUTH")
    error(
        "You must supply a GitHub authentication token by setting GITHUB_AUTH."
    )
end

# summarize_discourse()

# for (repo, use_stars) in [
#     # ("julialang/Julia", false),
#     ("jump-dev/JuMP.jl", false),
#     ("jump-dev/MathOptInterface.jl", false),
#     # ("jrevels/Cassette.jl", true),
#     # ("JuliaDiff/ChainRules.jl", true),
#     # ("YingboMa/ForwardDiff2.jl", true),
# ]
#     build_table(repo, [2017, 2018, 2019, 2020, 2021]; use_stars = use_stars)
# end

my_auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
build_issue_dataset("jump-dev/JuMP.jl", my_auth)
plot_issue_dashboard("jump-dev/JuMP.jl")
build_issue_dataset("jump-dev/MathOptInterface.jl", my_auth)
plot_issue_dashboard("jump-dev/MathOptInterface.jl")

jump = CSV.read(data_dir("jump-dev_JuMP_jl.csv"), DataFrames.DataFrame)
moi = CSV.read(data_dir("jump-dev_MathOptInterface_jl.csv"), DataFrames.DataFrame)
df = vcat(jump, moi)
sort!(df, :created_at, rev=true)

Plots.plot(
    plot_open_issues(df),
    plot_number_issues(df),
    plot_count_users(df),
    layout = (1, 3),
    size = (1_500, 400),
    margin = 10Plots.mm,
)
Plots.savefig(data_dir("combined.pdf"))
