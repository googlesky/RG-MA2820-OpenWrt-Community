#!/usr/bin/env python3
"""Small client for the RG-MA2820(T) EWEB maintenance API.

The password is prompted with terminal echo disabled and is never stored.  The
``upload-check`` uploads the file, calls RGOS ``upgradeOk`` for the real
model/header check, and immediately calls ``upgradeCancel`` to delete the
temporary upload.  ``upload-flash`` repeats the same validation and calls
``upgradeStart`` only when the caller also supplies ``--yes-really-flash``.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import http.client
import json
import mimetypes
import re
import secrets
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


DEFAULT_HOST = "192.0.2.3"


class EwebClient:
    def __init__(self, host: str, password: str, timeout: float = 30.0) -> None:
        self.origin = f"http://{host}"
        self.timeout = timeout
        self.token = self._login(password)

    @staticmethod
    def _decode_json(body: bytes, url: str) -> dict:
        try:
            value = json.loads(body.decode("utf-8", errors="replace"))
        except json.JSONDecodeError as error:
            preview = body[:300].decode("utf-8", errors="replace")
            raise RuntimeError(f"non-JSON response from {url}: {preview}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"unexpected JSON response from {url}: {value!r}")
        return value

    def _open(self, request: urllib.request.Request, timeout: float | None = None) -> bytes:
        try:
            with urllib.request.urlopen(request, timeout=timeout or self.timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {error.code} from {request.full_url}: {body[:500]}") from error

    def _login(self, password: str) -> str:
        stamp = str(int(time.time()))
        digest = hashlib.md5((password + "admin" + stamp).encode()).hexdigest()
        payload = {
            "method": "login",
            "params": {"pw": digest, "un": "admin", "time": stamp},
        }
        url = self.origin + "/login"
        request = urllib.request.Request(
            url,
            data=json.dumps(payload, separators=(",", ":")).encode(),
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        response = self._decode_json(self._open(request), url)
        data = response.get("data")
        token = data.get("token") if isinstance(data, dict) else None
        if response.get("code") != 0 or not token:
            raise RuntimeError(f"EWEB login failed: code={response.get('code')} msg={response.get('msg')!r}")
        return str(token)

    def request_json(self, method: str, path: str, data: dict | None = None) -> dict:
        if not path.startswith("/"):
            path = "/" + path
        url = self.origin + path
        body = None
        headers = {
            "Accept": "application/json",
            "Cookie": f"SessionID={self.token}; SessionTimeout=1000",
        }
        if data is not None:
            body = json.dumps(data, separators=(",", ":")).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=body, headers=headers, method=method.upper())
        return self._decode_json(self._open(request), url)

    def upload_check(self, image: Path, forced: bool) -> dict:
        boundary = "----rgma2820-" + secrets.token_hex(16)
        fields = {"isPersist": "true", "forcedUpgrade": "1" if forced else "0"}
        chunks: list[bytes] = []
        for name, value in fields.items():
            chunks.extend(
                [
                    f"--{boundary}\r\n".encode(),
                    f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                    value.encode(),
                    b"\r\n",
                ]
            )
        content_type = mimetypes.guess_type(image.name)[0] or "application/octet-stream"
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="file"; filename="{image.name}"\r\n'.encode(),
                f"Content-Type: {content_type}\r\n\r\n".encode(),
                image.read_bytes(),
                b"\r\n",
                f"--{boundary}--\r\n".encode(),
            ]
        )
        body = b"".join(chunks)
        url = self.origin + "/view/upload"
        request = urllib.request.Request(
            url,
            data=body,
            headers={
                "Accept": "application/json",
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Content-Length": str(len(body)),
                "Cookie": f"SessionID={self.token}; SessionTimeout=1000",
            },
            method="POST",
        )
        return self._decode_json(self._open(request, timeout=180.0), url)

    def upload_validate_and_cancel(self, image: Path, forced: bool) -> dict:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", image.name):
            raise RuntimeError("image name contains characters unsafe for RGOS")
        upload = self.upload_check(image, forced)
        if upload.get("code") != 0:
            return {"upload": upload, "validation": None, "cancel": None}

        payload = {
            "isPersist": True,
            "forcedUpgrade": "1" if forced else "0",
            "size": image.stat().st_size,
            "fileName": image.name,
        }
        validation: dict | None = None
        cancel: dict | None = None
        try:
            validation = self.request_json(
                "POST", "/api/v1/lua/upgrade/upgradeOk", payload
            )
        finally:
            cancel = self.request_json(
                "POST",
                "/api/v1/lua/upgrade/upgradeCancel",
                {"fileName": image.name},
            )
        return {"upload": upload, "validation": validation, "cancel": cancel}

    def upload_validate_and_flash(self, image: Path, forced: bool) -> dict:
        if not re.fullmatch(r"[A-Za-z0-9._-]+", image.name):
            raise RuntimeError("image name contains characters unsafe for RGOS")
        upload = self.upload_check(image, forced)
        if upload.get("code") != 0:
            return {"upload": upload, "validation": None, "start": None}

        payload = {
            "isPersist": True,
            "forcedUpgrade": "1" if forced else "0",
            "size": image.stat().st_size,
            "fileName": image.name,
        }
        validation = self.request_json(
            "POST", "/api/v1/lua/upgrade/upgradeOk", payload
        )
        if validation.get("code") != 0:
            cancel = self.request_json(
                "POST",
                "/api/v1/lua/upgrade/upgradeCancel",
                {"fileName": image.name},
            )
            return {
                "upload": upload,
                "validation": validation,
                "cancel": cancel,
                "start": None,
            }

        try:
            start = self.request_json(
                "POST", "/api/v1/lua/upgrade/upgradeStart", payload
            )
        except (http.client.RemoteDisconnected, ConnectionResetError) as error:
            # RGOS kills webappz before running bcm_flasher, so a successful
            # dispatch normally closes this HTTP connection without JSON.
            start = {
                "dispatched": True,
                "response": None,
                "connection": type(error).__name__,
            }
        return {"upload": upload, "validation": validation, "start": start}


def port_state(host: str, ports: list[int]) -> dict[str, bool]:
    state: dict[str, bool] = {}
    for port in ports:
        try:
            with socket.create_connection((host, port), timeout=1.0):
                state[str(port)] = True
        except OSError:
            state[str(port)] = False
    return state


def main() -> int:
    parser = argparse.ArgumentParser(description="RG-MA2820 EWEB maintenance client")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--password", help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("dev-status")
    subparsers.add_parser("dev-enable")
    subparsers.add_parser("dev-disable")
    upload = subparsers.add_parser("upload-check")
    upload.add_argument("image", type=Path)
    upload.add_argument("--forced", action="store_true")
    flash = subparsers.add_parser("upload-flash")
    flash.add_argument("image", type=Path)
    flash.add_argument("--forced", action="store_true")
    flash.add_argument("--yes-really-flash", action="store_true")
    args = parser.parse_args()

    password = args.password or getpass.getpass("EWEB management password: ")
    try:
        client = EwebClient(args.host, password)
        if args.command == "dev-status":
            response = client.request_json("GET", "/api/v1/lua/system/develop_mode_get")
            response["tcp"] = port_state(args.host, [22, 23, 54133])
        elif args.command in {"dev-enable", "dev-disable"}:
            enabled = args.command == "dev-enable"
            response = client.request_json(
                "POST",
                "/api/v1/lua/system/develop_mode_set",
                {"developMode": "1" if enabled else "0"},
            )
            time.sleep(1.0)
            status = client.request_json("GET", "/api/v1/lua/system/develop_mode_get")
            response = {"set": response, "status": status, "tcp": port_state(args.host, [22, 23, 54133])}
        elif args.command == "upload-check":
            if not args.image.is_file():
                raise RuntimeError(f"not a regular file: {args.image}")
            response = client.upload_validate_and_cancel(args.image, args.forced)
        else:
            if not args.yes_really_flash:
                raise RuntimeError("upload-flash requires --yes-really-flash")
            if not args.image.is_file():
                raise RuntimeError(f"not a regular file: {args.image}")
            response = client.upload_validate_and_flash(args.image, args.forced)
        print(json.dumps(response, indent=2, sort_keys=True))
        return 0
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
