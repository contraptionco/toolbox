#!/usr/bin/env python3
"""Opt-in Docker integration test; only temporary fixture containers are used.

Run from the development checkout with `python3 deployments/bully-pulpit/test_proxy.py`.
The fixture project has unique names, an ephemeral loopback port, no secrets,
no production mounts, and is removed in finally even when a check fails.
"""

import http.client
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent
HOST = "bully-pulpit.contraption.co"
IMAGE = re.search(
    r"^\s*image:\s*(nginxinc/nginx-unprivileged:[^\s]+)\s*$",
    (HERE / "compose.yml").read_text(),
    re.MULTILINE,
).group(1)
assert "@sha256:" in IMAGE, "Use the pinned deployment image for the fixture"


def run_fixture():
    project = "toolbox-bully-proxy-test-" + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project + "-") as directory:
        fixture = Path(directory)
        upstream = fixture / "upstream.conf"
        stream = fixture / "stream.txt"
        stream.write_bytes(b"s" * 8192)
        upstream.write_text("""
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr crit;
events { worker_connections 64; }
http {
    log_format fixture 'fixture_upstream';
    access_log /dev/stdout fixture;
    client_body_temp_path /tmp/client_body;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 3000;
        location = /stream {
            alias /fixtures/stream.txt;
            limit_rate 1024;
        }
        location / {
            default_type application/json;
            add_header X-Robots-Tag index;
            return 200 '{"host":"$http_host","xff":"$http_x_forwarded_for","real_ip":"$http_x_real_ip","proto":"$http_x_forwarded_proto","forwarded":"$http_forwarded","uri":"$request_uri"}';
        }
    }
}
""")
        compose = {
            "services": {
                "app": {
                    "image": IMAGE,
                    "entrypoint": ["nginx", "-g", "daemon off;"],
                    "volumes": [
                        f"{upstream}:/etc/nginx/nginx.conf:ro",
                        f"{stream}:/fixtures/stream.txt:ro",
                    ],
                    "read_only": True,
                    "tmpfs": ["/tmp:size=32m,mode=1777"],
                    "mem_limit": "64m",
                },
                "proxy": {
                    "image": IMAGE,
                    "entrypoint": ["nginx", "-g", "daemon off;"],
                    "volumes": [f"{HERE / 'nginx.conf'}:/etc/nginx/nginx.conf:ro"],
                    "read_only": True,
                    "tmpfs": ["/tmp:size=32m,mode=1777"],
                    "mem_limit": "64m",
                    "ports": ["127.0.0.1::8080"],
                    "depends_on": ["app"],
                },
                "spare": {
                    "image": IMAGE,
                    "entrypoint": ["sleep", "120"],
                    "profiles": ["dns-test"],
                    "read_only": True,
                    "mem_limit": "16m",
                },
            },
            # Docker Desktop does not publish ports for an internal-only
            # network. This isolated project network joins no existing service.
            "networks": {"default": {}},
        }
        compose_file = fixture / "compose.json"
        compose_file.write_text(json.dumps(compose))
        base = ["docker", "compose", "-p", project, "-f", str(compose_file)]

        def command(*args):
            result = subprocess.run(
                base + list(args), capture_output=True, text=True, timeout=180
            )
            if result.returncode:
                raise RuntimeError(result.stderr[-3000:])
            return result.stdout

        def request(path="/", headers=None, method="GET", body=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                connection.request(
                    method, path, body=body, headers={"Host": HOST, **(headers or {})}
                )
                response = connection.getresponse()
                return response.status, dict(response.getheaders()), response.read()
            except http.client.RemoteDisconnected:
                return 444, {}, b""
            finally:
                connection.close()

        checks = 0
        try:
            command("up", "-d", "--pull", "missing")
            port = int(command("port", "proxy", "8080").strip().rsplit(":", 1)[1])
            for attempt in range(40):
                try:
                    if request()[0] == 200:
                        break
                except (ConnectionError, OSError):
                    pass
                time.sleep(0.1)
            else:
                raise RuntimeError("Fixture proxy did not become ready")

            status, headers, body = request(headers={
                "CF-Connecting-IP": "203.0.113.7",
                "X-Forwarded-For": "198.51.100.99",
                "X-Real-IP": "198.51.100.98",
                "X-Forwarded-Proto": "http",
                "Forwarded": "for=198.51.100.99;proto=http",
            })
            observed = json.loads(body)
            assert status == 200
            assert observed["host"] == HOST
            assert observed["xff"] == observed["real_ip"] == "203.0.113.7"
            assert observed["proto"] == "https" and observed["forwarded"] == ""
            assert headers["X-Robots-Tag"] == "noindex, nofollow, noarchive"
            checks += 6
            _, _, body = request(headers={"X-Forwarded-For": "198.51.100.99"})
            assert json.loads(body)["xff"] == ""
            checks += 1

            for host in ["localhost", "www.philipithomas.com", HOST + ".evil.test", HOST + ":8080"]:
                assert request(headers={"Host": host})[0] == 444, host
                checks += 1
            assert request("http://" + HOST + "/", {"Host": "evil.test"})[0] == 444
            checks += 1

            for path in [
                "/.well-known/workflow",
                "/.well-known/workflow/v1/flow",
                "/.well-known/workflow/v1/step?token=fixture",
                "/.WELL-KNOWN/WORKFLOW/v1/flow",
                "//.well-known///workflow/v1/flow",
                "/safe/../.well-known/workflow/v1/flow",
                "/%2ewell-known/workflow/v1/flow",
                "/.well-known%2fworkflow/v1/flow",
                "/.well-known/%77orkflow/v1/flow",
                "/.well-known/workflow-extra",
            ]:
                for method in ["GET", "POST"]:
                    status, headers, _ = request(path, {"X-Workflow-Internal": "true"}, method)
                    assert status == 403, (method, path, status)
                    assert "noindex" in headers["X-Robots-Tag"]
                    checks += 2

            for path in [
                "/%252ewell-known/workflow/v1/flow",
                "/.well-known%252fworkflow/v1/flow",
                "/.well-known/%2577orkflow/v1/flow",
                "/.well-known%5cworkflow/v1/flow",
                "/.well-known\\workflow/v1/flow",
            ]:
                status, headers, _ = request(path)
                assert status == 400, (path, status)
                assert "noindex" in headers["X-Robots-Tag"]
                checks += 2

            # Encoded query values are ordinary application data, not route paths.
            assert request("/api/search?q=percent%2525%5c")[0] == 200
            assert request("/api/chat", method="POST", body="fixture")[0] == 200
            status, headers, _ = request(
                "/api/printing-press/subscribers/import",
                {"Content-Length": str(10 * 1024 * 1024 + 1), "Content-Type": "text/csv"},
                method="POST",
                body=b"",
            )
            assert status == 413 and "noindex" in headers["X-Robots-Tag"]
            checks += 3

            # The upstream takes several seconds to send its body. The client
            # must receive its first bytes promptly, before the body completes.
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
            try:
                started = time.monotonic()
                connection.request("GET", "/stream", headers={"Host": HOST})
                response = connection.getresponse()
                first = response.read(256)
                first_elapsed = time.monotonic() - started
                remainder = response.read()
                total_elapsed = time.monotonic() - started
                assert response.status == 200 and len(first + remainder) == 8192
                assert first_elapsed < 2, ("buffered response", first_elapsed)
                assert total_elapsed >= 4, ("invalid streaming fixture", total_elapsed)
                checks += 3
            finally:
                connection.close()

            # Occupy the retired fixture app's address, then start its
            # replacement. The unchanged proxy must find the new address.
            proxy_id = command("ps", "-q", "proxy").strip()

            def app_ip():
                container = command("ps", "-q", "app").strip()
                assert re.fullmatch(r"[a-f0-9]{64}", container)
                return subprocess.run(
                    ["docker", "inspect", "--format",
                     "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", container],
                    text=True, capture_output=True, check=True, timeout=10,
                ).stdout.strip()

            old_ip = app_ip()
            command("stop", "--timeout", "2", "app")
            command("rm", "-f", "app")
            command("up", "-d", "--no-deps", "spare")
            command("up", "-d", "--no-deps", "app")
            assert app_ip() != old_ip, "Fixture must move the app to another IP"
            for attempt in range(75):
                try:
                    if request()[0] == 200:
                        break
                except (ConnectionError, OSError):
                    pass
                time.sleep(0.2)
            else:
                raise AssertionError("Proxy did not resolve the replacement app")
            assert command("ps", "-q", "proxy").strip() == proxy_id
            checks += 3
            print(f"Proxy fixture passed {checks} checks; production services untouched.")
        except Exception:
            # These containers contain only synthetic requests and no secrets.
            print(command("ps", "--all"))
            print(command("logs", "--no-log-prefix", "--tail", "20"))
            raise
        finally:
            command("--profile", "dns-test", "down", "--volumes", "--remove-orphans", "--timeout", "5")


if __name__ == "__main__":
    run_fixture()
