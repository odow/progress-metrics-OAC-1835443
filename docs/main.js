var d3 = Plotly.d3;

function load_json(filename, callback) {
    var xml_request = new XMLHttpRequest();
    xml_request.overrideMimeType("application/json");
    xml_request.open("GET", filename, true);
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

function to_date(d) {
    function two_digit(x) {
        if (x < 10) {
            return "0" + x
        } else {
            return x
        }
    }
    return d.getFullYear() + "-" + two_digit(d.getMonth() + 1) + "-" + two_digit(d.getDate());
}

function add_new_dates(x, y, new_date, new_value) {
    if (x.length == 0) {
        x.push(new_date);
        y.push(new_value);
    } else if (x[x.length-1] == new_date) {
        y[y.length-1] = new_value;  // update in-place
    } else {
        var date = new Date(x[x.length-1]);
        new_date = new Date(new_date);
        while (date < new_date) {
            date.setDate(date.getDate() + 1);
            x.push(to_date(date));
            y.push(y[y.length-1]);
        }
        x.push(to_date(new_date));
        y.push(new_value);
    }
    return
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
            add_new_dates(x, y, item["date"].slice(0, 10), i);
        } else if (!is_cumulative) {
            i--;
            add_new_dates(x, y, item["date"].slice(0, 10), i);
        }
    });
    add_new_dates(x, y, to_date(new Date()), i);
    object = {name: key, "x": x, "y": y, stackgroup: "one"}
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
        add_new_dates(x, y, item["date"].slice(0, 10), i);
    });
    add_new_dates(x, y, to_date(new Date()), i);
    object = {name: key, "x": x, "y": y}
    if (key != "JuMP.jl" && key != "MathOptInterface.jl") {
        object["visible"] = "legendonly";
    }
    return object
}

(function() {
    var charts = [];
    layout = {
        margin: {b: 30, t: 20},
        hovermode: 'closest',
        "yaxis": {
            "range": ["2013-01-01", to_date(new Date())],
            "title": "Count"
        }
    }
    load_json("data.json", function (data) {
        function plot_chart(key, f) {
            var chart = d3.select(key).node();
            var series = Object.keys(data).sort().map(f);
            console.log(layout);
            Plotly.plot(chart, series, layout);
            charts.push(chart);
            return
        }
        plot_chart(
            "#chart_count_open_issues", 
            key => count_of_opened_issues(data, key, false, false),
        );
        plot_chart(
            "#chart_count_open_pull_requests", 
            key => count_of_opened_issues(data, key, true, false),
        );
        plot_chart(
            "#chart_cumulative_count_open_issues", 
            key => count_of_opened_issues(data, key, false, true),
        );
        plot_chart(
            "#chart_cumulative_count_open_pull_requests", 
            key => count_of_opened_issues(data, key, true, true),
        );
        plot_chart(
            "#chart_count_users_open_issues", 
            key => count_of_users(data, key, false),
        );
        plot_chart(
            "#chart_count_users_open_pull_requests", 
            key => count_of_users(data, key, true),
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
