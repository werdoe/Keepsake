#!/usr/bin/env python3
"""App Store Connect helper for the TestFlight workflow.

  asc.py setup <out-dir> <env-file>   find the API key in the repo secrets, check the account,
                                      register the bundle IDs, find the team and the app,
                                      make sure an internal TestFlight group gets every build
  asc.py report <out-dir> <env-file>  note the latest builds after an upload

Never writes secret values to <out-dir> (that folder is published to a branch);
only to <env-file>, which stays on the build machine.
"""
import base64
import json
import os
import pathlib
import re
import sys
import time

import jwt
import requests

BUNDLE = "com.rai.igsaver"
TARGETS = {
    "com.rai.igsaver": "Keepsake",
    "com.rai.igsaver.share": "Keepsake Share",
    "com.rai.igsaver.widgets": "Keepsake Widgets",
}
API = "https://api.appstoreconnect.apple.com"

cmd, OUT, ENV_FILE = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
OUT.mkdir(parents=True, exist_ok=True)
notes = []


def note(line):
    print(line)
    notes.append(line)
    (OUT / "summary.txt").write_text("\n".join(notes) + "\n")


def problem(message):
    note("PROBLEM: " + message)
    (OUT / "problem.txt").write_text(message + "\n")
    sys.exit(1)


# ---------------------------------------------------------------- secrets

def find_key(quiet=False):
    raw = json.loads(os.environ.get("ALL_SECRETS") or "{}")
    names = sorted(k for k in raw if k.lower() != "github_token")
    (OUT / "secret-names.txt").write_text("\n".join(names) + "\n")
    key_id = issuer = p8 = team = None
    unknown_ten = []
    for name, value in raw.items():
        if name.lower() == "github_token" or not isinstance(value, str):
            continue
        v = value.strip().replace("\\n", "\n")
        upper = name.upper()
        if "BEGIN PRIVATE KEY" in v:
            p8 = v
            continue
        try:
            decoded = base64.b64decode(v, validate=True).decode()
            if "BEGIN PRIVATE KEY" in decoded:
                p8 = decoded.strip()
                continue
        except Exception:
            pass
        if re.fullmatch(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", v):
            issuer = v
        elif re.fullmatch(r"[A-Z0-9]{10}", v):
            if "TEAM" in upper:
                team = v
            elif "KEY" in upper:
                key_id = v
            else:
                unknown_ten.append(v)
    if key_id is None and len(unknown_ten) == 1:
        key_id = unknown_ten.pop()
    if p8 and "BEGIN PRIVATE KEY" in p8 and "\n" not in p8.strip():
        # Pasted on one line: rebuild the PEM layout.
        body = re.sub(r"-----(BEGIN|END) PRIVATE KEY-----|\s", "", p8)
        p8 = "-----BEGIN PRIVATE KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END PRIVATE KEY-----\n"
    found = [label for label, val in (("key file (.p8)", p8), ("Key ID", key_id), ("Issuer ID", issuer), ("Team ID", team)) if val]
    if not quiet:
        note("Repo secrets: " + (", ".join(names) or "none"))
        note("Recognised: " + (", ".join(found) or "nothing"))
    missing = [label for label, val in (("the .p8 key file contents", p8), ("the Key ID", key_id), ("the Issuer ID", issuer)) if not val]
    if missing:
        problem("Couldn't find " + ", ".join(missing) + " in the repo's Actions secrets.")
    return key_id, issuer, p8, team


# ---------------------------------------------------------------- API

class ASC:
    def __init__(self, key_id, issuer, p8):
        self.key_id, self.issuer, self.p8 = key_id, issuer, p8
        self._token, self._made = None, 0

    def token(self):
        if not self._token or time.time() - self._made > 900:
            now = int(time.time())
            self._token = jwt.encode({"iss": self.issuer, "iat": now, "exp": now + 1150, "aud": "appstoreconnect-v1"},
                                     self.p8, algorithm="ES256", headers={"kid": self.key_id, "typ": "JWT"})
            self._made = now
        return self._token

    def call(self, method, path, **kw):
        r = requests.request(method, API + path, headers={"Authorization": "Bearer " + self.token()}, timeout=60, **kw)
        return r

    def get(self, path, **params):
        r = self.call("GET", path, params=params)
        if r.status_code == 401:
            problem("Apple rejected the API key (401). Check the Key ID, Issuer ID and .p8 secret all belong to the same key, and that the key hasn't been revoked.")
        if r.status_code == 403:
            problem("The API key isn't allowed to do this (403). Create the key with the Admin role.")
        r.raise_for_status()
        return r.json()


def error_text(r):
    try:
        return "; ".join(e.get("detail") or e.get("title", "") for e in r.json().get("errors", []))
    except Exception:
        return r.text[:300]


def setup():
    key_id, issuer, p8, team = find_key()
    keydir = ENV_FILE.parent / "private_keys"
    keydir.mkdir(parents=True, exist_ok=True)
    keyfile = keydir / f"AuthKey_{key_id}.p8"
    keyfile.write_text(p8 if p8.endswith("\n") else p8 + "\n")
    keyfile.chmod(0o600)
    asc = ASC(key_id, issuer, p8)

    apps = asc.get("/v1/apps", limit=200).get("data", [])
    note("API key works.")
    (OUT / "apps.txt").write_text("".join(f"{a['attributes']['name']}  |  {a['attributes']['bundleId']}\n" for a in apps))

    # Register the three bundle IDs (with App Groups) so Xcode and the New App form can use them.
    seed = None
    for identifier, name in TARGETS.items():
        found = [b for b in asc.get("/v1/bundleIds", **{"filter[identifier]": identifier, "limit": 20}).get("data", [])
                 if b["attributes"]["identifier"] == identifier]
        if found:
            bundle = found[0]
            note(f"Bundle ID {identifier}: already registered.")
        else:
            r = asc.call("POST", "/v1/bundleIds", json={"data": {"type": "bundleIds", "attributes": {
                "identifier": identifier, "name": name, "platform": "IOS"}}})
            if r.status_code >= 300:
                problem(f"Couldn't register bundle ID {identifier}: {error_text(r)}")
            bundle = r.json()["data"]
            note(f"Bundle ID {identifier}: registered.")
        seed = seed or bundle["attributes"].get("seedId")
        caps = asc.get(f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities").get("data", [])
        if not any(c["attributes"].get("capabilityType") == "APP_GROUPS" for c in caps):
            r = asc.call("POST", "/v1/bundleIdCapabilities", json={"data": {"type": "bundleIdCapabilities",
                "attributes": {"capabilityType": "APP_GROUPS"},
                "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}}}}})
            note(f"  App Groups capability: {'enabled' if r.status_code < 300 else 'not enabled (' + error_text(r) + ')'}")

    team = team or seed
    if not team:
        problem("Couldn't work out the Team ID. Add it as a secret named APPLE_TEAM_ID.")
    note(f"Team ID: {team}")

    app = next((a for a in apps if a["attributes"]["bundleId"] == BUNDLE), None)
    if not app:
        others = ", ".join(f"{a['attributes']['name']} ({a['attributes']['bundleId']})" for a in apps) or "none"
        problem(f"No app in App Store Connect uses bundle ID {BUNDLE} yet. Apps found: {others}. "
                "Create it in App Store Connect: Apps, +, New App, choose the bundle ID 'Keepsake - com.rai.igsaver'.")
    note(f"App record: {app['attributes']['name']} ({BUNDLE})")

    groups = asc.get(f"/v1/apps/{app['id']}/betaGroups", limit=50).get("data", [])
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    auto = [g for g in internal if g["attributes"].get("hasAccessToAllBuilds")]
    if auto:
        note(f"TestFlight group: '{auto[0]['attributes']['name']}' gets every new build automatically.")
    else:
        r = asc.call("POST", "/v1/betaGroups", json={"data": {"type": "betaGroups",
            "attributes": {"name": "Keepsake Team", "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})
        if r.status_code < 300:
            note("TestFlight group: created internal group 'Keepsake Team' that gets every new build.")
        else:
            note("TestFlight group: couldn't create one automatically (" + error_text(r) + "). Add an internal group by hand.")

    ENV_FILE.write_text(
        f"export KEY_PATH='{keyfile}'\nexport ASC_KEY_ID='{key_id}'\nexport ASC_ISSUER_ID='{issuer}'\n"
        f"export TEAM_ID='{team}'\nexport APP_ID='{app['id']}'\n")


def report():
    key_id, issuer, p8, _ = find_key(quiet=True)
    app_id = os.environ.get("APP_ID")
    asc = ASC(key_id, issuer, p8)
    builds = asc.get("/v1/builds", **{"filter[app]": app_id, "sort": "-uploadedDate", "limit": 3}).get("data", [])
    for b in builds:
        a = b["attributes"]
        note(f"Build {a.get('version')}: {a.get('processingState')} (uploaded {a.get('uploadedDate')})")


if __name__ == "__main__":
    existing = (OUT / "summary.txt")
    if existing.exists():
        notes.extend(existing.read_text().splitlines())
    setup() if cmd == "setup" else report()
