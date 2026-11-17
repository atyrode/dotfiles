"""The cost guard of myParcelle's CI machines on Clever Cloud, one tick per run.

Independent of the controller (myparcelle-ci-clever.service): it shares no code
and no state with it, reads Clever directly (the API for the applications and
their instances, Clever's telemetry for the minutes they ran) and acts on the
`myparcelle-ci-<n>` applications alone:

  1. an instance running longer than CI_CLEVER_GUARD_MAX_AGE_MIN (70) is
     stopped, and #alertes gets one line; so is any application with
     autoscaling (instances or flavour) or more than one instance;
  2. today's CI spend (Paris day) reaching CI_CLEVER_GUARD_DAY_EUR (15), or
     CI_CLEVER_GUARD_DAY_EUR_OVERRIDE (`<Paris date>:<EUR>`) on that one date
     only, past which it is ignored and #alertes is told once to remove it, or
  3. the month's reaching CI_CLEVER_GUARD_MONTH_EUR (100), pulls the kill
     switch: the latch file is written (systemd then stops the controller and
     refuses to start it; the controller itself refuses too), CI_RUNS_ON goes
     back to dev-01, every CI application is stopped, #alertes gets one line.
     Only a human removes the latch; while it exists every tick stops any CI
     application found running and keeps CI_RUNS_ON on dev-01;
  4. more than CI_CLEVER_MAX_MACHINES applications running at once, two
     readings in a row: the newest extras are stopped, one line an hour;
  5. no complete reading of Clever for CI_CLEVER_GUARD_BLIND_MIN (15): every
     CI application is stopped (fail closed), each tick until Clever answers
     again, and #alertes gets one line.

`--report` reads and prints what it sees, acting on nothing.
CI_CLEVER_QUIET=1 logs the #alertes lines instead of posting them.
Credentials arrive as systemd credentials; no secret is ever logged.
"""

import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from zoneinfo import ZoneInfo

API = "https://api.clever-cloud.com"
WARP10 = "https://c2-warp10-clevercloud-customers.services.clever-cloud.com/api/v0/exec"
POOL_NAME = re.compile(r"^myparcelle-ci-\d+$")
PARIS = ZoneInfo("Europe/Paris")
# Clever's public prices (Paris, EUR per hour, excluding VAT) on 2026-11-16,
# used when the price list does not answer.
FALLBACK_PRICES = {"XS": 0.01111, "S": 0.04444, "M": 0.10556, "L": 0.21111, "XL": 0.42222, "2XL": 0.66667, "3XL": 0.88889}
# Telemetry samples each instance once a minute: it ran until a minute after its last sample.
SAMPLE_MS = 60_000
DEV_01_LABELS = '["self-hosted","linux","x64","dev-01"]'
USER_AGENT = "myparcelle-ci-clever-guard (https://github.com/atyrode/dotfiles)"


def number(name, default):
    value = float(os.environ.get(name, default))
    if not value > 0:
        raise ValueError(f"{name} must be a positive number")
    return value


ORGANISATION = os.environ.get("CI_CLEVER_ORGANISATION", "orga_9bc7fb11-ca4f-4a85-9c2e-855f421760a0")
REPOSITORY = os.environ.get("CI_CLEVER_REPOSITORY", "tyrode-dev/myParcelle")
DAY_CAP = number("CI_CLEVER_GUARD_DAY_EUR", 15)
MONTH_CAP = number("CI_CLEVER_GUARD_MONTH_EUR", 100)
MAX_MACHINES = int(number("CI_CLEVER_MAX_MACHINES", 40))
MAX_AGE_MS = number("CI_CLEVER_GUARD_MAX_AGE_MIN", 70) * 60_000
BLIND_MS = number("CI_CLEVER_GUARD_BLIND_MIN", 15) * 60_000
CONTROLLER = os.environ.get("CI_CLEVER_GUARD_CONTROLLER", "myparcelle-ci-clever.service")
LATCH = os.environ.get("CI_CLEVER_KILL_SWITCH", "/var/lib/myparcelle-ci-clever-guard/kill-switch")
STATE = os.path.join(os.environ.get("STATE_DIRECTORY", "."), "state.json")
QUIET = os.environ.get("CI_CLEVER_QUIET") == "1"
REPORT = sys.argv[1:] == ["--report"]


def log(message):
    print(f"{datetime.now().astimezone().isoformat(timespec='seconds')} {message}", flush=True)


def credential(name):
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise RuntimeError("CREDENTIALS_DIRECTORY is not set: run as the systemd unit")
    with open(os.path.join(directory, name), encoding="utf-8") as source:
        return source.read().strip()


def request(method, url, headers=None, body=None, timeout=30):
    """The answer's body; an error names the method, the path and the status, never a credential.

    Discord's edge refuses urllib's default User-Agent (403, Cloudflare 1010): every call names the guard.
    """
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    call = urllib.request.Request(url, data=data, method=method, headers={"User-Agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(call, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()[:300]


class Clever:
    def __init__(self):
        oauth = json.loads(credential("clever-oauth"))
        quote = lambda value: urllib.parse.quote(value, safe="")  # noqa: E731
        # OAuth 1.0a, PLAINTEXT signature over HTTPS, as clever-tools signs.
        self.authorization = (
            f'OAuth oauth_consumer_key="{oauth["consumerKey"]}", oauth_token="{oauth["token"]}", '
            f'oauth_signature="{quote(oauth["consumerSecret"])}%26{quote(oauth["secret"])}"'
        )

    def call(self, method, path):
        headers = {"Authorization": self.authorization, "Accept": "application/json"}
        status, body = request(method, f"{API}{path}", headers)
        if status >= 300:
            raise RuntimeError(f"Clever {method} {path}: {status} {body[:200].decode(errors='replace')}")
        return body

    def pool(self):
        """The CI applications, each with its instances; everything else in the organisation is left out."""
        listed = json.loads(self.call("GET", f"/v2/organisations/{ORGANISATION}/applications"))
        apps = [app for app in listed if POOL_NAME.match(app["name"])]
        if not apps:
            raise RuntimeError("Clever lists no myparcelle-ci-<n> application")

        def instances(app):
            return json.loads(self.call("GET", f"/v2/organisations/{ORGANISATION}/applications/{app['id']}/instances"))

        with ThreadPoolExecutor(16) as pool:
            for app, listed_instances in zip(apps, pool.map(instances, apps)):
                app["instances"] = [i for i in listed_instances if i.get("state") not in ("DELETED", "STOPPED", "STOPPING")]
        return apps

    def stop(self, app):
        if not POOL_NAME.match(app["name"]):
            raise RuntimeError(f"refusing to stop {app['name']}: not a CI machine")
        self.call("DELETE", f"/v2/organisations/{ORGANISATION}/applications/{app['id']}/instances")

    def uptimes(self, app_ids, start, end):
        """{instance: (app_id, flavour, ms)} each CI instance ran within [start, end), from Clever's telemetry."""
        token = self.call("GET", f"/v2/metrics/read/{ORGANISATION}").decode().strip()
        if not re.fullmatch(r"[\w.-]+", token):
            raise RuntimeError("Clever metrics: unexpected read token")
        selector = "~(?:" + "|".join(re.escape(app_id) for app_id in app_ids) + ")"
        script = "\n".join([
            f"'{token}' 'token' STORE",
            f"[ $token 'mem.total' {{ 'owner_id' '{ORGANISATION}' 'app_id' '{selector}' }} "
            f"'{iso(start)}' '{iso(end)}' ] FETCH",
            "<% DROP DUP LABELS 'labels' STORE DUP FIRSTTICK SWAP LASTTICK 'last' STORE 'first' STORE",
            "[ $labels 'host' GET $labels 'app_id' GET $labels 'flavor_name' GET $first $last ] %> LMAP",
        ])
        status, body = request("POST", WARP10, body=script.encode(), timeout=60)
        # Its error page quotes the script, token included: only the status leaves here.
        if status != 200:
            raise RuntimeError(f"Clever metrics: {status}")
        found = {}
        for host, app_id, flavour, first, last in json.loads(body)[0]:
            if not isinstance(first, (int, float)) or not isinstance(last, (int, float)):
                continue
            first_ms, last_ms = first / 1000, last / 1000
            known = found.get(host)
            if known:
                first_ms, last_ms = min(first_ms, known[2]), max(last_ms, known[3])
            found[host] = (app_id, flavour, first_ms, last_ms)
        return {host: (app_id, flavour, max(0, min(last + SAMPLE_MS, end) - first)) for host, (app_id, flavour, first, last) in found.items()}


def iso(ms):
    return datetime.fromtimestamp(ms / 1000).astimezone().isoformat()


def prices():
    known = dict(FALLBACK_PRICES)
    try:
        status, body = request("GET", f"{API}/v4/billing/price-system?zone_id=par", timeout=20)
        if status == 200:
            for entry in json.loads(body).get("runtime", []):
                slug, price = entry.get("slug_id", ""), entry.get("price")
                if slug.startswith("apps.") and isinstance(price, (int, float)) and entry.get("time_unit") == "PT1H":
                    known[slug[5:]] = float(price)
    except (OSError, ValueError):
        pass
    return known


def spend(clever, apps, start, end, price):
    """EUR the CI instances cost within [start, end): telemetry, raised to what the API shows running now."""
    ran = clever.uptimes([app["id"] for app in apps], start, end)
    flavours = {app["id"]: app["instance"]["minFlavor"]["name"] for app in apps}
    for app in apps:
        for instance in app["instances"]:
            created = instance.get("creationDate")
            if not isinstance(created, (int, float)) or created >= end:
                continue
            ms = end - max(created, start)
            known = ran.get(instance["id"])
            if not known or known[2] < ms:
                ran[instance["id"]] = (app["id"], instance.get("flavor", {}).get("name") or flavours[app["id"]], ms)
    total = 0.0
    for app_id, flavour, ms in ran.values():
        hourly = price.get(flavour) or price.get(flavours.get(app_id, ""))
        if hourly is None:
            # An unknown flavour is priced as the dearest one: the guard errs on the side of stopping.
            hourly = max(price.values())
        total += ms / 3_600_000 * hourly
    return total


def paris_midnight(ms, first_of_month=False):
    moment = datetime.fromtimestamp(ms / 1000, PARIS).replace(hour=0, minute=0, second=0, microsecond=0)
    if first_of_month:
        moment = moment.replace(day=1)
    return int(moment.timestamp() * 1000)


def day_cap(state, day_start):
    """CI_CLEVER_GUARD_DAY_EUR, or CI_CLEVER_GUARD_DAY_EUR_OVERRIDE (`<Paris date>:<EUR>`) on that date alone.

    An override that is malformed or not for today is ignored (the base cap is the stricter default) and
    #alertes is told once, so a one-day exception cannot outlive its day unnoticed.
    """
    override = os.environ.get("CI_CLEVER_GUARD_DAY_EUR_OVERRIDE", "").strip()
    if not override:
        return DAY_CAP
    today = datetime.fromtimestamp(day_start / 1000, PARIS).date().isoformat()
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}):(\d+(?:\.\d+)?)", override)
    if match and match[1] == today:
        return float(match[2])
    why = f"not for today ({today})" if match else "malformed"
    log(f"CI_CLEVER_GUARD_DAY_EUR_OVERRIDE={override} ignored, {why}: day cap {euros(DAY_CAP)}")
    if not REPORT and state.get("overrideIgnored") != override:
        state["overrideIgnored"] = override
        post(
            f"ℹ️ CI sur Clever Cloud : l'exception de plafond journalier CI_CLEVER_GUARD_DAY_EUR_OVERRIDE={override} est ignorée ({why}) ; "
            f"plafond du jour {euros(DAY_CAP)}. La retirer de myparcelle-ci-clever-guard.nix (dotfiles)."
        )
    return DAY_CAP


def wanted_up(app):
    """Started and not yet stopped: what the controller's limit of machines at once counts."""
    return app.get("state") != "SHOULD_BE_DOWN"


def running(app):
    """Wanted up, or with an instance still alive (billed) whatever the application's state."""
    return wanted_up(app) or bool(app["instances"])


def started(app):
    """When its newest instance was created; an application still waiting for one is the newest of all."""
    return max((i.get("creationDate") or 0 for i in app["instances"]), default=float("inf"))


def load_state():
    try:
        with open(STATE, encoding="utf-8") as source:
            return json.load(source)
    except FileNotFoundError:
        return {}


def save_state(state):
    scratch = f"{STATE}.tmp"
    with open(scratch, "w", encoding="utf-8") as target:
        json.dump(state, target)
    os.replace(scratch, STATE)


def post(content):
    """One line in #alertes through the operator's « Statut » webhook; never mentions anyone."""
    if QUIET:
        return log(f"#alertes (quiet, not posted): {content}")
    log(f"#alertes: {content}")
    try:
        line = next((entry for entry in credential("discord").splitlines() if entry.startswith("DISCORD_ALERTS_WEBHOOK_URL=")), "")
        webhook = line.split("=", 1)[1].strip().strip("'\"") if line else ""
        if not webhook.startswith("https://discord.com/api/webhooks/"):
            return log("Discord: no #alertes webhook in the credential")
        status, _ = request("POST", webhook, {"Content-Type": "application/json"}, {"content": content, "allowed_mentions": {"parse": []}})
        if status >= 300:
            log(f"Discord post failed: {status}")
    except OSError as error:
        log(f"Discord post failed: {error.__class__.__name__}")


def github(method, path, body=None):
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {credential('github-token')}",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
    }
    return request(method, f"https://api.github.com/repos/{REPOSITORY}{path}", headers, body)


def route_to_dev_01():
    """CI_RUNS_ON on dev-01's labels; true once GitHub holds them."""
    try:
        status, body = github("GET", "/actions/variables/CI_RUNS_ON")
        if status == 200 and json.dumps(json.loads(json.loads(body)["value"]), separators=(",", ":")) == DEV_01_LABELS:
            return True
        status, _ = github("PATCH", "/actions/variables/CI_RUNS_ON", {"name": "CI_RUNS_ON", "value": DEV_01_LABELS})
        log(f"routing CI to dev-01: GitHub answered {status}")
        return status == 204
    except (OSError, ValueError, KeyError) as error:
        log(f"routing CI to dev-01: {error.__class__.__name__}")
        return False


def controller_active():
    return subprocess.run(["systemctl", "is-active", "--quiet", CONTROLLER], check=False).returncode == 0


def stop_all(clever, apps, why):
    """Stops every CI application found running: (the names stopped, the names it could not stop)."""
    stopped, failed = [], []
    for app in apps:
        if not running(app):
            continue
        try:
            clever.stop(app)
            stopped.append(app["name"])
            log(f"{app['name']}: stopped ({why})")
        except (OSError, RuntimeError) as error:
            failed.append(app["name"])
            log(f"{app['name']}: stop failed ({why}): {error}")
    return stopped, failed


def stop_everything_blind(why):
    """Without a reading of the instances: a stop for every CI application Clever does not list as stopped."""
    clever = Clever()
    listed = json.loads(clever.call("GET", f"/v2/organisations/{ORGANISATION}/applications"))
    apps = [dict(app, instances=[]) for app in listed if POOL_NAME.match(app["name"])]
    return stop_all(clever, apps, why)


def euros(value):
    return f"{value:.2f} €".replace(".", ",")


def pull_kill_switch(clever, apps, reason):
    with open(LATCH, "x", encoding="utf-8") as latch:
        latch.write(json.dumps({"at": datetime.now().astimezone().isoformat(), "reason": reason}) + "\n")
    log(f"kill switch: {reason}")
    routed = route_to_dev_01()
    stopped, failed = stop_all(clever, apps, "kill switch")
    # systemd stops the controller once the latch exists (it stops its own machines, within 90 s).
    deadline = time.monotonic() + 75
    while controller_active() and time.monotonic() < deadline:
        time.sleep(5)
    controller_stopped = not controller_active()
    # Whatever the controller started meanwhile.
    try:
        more, failed = stop_all(clever, clever.pool(), "kill switch")
        stopped += [name for name in more if name not in stopped]
    except (OSError, RuntimeError, ValueError) as error:
        log(f"kill switch: second reading failed ({error}); the next tick stops what is left")
    post(
        f"🛑 CI sur Clever Cloud : coupe-circuit — {reason}. "
        f"Contrôleur {'arrêté' if controller_stopped else 'TOUJOURS ACTIF (arrêter à la main)'}, "
        f"{len(stopped)} machine(s) arrêtée(s){', échec : ' + ', '.join(failed) if failed else ''}, "
        f"CI {'renvoyée sur dev-01' if routed else 'NON renvoyée sur dev-01 (CI_RUNS_ON à poser à la main)'}. "
        f"Seul un humain lève le verrou : `sudo rm {LATCH}` (myParcelle docs/workflows/DELIVERY.md § Clever cost guard)."
    )


def tick(state, now):
    clever = Clever()
    apps = clever.pool()
    price = prices()
    day_start = paris_midnight(now)
    month_start = paris_midnight(now, first_of_month=True)
    day = spend(clever, apps, day_start, now, price)
    # The month's days before today change no more: read once an hour.
    before = state.get("monthBefore", {})
    if before.get("dayStart") != day_start or now - before.get("at", 0) > 3_600_000:
        eur = spend(clever, apps, month_start, day_start, price) if month_start < day_start else 0.0
        before = state["monthBefore"] = {"dayStart": day_start, "at": now, "eur": eur}
    month = before["eur"] + day
    cap = day_cap(state, day_start)
    up = sorted((app for app in apps if running(app)), key=started)
    log(f"{len(up)}/{len(apps)} CI application(s) running; today {euros(day)} (cap {euros(cap)}), month {euros(month)} (cap {euros(MONTH_CAP)})")
    if REPORT:
        for app in up:
            ages = [round((now - i["creationDate"]) / 60_000, 1) for i in app["instances"] if i.get("creationDate")]
            print(f"  {app['name']} {app.get('state')} instance age(s) min: {ages}")
        return

    # 2, 3: the caps; while latched, nothing runs.
    if os.path.exists(LATCH):
        if any(running(app) for app in up):
            stop_all(clever, up, "kill switch latched")
        route_to_dev_01()
        if controller_active() and not state.get("latchedControllerAlerted"):
            state["latchedControllerAlerted"] = True
            post(f"🛑 CI sur Clever Cloud : le verrou {LATCH} est posé mais {CONTROLLER} tourne : l'arrêter à la main.")
        return
    state.pop("latchedControllerAlerted", None)
    if day >= cap:
        return pull_kill_switch(clever, apps, f"dépense CI du jour {euros(day)} ≥ plafond {euros(cap)}")
    if month >= MONTH_CAP:
        return pull_kill_switch(clever, apps, f"dépense CI du mois {euros(month)} ≥ plafond {euros(MONTH_CAP)}")

    # 1: an instance running too long.
    alerted = state.setdefault("longRunning", {})
    for app in up:
        old = [i for i in app["instances"] if i.get("creationDate") and now - i["creationDate"] > MAX_AGE_MS]
        if not old:
            continue
        minutes = round((now - min(i["creationDate"] for i in old)) / 60_000)
        try:
            clever.stop(app)
            outcome = "arrêtée"
            app["instances"] = []
            app["state"] = "SHOULD_BE_DOWN"
        except (OSError, RuntimeError) as error:
            log(f"{app['name']}: stop failed: {error}")
            outcome = "arrêt ÉCHOUÉ, nouvel essai dans 2 min"
        if any(i["id"] not in alerted for i in old):
            for instance in old:
                alerted[instance["id"]] = now
            post(f"⚠️ CI sur Clever Cloud : {app['name']} tournait depuis {minutes} min (> {round(MAX_AGE_MS / 60_000)} min) : {outcome} par le garde-fou de coût.")
    for instance_id, at in list(alerted.items()):
        if now - at > 86_400_000:
            del alerted[instance_id]

    # 1b: one instance of one flavour per machine; autoscaling or a second instance multiplies its cost.
    scaled = state.setdefault("scaled", {})
    for app in apps:
        instance = app["instance"]
        shape = (instance.get("minInstances"), instance.get("maxInstances"), instance["minFlavor"]["name"], instance["maxFlavor"]["name"])
        alive = len(app["instances"])
        if shape[0] == shape[1] == 1 and shape[2] == shape[3] and alive <= 1:
            continue
        if running(app):
            stop_all(clever, [app], "scalability or several instances")
            app["instances"] = []
            app["state"] = "SHOULD_BE_DOWN"
        if now - scaled.get(app["name"], 0) > 86_400_000:
            scaled[app["name"]] = now
            post(
                f"⚠️ CI sur Clever Cloud : {app['name']} n'a plus 1 instance fixe ({shape[0]}–{shape[1]} instance(s), "
                f"{shape[2]}–{shape[3]}, {alive} en marche) : arrêtée par le garde-fou de coût ; remettre 1 instance, auto-scalabilité désactivée."
            )

    # 4: more machines at once than the controller may run, two readings in a row (a controller
    # replacing a machine is never caught between its stop and its start).
    up = [app for app in up if wanted_up(app)]
    over = len(up) > MAX_MACHINES
    if over and state.get("overLimit"):
        extras = up[MAX_MACHINES:]
        _, failed = stop_all(clever, extras, f"more than {MAX_MACHINES} running")
        if now - state.get("tooManyAlertedAt", 0) > 3_600_000:
            state["tooManyAlertedAt"] = now
            post(
                f"⚠️ CI sur Clever Cloud : {len(up)} machines en marche (max {MAX_MACHINES}) : "
                f"les {len(extras)} plus récentes arrêtées par le garde-fou de coût{' (échec : ' + ', '.join(failed) + ')' if failed else ''}."
            )
    state["overLimit"] = over


def main():
    now = int(time.time() * 1000)
    state = load_state()
    try:
        tick(state, now)
    except Exception:  # noqa: BLE001 - any failure to read Clever counts towards blindness
        log(f"tick failed, no complete reading of Clever: {traceback.format_exc(limit=3).strip()}")
        if REPORT:
            return 1
        blind_since = state.setdefault("blindSince", now)
        if now - blind_since >= BLIND_MS:
            minutes = round((now - blind_since) / 60_000)
            try:
                stopped, failed = stop_everything_blind(f"guard blind for {minutes} min")
                outcome = f"{len(stopped)} machine(s) arrêtée(s)" + (f", échec : {', '.join(failed)}" if failed else "")
            except Exception as error:  # noqa: BLE001
                outcome = f"arrêt impossible ({error.__class__.__name__}) : les arrêter dans la console Clever"
                log(f"blind stop failed: {traceback.format_exc(limit=3).strip()}")
            if not state.get("blindAlerted"):
                state["blindAlerted"] = True
                post(f"🔴 CI sur Clever Cloud : le garde-fou de coût ne lit plus Clever depuis {minutes} min ; machines CI arrêtées par sécurité : {outcome}.")
        save_state(state)
        return 1
    if REPORT:
        return 0
    if state.pop("blindAlerted", None):
        post(f"✅ CI sur Clever Cloud : le garde-fou de coût lit de nouveau Clever (aveugle depuis {round((now - state['blindSince']) / 60_000)} min).")
    state.pop("blindSince", None)
    save_state(state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
