"""Loopback Releases API with independent repository failures and page histories."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit
from typing import Any


def release(plugin: str, version: str, repo: str) -> dict[str, Any]:
    return {"tag_name": f"{plugin}-v{version}", "assets": [{
        "name": f"{plugin}-{version}-linux-x86_64.tar.gz",
        "browser_download_url": f"https://example.invalid/{repo}/{plugin}-{version}.tar.gz"}]}


def page_for(scenario: str, repo: str, page: int) -> tuple[int, Any]:
    # Opposite-repository tags must never satisfy the requested repository.
    filler = release("beta" if repo == "owner-a/catalog-a" else "alpha", "99.0.0", repo)
    full = [filler] * 100
    if repo == "owner-a/catalog-a":
        if scenario == "rate":
            return 429, {"message": "rate limit"}
        if scenario == "disconnect":
            return 0, None
        if scenario == "nonlist":
            return 200, {"message": "not releases"}
        if scenario == "partial":
            return (200, [release("alpha", "1.2.0", repo)] + full[:99]) if page == 1 else (503, {})
        if scenario == "caps":
            return 200, full if page <= 10 else [release("late", "1.0.0", repo)]
        if scenario == "short":
            return 200, []
        return 200, [release("alpha", "1.2.0", repo)] + full[:99]
    if repo == "owner-b/catalog-b":
        target_page = 10 if scenario == "caps" else 2 if scenario in ("early", "short") else 1
        return 200, full if page < target_page else [release("beta", "2.3.0", repo)]
    return 404, {}


class Handler(BaseHTTPRequestHandler):
    requests: list[dict[str, Any]] = []

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        if url.path.startswith("/requests/"):
            scenario = url.path.removeprefix("/requests/")
            self.reply(200, [item for item in self.requests if item["scenario"] == scenario])
            return
        scenario, _, repo = url.path.strip("/").partition("/repos/")
        repo = repo.removesuffix("/releases")
        page = int(parse_qs(url.query).get("page", ["1"])[0])
        self.requests.append({"scenario": scenario, "repo": repo, "page": page})
        status, body = page_for(scenario, repo, page)
        if status == 0:
            self.close_connection = True
            return
        self.reply(status, body)

    def reply(self, status: int, value: Any) -> None:
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    with HTTPServer(("127.0.0.1", args.port), Handler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
