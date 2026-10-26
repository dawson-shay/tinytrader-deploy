# Jupyter for the console: the token comes from JUPYTER_TOKEN (the site's
# secrets/research.env), and only the console may embed it in a page.
c = get_config()  # noqa: F821
c.ServerApp.tornado_settings = {
    "headers": {
        "Content-Security-Policy": "frame-ancestors 'self' http://localhost:8080 http://127.0.0.1:8080",
    },
}
# No browser on the server, no announcements, no telemetry-like checks.
c.ServerApp.open_browser = False
c.LabApp.news_url = None
c.LabApp.check_for_updates_class = "jupyterlab.NeverCheckForUpdate"
