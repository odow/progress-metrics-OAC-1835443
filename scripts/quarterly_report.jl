import Dates
import GitHub

struct Repository
    issues
    commits
end

function Repository(repo; since, until, my_auth)
    println("Getting : ", repo)
    issues, _ = GitHub.issues(
        repo;
        auth = my_auth,
        params = Dict("state" => "all", "since" => since, "until" => until),
    )
    summary_commits, _ = GitHub.commits(
        repo; auth = my_auth,
        params = Dict("since" => since, "until" => until),
    )
    commits = [
        GitHub.commit(repo, c.sha, auth = my_auth) for c in summary_commits
    ]
    return Repository(issues, commits)
end

function add_or_set!(x, key, v)
    if iszero(v)
        return
    elseif haskey(x, key)
        x[key] += v
    else
        x[key] = v
    end
end

function summarize(repos; since, until, exclude = String[])
    additions = Dict{String,Int}()
    deletions = Dict{String,Int}()
    n_commits = 0
    our_commits = 0
    n_repos = 0
    println("Repository            | Commits | Additions | Deletions")
    for r in sort(collect(keys(repos)); by = r -> length(repos[r].commits), rev = true)
        if r in exclude
            continue
        end
        repo = repos[r]
        for commit in repo.commits
            author = commit.author === nothing ? "<unknown>" : commit.author.login
            add_or_set!(additions, author, commit.stats["additions"])
            add_or_set!(deletions, author, commit.stats["deletions"])
            n_commits += 1
            if author in ("odow", "blegat")
                our_commits += 1
            end
        end
        if length(repo.commits) > 0
            n_repos += 1
            println(
                rpad(replace(r, "jump-dev/" => ""), 21),
                " | ",
                rpad(length(repo.commits), 7),
                " | ",
                rpad(sum(c.stats["additions"] for c in repo.commits), 9),
                " | ",
                rpad(sum(c.stats["deletions"] for c in repo.commits), 9),
            )
        end
    end

    N = length(union(keys(additions), keys(deletions)))

    issue_stats = Dict(
        "PR" => Dict("Opened" => 0, "Closed" => 0),
        "Issue" => Dict("Opened" => 0, "Closed" => 0),
    )
    for (r, repo) in repos
        if r in exclude
            continue
        end
        for i in repo.issues
            type = i.pull_request === nothing ? "Issue" : "PR"
            if i.created_at >= Dates.DateTime(since)
                issue_stats[type]["Opened"] += 1
            end
            if i.closed_at !== nothing && i.closed_at < Dates.DateTime(until)
                issue_stats[type]["Closed"] += 1
            end
        end
    end

    return """
    In this quarter, $(N) users made $(n_commits) commits to $(n_repos) repositories
    in the JuMP-dev organization, representing $(sum(values(additions))) lines added
    and $(sum(values(deletions))) lines deleted.

    Of which, Dr Dowson and Dr Legat made $(our_commits) commits representing
    $(additions["odow"] + additions["blegat"]) lines added and
    $(deletions["odow"] + deletions["blegat"]) lines deleted.

    In total, $(issue_stats["PR"]["Opened"]) pull requests were opened and
    $(issue_stats["PR"]["Closed"]) pull requests were closed, and
    $(issue_stats["Issue"]["Opened"]) issues were opened and
    $(issue_stats["Issue"]["Closed"]) issues were closed.
    """
end

function summarize_prs(repos, exclude)
    opened_prs = Any[]
    for (_, repo) in repos
        map(repo.issues) do issue
            if issue.user.login != "odow"
                return
            elseif issue.pull_request ===  nothing
                return
            elseif issue.created_at < Dates.DateTime(since)
                return
            elseif issue.created_at > Dates.DateTime(until)
                return
            end
            push!(
                opened_prs,
                (date=Dates.Date(issue.created_at), url=issue.html_url.uri),
            )
            return
        end
    end
    sort!(opened_prs, by = x -> (x.date, x.url))
    old_date = nothing
    for pr in opened_prs
        if any(s -> occursin(s, pr.url), exclude)
            continue
        end
        if pr.date != old_date
            println("\n", pr.date, "\n")
            old_date  = pr.date
        end
        println("  * ", pr.url)
    end
    return
end

function get_repos(since, until)
    my_auth = GitHub.authenticate(ENV["GITHUB_AUTH"])
    all_repos, _ = GitHub.repos("jump-dev", auth=my_auth);
    repos = Dict(
        repo => Repository(repo; since = since, until = until, my_auth = my_auth)
        for repo in map(r -> "jump-dev/$(r.name)", all_repos)
    )
    repos["JuliaDocs/Documenter.jl"] = Repository(
        "JuliaDocs/Documenter.jl";
        since = since,
        until = until,
        my_auth = my_auth,
    )
    return repos
end

since = "2021-08-01T00:00:00"
until = "2021-11-01T00:00:00"

repos = get_repos(since, until)
summarize(
    repos;
    since = since,
    until = until,
)

summarize_prs(repos, ["CPLEX", "Gurobi"])
