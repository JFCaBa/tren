"""APNs client: HTTP/2 with token-based (JWT) auth. Never logs device tokens."""
from __future__ import annotations

import base64
import binascii
import json
import sys
import threading
import time
from typing import Mapping, Optional, TextIO

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

HOSTS = {
    "production": "api.push.apple.com",
    "sandbox": "api.sandbox.push.apple.com",
}
FORCED_REFRESH_GAP = 20 * 60  # min gap between JWT drops caused by non-expiry 403s
JWT_TTL = 50 * 60  # Apple requires a refresh between 20 and 60 minutes
EXPIRATION_SECONDS = 600
MAX_PAYLOAD = 4096
GONE_REASONS = {"BadDeviceToken", "DeviceTokenNotForTopic"}


def _payload(title: str, body: str) -> bytes:
    return json.dumps(
        {"aps": {"alert": {"title": title, "body": body}, "sound": "default"}},
        ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8", errors="replace")


def build_payload(title: str, body: str) -> Optional[bytes]:
    """Encode the alert, truncating the body (never the title) to fit 4 KB.

    Returns None if even an empty body does not fit."""
    if len(_payload(title, "")) > MAX_PAYLOAD:
        return None
    data = _payload(title, body)
    if len(data) <= MAX_PAYLOAD:
        return data
    lo, hi = 0, len(body)  # longest body prefix that fits
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(_payload(title, body[:mid])) <= MAX_PAYLOAD:
            lo = mid
        else:
            hi = mid - 1
    return _payload(title, body[:lo])


class Apns:
    def __init__(self, key_pem: bytes, key_id: str, team_id: str,
                 topic: str = "com.jfcaba.proximotren", clock=time.time,
                 transport: Optional[httpx.BaseTransport] = None,
                 log: TextIO = sys.stderr):
        self._key_pem = key_pem
        self._key_id = key_id
        self._team_id = team_id
        self._topic = topic
        self._clock = clock
        self._client = httpx.Client(http2=True, timeout=10, transport=transport)
        self._jwt: Optional[str] = None
        self._jwt_at = 0.0
        self._forced_at: Optional[float] = None
        self._lock = threading.Lock()
        self._log = log

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Optional["Apns"]:
        key_b64 = (env.get("APNS_KEY") or "").strip()
        key_id = (env.get("APNS_KEY_ID") or "").strip()
        team_id = (env.get("APNS_TEAM_ID") or "").strip()
        if not (key_b64 and key_id and team_id):
            return None
        try:
            key_pem = base64.b64decode(key_b64, validate=True)
            key = serialization.load_pem_private_key(key_pem, password=None)
        except (binascii.Error, ValueError, TypeError):
            return None
        if not (isinstance(key, ec.EllipticCurvePrivateKey)
                and isinstance(key.curve, ec.SECP256R1)):
            return None
        return cls(key_pem, key_id, team_id)

    def _token(self) -> str:
        with self._lock:
            now = self._clock()
            age = now - self._jwt_at
            if self._jwt is None or age < 0 or age >= JWT_TTL:
                self._jwt = jwt.encode(
                    {"iss": self._team_id, "iat": int(now)},
                    self._key_pem, algorithm="ES256", headers={"kid": self._key_id},
                )
                self._jwt_at = now
            return self._jwt

    def _drop_token(self, expired: bool) -> None:
        """Expired token: always renew. Any other 403 (e.g. clock skew): renew at most once per
        FORCED_REFRESH_GAP, so a bad key cannot cause TooManyProviderTokenUpdates."""
        with self._lock:
            now = self._clock()
            if expired:
                self._jwt = None
            elif (self._forced_at is None or now < self._forced_at
                  or now - self._forced_at >= FORCED_REFRESH_GAP):
                self._jwt = None
                self._forced_at = now

    def _note(self, line: str) -> None:
        try:
            self._log.write(line + "\n")
        except Exception:
            pass

    def send(self, token: str, env: str, title: str, body: str) -> str:
        """Returns "ok", "gone" (token no longer valid) or "error". Never raises.
        No apns-collapse-id: every alert stays on the lock screen."""
        try:
            payload = build_payload(title, body)
        except Exception as e:
            self._note(f"apns payload {type(e).__name__}")
            return "error"
        if payload is None:
            self._note("apns payload too large")
            return "error"
        return self._post(token, env, payload, {
            "apns-topic": self._topic,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": str(int(self._clock()) + EXPIRATION_SECONDS),
        })

    def send_activity(self, token: str, env: str, state: dict, *, event: str = "update",
                      priority: int = 5, stale: int, dismissal: int | None = None) -> str:
        """A Live Activity update or end ("ok" | "gone" | "error"; never raises)."""
        try:
            aps = {"timestamp": int(self._clock()), "event": event, "content-state": state,
                   "stale-date": int(stale)}
            if dismissal is not None:
                aps["dismissal-date"] = int(dismissal)
            payload = json.dumps({"aps": aps}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        except Exception as e:
            self._note(f"apns payload {type(e).__name__}")
            return "error"
        if len(payload) > MAX_PAYLOAD:
            self._note("apns payload too large")
            return "error"
        return self._post(token, env, payload, {
            "apns-topic": f"{self._topic}.push-type.liveactivity",
            "apns-push-type": "liveactivity",
            "apns-priority": str(priority),
        })

    def _post(self, token: str, env: str, payload: bytes, extra: dict) -> str:
        """One immediate retry only when the request certainly wasn't sent (connect error/timeout,
        pool timeout), never on an HTTP status."""
        try:
            host = HOSTS.get(env, HOSTS["production"])
            headers = {"authorization": "bearer " + self._token(), **extra,
                       "content-type": "application/json"}
            url = f"https://{host}/3/device/{token}"
            try:
                r = self._client.post(url, content=payload, headers=headers)
            except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout):  # certainly not sent
                r = self._client.post(url, content=payload, headers=headers)
        except Exception as e:
            self._note(f"apns network {type(e).__name__}")
            return "error"
        if r.status_code == 200:
            return "ok"
        reason = None
        try:
            reason = r.json().get("reason")
        except Exception:
            pass
        self._note(f"apns {r.status_code} {reason}")
        if r.status_code == 403:
            self._drop_token(reason == "ExpiredProviderToken")
        if r.status_code == 410:
            return "gone"
        if r.status_code == 400 and reason in GONE_REASONS:
            return "gone"
        return "error"
