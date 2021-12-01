var d3 = Plotly.d3;

function load_json(filename, callback) {
    var xml_request = new XMLHttpRequest();
    xml_request.overrideMimeType("application/json");
    xml_request.open('GET', filename, true);
    // xml_request.setRequestHeader("Access-Control-Allow-Origin","*")
    xml_request.onreadystatechange = function() {
        if (xml_request.readyState == 4) {
            if (xml_request.status == "200" || xml_request.status == "0") {
                // Required use of an anonymous callback as .open will NOT
                // return a value but simply returns undefined in asynchronous
                // mode.
                callback(JSON.parse(xml_request.responseText));
            } else {
                console.log("error getting " + filename);
                console.log(xml_request);
            }
        }
    };
    xml_request.send(null);
}

function count_of_opened_issues(data, key, is_pr, is_cumulative) {
    i = 0;
    x = [];
    y = [];
    data[key].map(function(item) {
        if (item["is_pr"] != is_pr) {
            return
        } else if (item["type"] == "opened") {
            i++;
            x.push(item["date"]);
            y.push(i);    
        } else if (!is_cumulative) {
            i--;
            x.push(item["date"]);
            y.push(i);
        }
    });
    object = {name: key, "x": x, "y": y, line: {shape: 'hv'}}
    if (key != "JuMP.jl" && key != "MathOptInterface.jl") {
        object["visible"] = "legendonly";
    }
    return object
}

function count_of_users(data, key, is_pr) {
    names = new Set();
    i = 0;
    x = [];
    y = [];
    data[key].map(function(item) {
        if (item["is_pr"] != is_pr || item["type"] == "closed") {
            return
        } else if (names.has(item["user"])) {
            return
        }
        names.add(item["user"]);
        i++;
        x.push(item["date"]);
        y.push(i);
    });
    object = {name: key, "x": x, "y": y, line: {shape: 'hv'}}
    if (key != "JuMP.jl" && key != "MathOptInterface.jl") {
        object["visible"] = "legendonly";
    }
    return object
}

(function() {
    var charts = [];
    load_json("data.json", function (data) {
        function plot_chart(key, f, layout = {}) {
            var chart = d3.select(key).node();
            var series = Object.keys(data).sort().map(f);
            Plotly.plot(chart, series, layout);
            charts.push(chart);
            return
        }
        plot_chart(
            '#chart_count_open_issues', 
            key => count_of_opened_issues(data, key, false, false),
            {"yaxis": {"title": "Count"}}
        );
        plot_chart(
            '#chart_count_open_pull_requests', 
            key => count_of_opened_issues(data, key, true, false),
            {"yaxis": {"title": "Count"}}
        );
        plot_chart(
            '#chart_cumulative_count_open_issues', 
            key => count_of_opened_issues(data, key, false, true),
            {"yaxis": {"title": "Count"}}
        );
        plot_chart(
            '#chart_cumulative_count_open_pull_requests', 
            key => count_of_opened_issues(data, key, true, true),
            {"yaxis": {"title": "Count"}}
        );
        plot_chart(
            '#chart_count_users_open_issues', 
            key => count_of_users(data, key, false),
            {"yaxis": {"title": "Count"}}
        );
        plot_chart(
            '#chart_count_users_open_pull_requests', 
            key => count_of_users(data, key, true),
            {"yaxis": {"title": "Count"}}
        );
    });
    /* =========================================================================
        Resizing stuff.
    ========================================================================= */
    window.onresize = function() {
        charts.map(function(chart){
            if (window.getComputedStyle(chart).display == "block") {
                Plotly.Plots.resize(chart)
            }
        })
    };
})();
