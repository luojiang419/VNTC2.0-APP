pub fn get(path: &str) -> Option<(&'static str, &'static str)> {
    Some(match path {
        "styles/tokens.css" => (
            "text/css; charset=utf-8",
            include_str!("../web/styles/tokens.css"),
        ),
        "styles/shell.css" => (
            "text/css; charset=utf-8",
            include_str!("../web/styles/shell.css"),
        ),
        "styles/components.css" => (
            "text/css; charset=utf-8",
            include_str!("../web/styles/components.css"),
        ),
        "styles/pages.css" => (
            "text/css; charset=utf-8",
            include_str!("../web/styles/pages.css"),
        ),
        "styles/responsive.css" => (
            "text/css; charset=utf-8",
            include_str!("../web/styles/responsive.css"),
        ),
        "js/api.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/api.js"),
        ),
        "js/state.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/state.js"),
        ),
        "js/router.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/router.js"),
        ),
        "js/ui.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/ui.js"),
        ),
        "js/app.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/app.js"),
        ),
        "js/pages/dashboard.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/pages/dashboard.js"),
        ),
        "js/pages/link-status.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/pages/link-status.js"),
        ),
        "js/pages/configs.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/pages/configs.js"),
        ),
        "js/pages/settings.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/pages/settings.js"),
        ),
        "js/pages/about.js" => (
            "text/javascript; charset=utf-8",
            include_str!("../web/js/pages/about.js"),
        ),
        _ => return None,
    })
}
