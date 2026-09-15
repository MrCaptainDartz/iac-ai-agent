"""Agent zone egress policy for the L7 proxy: destination allowlist, deny by default.

Loaded by egress-proxy.service (mitmproxy, regular mode); the allowlist path is an option.
"""

from __future__ import annotations

import ipaddress
import posixpath
import re
import socket
from typing import Optional
from urllib.parse import unquote

from mitmproxy import ctx, http

# A rule without an explicit port covers these.
DEFAULT_PORTS = frozenset((80, 443))
# Named explicitly: `is_private` covers CGNAT or not depending on the Python version.
CGNAT = ipaddress.ip_network("100.64.0.0/10")
ALLOW_PREFIX = "egress-allow: "
DENY_PREFIX = "egress-deny: "
BLOCKED_BODY = b"Blocked by the agent zone egress policy.\n"


# A plain class, not @dataclass: mitmproxy's script loader never registers the module in sys.modules.
class Rule:
    """One allowlist entry: [.]host[:port][/path]."""

    def __init__(self, host: str, subdomains: bool, ports: frozenset, path: str) -> None:
        self.host = host
        self.subdomains = subdomains
        self.ports = ports
        self.path = path

    def matches(self, host: str, port: int, path: Optional[str]) -> bool:
        if port not in self.ports:
            return False
        # `*`: any host — the internal check is then the only destination control.
        if self.host != "*":
            if self.subdomains:
                if host != self.host and not host.endswith("." + self.host):
                    return False
            elif host != self.host:
                return False
        if self.path == "" or path is None:
            # No path rule, or no path yet (CONNECT): host and port decide.
            return True
        # On a boundary, so `/v1` does not allow `/v1-secret` and does allow `/v1` itself.
        target = normalize_path(path)
        return target == self.path or target.startswith(self.path + "/")


def normalize_path(path: str) -> str:
    """The path an origin will resolve: query out, encoded bytes decoded, dot segments resolved.
    Without that, `/v1/../admin` passes a `/v1` rule and reaches `/admin` upstream."""
    target = unquote(path.partition("?")[0])
    target = posixpath.normpath(re.sub(r"/{2,}", "/", target))
    return "" if target in (".", "/") else target.rstrip("/")


def parse_rule(line: str) -> Optional[Rule]:
    """Return the rule for one allowlist line, or None if there is nothing usable in it."""
    entry = line.split("#", 1)[0].strip().lower()
    if not entry:
        return None
    subdomains = entry.startswith(".")
    if subdomains:
        entry = entry[1:]
    path = ""
    if "/" in entry:
        entry, path = entry.split("/", 1)
        path = normalize_path("/" + path)
    host, _, port = entry.partition(":")
    if not host:
        ctx.log.warn(f"{DENY_PREFIX}ignoring malformed allowlist entry: {entry}")
        return None
    ports = DEFAULT_PORTS
    if port:
        try:
            ports = frozenset((int(port),))
        except ValueError:
            ctx.log.warn(f"{DENY_PREFIX}ignoring allowlist entry with a bad port: {entry}")
            return None
    return Rule(host=host.rstrip("."), subdomains=subdomains, ports=ports, path=path)


class EgressPolicy:
    def __init__(self) -> None:
        self.rules: tuple[Rule, ...] = ()
        self.resolved: dict[str, Optional[str]] = {}

    def load(self, loader) -> None:
        loader.add_option(
            "allowlist_path",
            str,
            "",
            "Path to the egress allowlist file. An unreadable file denies every request.",
        )

    def configure(self, updated) -> None:
        if "allowlist_path" in updated or not self.rules:
            self._read_rules()

    # Decided before any upstream connection opens, so a refusal is a decision, not a reset.
    def http_connect(self, flow: http.HTTPFlow) -> None:
        self._decide(flow, flow.request.host, flow.request.port, None)

    # Plain HTTP, and every request once TLS is intercepted (level 2).
    def request(self, flow: http.HTTPFlow) -> None:
        self._decide(flow, flow.request.host, flow.request.port, flow.request.path)

    def _read_rules(self) -> None:
        """Reload the allowlist. Never a partial state: an error leaves the policy refusing."""
        self.rules = ()
        self.resolved.clear()
        try:
            with open(ctx.options.allowlist_path) as handle:
                lines = handle.readlines()
        except OSError as err:
            ctx.log.error(f"{DENY_PREFIX}allowlist unreadable ({err}): everything is refused")
            return
        self.rules = tuple(rule for rule in map(parse_rule, lines) if rule)
        ctx.log.info(f"{ALLOW_PREFIX}policy loaded: {len(self.rules)} rule(s)")

    def _decide(self, flow: http.HTTPFlow, host: str, port: int, path: Optional[str]) -> None:
        host = (host or "").lower().rstrip(".")
        reason = self._refuse_reason(host, port, path)
        if reason is None:
            ctx.log.info(f"{ALLOW_PREFIX}{host}:{port}{path or ''}")
            return
        ctx.log.warn(f"{DENY_PREFIX}{reason} {host}:{port}{path or ''}")
        flow.response = http.Response.make(
            403, BLOCKED_BODY, {"Content-Type": "text/plain"}
        )

    def _refuse_reason(self, host: str, port: int, path: Optional[str]) -> Optional[str]:
        if not host:
            return "malformed"
        # The allowlist first, and without touching the network: resolving a host the agent may
        # not reach would hand it a DNS channel out (query names as payload).
        if not any(rule.matches(host, port, path) for rule in self.rules):
            return "not-allowlisted"
        # Then only, for an allowed host: a name resolving into the LAN is refused.
        return self._resolution_refusal(host)

    def _resolution_refusal(self, host: str) -> Optional[str]:
        """Cached: one resolution per allowed host, before the connection is opened."""
        if host not in self.resolved:
            self.resolved[host] = self._refuse_unless_public(host)
        return self.resolved[host]

    def _refuse_unless_public(self, host: str) -> Optional[str]:
        """Without this the proxy is a path to the LAN, undoing the uid egress filter."""
        try:
            ipaddress.ip_address(host)
        except ValueError:
            pass  # not a literal: resolve it below
        else:
            return None if self._is_public(host) else "internal"
        try:
            infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
        except socket.gaierror:
            return "unresolved"  # never passed through
        return None if all(self._is_public(i[4][0]) for i in infos) else "internal"

    @staticmethod
    def _is_public(address: str) -> bool:
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            return False
        if ip.version == 6 and ip.ipv4_mapped is not None:
            ip = ip.ipv4_mapped
        return not (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
            or ip in CGNAT
        )


addons = [EgressPolicy()]
