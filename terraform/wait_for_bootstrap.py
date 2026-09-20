#!/usr/bin/env python3
"""Block until a Windows VM reports that its bootstrap finished.

WHY THIS EXISTS
---------------
Nova reports ACTIVE as soon as the hypervisor has started the guest. It
says nothing about whether Windows got through its specialize pass, whether
cloudbase-init ran, or whether anything inside the VM worked. We have seen a
VM that wedged in sysprep: cloudbase-init spun 833 times waiting for
GeneralizationState to leave 4, gave up silently, and the machine sat there
ACTIVE and permanently unreachable. A hard reboot did not clear it.

Without this check that VM is reported as a SUCCESSFUL deployment. The
student is mailed credentials for a machine that will never accept them,
and nothing anywhere records a problem. At roughly one VM in three that is
several dead desktops per course with no signal at all.

So: the bootstrap script prints ``@@BOOTSTRAP done`` to stdout as its last
act, cloudbase-init copies its output into the Nova console log, and this
waits for that marker. No marker, no successful apply.

WHY THE CONSOLE LOG AND NOT A PORT CHECK
----------------------------------------
Connecting to 3389 would be the obvious test, but the worker container that
runs Terraform has no IPv6 route at all (``Network is unreachable``), and
the VMs are IPv6-only. The console log is reachable over the OpenStack API,
which the worker does have, and it is a stricter test anyway: it proves the
whole bootstrap ran, not just that something bound a port.

IMPLEMENTATION NOTES
--------------------
Standard library only, and deliberately so. This runs from a Terraform
``local-exec`` inside the worker image, and an app repo should not silently
depend on which Python packages the platform happens to install. Keystone
and Nova are plain JSON over HTTPS; ``urllib`` is enough.

Credentials come from the OS_* environment variables the worker already
exports for Terraform, so nothing new has to be plumbed through.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

MARKER_DONE = "@@BOOTSTRAP done"
MARKER_ANY = "@@BOOTSTRAP"

# How long to wait between console-log polls. The log is cheap to fetch but
# there is no reason to hammer the API: a healthy VM takes minutes, not
# seconds, and observed successful boots land around the 2-3 minute mark.
POLL_SECONDS = 15


class BootstrapError(RuntimeError):
    """Raised with a message meant to be read in a deployment log."""


def _post(url: str, payload: dict, token: str | None = None) -> tuple[dict, dict]:
    """POST JSON, return (body, headers). Raises BootstrapError on HTTP error."""
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if token:
        req.add_header("X-Auth-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            body = json.loads(raw) if raw else {}
            return body, dict(resp.headers)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:400]
        raise BootstrapError(f"{exc.code} from {url}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise BootstrapError(f"cannot reach {url}: {exc.reason}") from exc


def authenticate() -> tuple[str, str]:
    """Return (token, nova_base_url) from the OS_* environment."""
    auth_url = os.environ.get("OS_AUTH_URL", "").rstrip("/")
    if not auth_url:
        raise BootstrapError("OS_AUTH_URL is not set - cannot reach OpenStack")
    # OS_AUTH_URL is written both with and without the version suffix
    # depending on who configured the credential; normalise it.
    if not auth_url.endswith("/v3"):
        auth_url += "/v3"

    cred_id = os.environ.get("OS_APPLICATION_CREDENTIAL_ID")
    cred_secret = os.environ.get("OS_APPLICATION_CREDENTIAL_SECRET")
    if cred_id and cred_secret:
        identity = {
            "methods": ["application_credential"],
            "application_credential": {"id": cred_id, "secret": cred_secret},
        }
        scope = None
    else:
        username = os.environ.get("OS_USERNAME")
        password = os.environ.get("OS_PASSWORD")
        if not (username and password):
            raise BootstrapError(
                "no usable OpenStack credentials in the environment "
                "(need OS_APPLICATION_CREDENTIAL_ID/SECRET or OS_USERNAME/OS_PASSWORD)"
            )
        identity = {
            "methods": ["password"],
            "password": {
                "user": {
                    "name": username,
                    "password": password,
                    "domain": {"name": os.environ.get("OS_USER_DOMAIN_NAME", "Default")},
                }
            },
        }
        # An application credential carries its own scope; a password does not.
        project = {"domain": {"name": os.environ.get("OS_PROJECT_DOMAIN_NAME", "Default")}}
        if os.environ.get("OS_PROJECT_ID"):
            project = {"id": os.environ["OS_PROJECT_ID"]}
        elif os.environ.get("OS_PROJECT_NAME"):
            project["name"] = os.environ["OS_PROJECT_NAME"]
        scope = {"project": project}

    payload: dict = {"auth": {"identity": identity}}
    if scope:
        payload["auth"]["scope"] = scope

    body, headers = _post(f"{auth_url}/auth/tokens", payload)
    token = headers.get("X-Subject-Token") or headers.get("x-subject-token")
    if not token:
        raise BootstrapError("Keystone returned no X-Subject-Token")

    region = os.environ.get("OS_REGION_NAME")
    interface = os.environ.get("OS_INTERFACE", "public")
    for service in body.get("token", {}).get("catalog", []):
        if service.get("type") != "compute":
            continue
        endpoints = service.get("endpoints", [])
        # Prefer the configured region, but do not fail if a single-region
        # cloud leaves the field off its endpoints.
        for want_region in (region, None):
            for endpoint in endpoints:
                if endpoint.get("interface") != interface:
                    continue
                if want_region and endpoint.get("region") != want_region:
                    continue
                return token, endpoint["url"].rstrip("/")
    raise BootstrapError(f"no '{interface}' compute endpoint in the service catalog")


def console_log(token: str, nova_url: str, server_id: str, lines: int = 500) -> str:
    """Fetch the tail of a server's console log."""
    body, _ = _post(
        f"{nova_url}/servers/{server_id}/action",
        {"os-getConsoleOutput": {"length": lines}},
        token=token,
    )
    return body.get("output") or ""


def markers(log: str) -> list[str]:
    """Pull the @@BOOTSTRAP lines out of a console log.

    cloudbase-init does not stream the user-data script's output line by
    line - it captures the whole thing and logs it as one Python bytes
    repr, so the line breaks arrive as literal backslash-r-backslash-n
    inside a single log line. Split on that escape, not on real newlines,
    or everything collapses into one unreadable blob.
    """
    crlf = chr(92) + "r" + chr(92) + "n"
    found = []
    for chunk in log.replace(crlf, "\n").splitlines():
        at = chunk.find(MARKER_ANY)
        if at < 0:
            continue
        marker = chunk[at:].strip()
        # A log fetched mid-write can end on a bare "@@BOOTSTRAP" with no
        # text yet; reporting that as the last thing the VM said is noise.
        if marker != MARKER_ANY:
            found.append(marker)
    return found


def main() -> int:
    server_id = os.environ["SERVER_ID"]
    label = os.environ.get("SERVER_LABEL", server_id)
    timeout = float(os.environ.get("READY_TIMEOUT_SECONDS", "1200"))

    token, nova_url = authenticate()
    deadline = time.time() + timeout
    seen: list[str] = []

    while True:
        try:
            log = console_log(token, nova_url, server_id)
        except BootstrapError as exc:
            # A transient API hiccup should not fail a 20-minute wait; only
            # the deadline decides that.
            print(f"[{label}] console log unavailable ({exc}), retrying", flush=True)
            log = ""

        seen = markers(log) or seen
        if any(m.startswith(MARKER_DONE) for m in seen):
            print(f"[{label}] bootstrap completed ({len(seen)} markers)", flush=True)
            return 0

        if time.time() >= deadline:
            break

        last = seen[-1] if seen else "no @@BOOTSTRAP output yet"
        remaining = int(deadline - time.time())
        print(f"[{label}] waiting ({remaining}s left), last: {last}", flush=True)
        time.sleep(min(POLL_SECONDS, max(1, deadline - time.time())))

    # Timed out. Everything useful we know goes into the failure, because
    # the VM is about to be someone else's problem to debug.
    sys.stderr.write(
        f"\nVM {label} ({server_id}) never reported a completed bootstrap "
        f"within {int(timeout)}s.\n\n"
    )
    if seen:
        sys.stderr.write("Last console markers:\n")
        for marker in seen[-15:]:
            sys.stderr.write(f"  {marker}\n")
        sys.stderr.write(
            "\nThe bootstrap started but did not finish - check the markers above "
            "for the step it stopped at.\n"
        )
    else:
        sys.stderr.write(
            "The console log contains no @@BOOTSTRAP output at all, which means "
            "the bootstrap script never ran. The usual cause is Windows wedging "
            "in its first-boot specialize pass: cloudbase-init waits for sysprep "
            "to finish, never sees it, and exits without running user data. Such "
            "a VM stays ACTIVE forever and cannot be recovered by rebooting - it "
            "has to be destroyed and redeployed.\n"
        )
    sys.stderr.write(
        f"\nInspect it with:\n  openstack console log show {server_id}\n"
    )
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BootstrapError as exc:
        sys.stderr.write(f"readiness check failed: {exc}\n")
        sys.exit(1)
