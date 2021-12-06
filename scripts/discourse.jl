# ============================================================================ #
#                                                                              #
#                           Discourse related queries                          #
#                                                                              #
# ============================================================================ #

import DataFrames
import Dates
import HTTP
import JSON
import Plots

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

# build_discourse_dataset()
# summarize_top_topics()
plot_discourse_plots()
