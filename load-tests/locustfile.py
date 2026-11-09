"""Locust scenario for the Multidimensional Portal Generator API (FastAPI).

Real routes (verified against src/main.py and /openapi.json):
    POST /auth/register      {email, password>=8}           -> 201 UserResponse
    POST /auth/login         {email, password}              -> 200 {access_token, token_type}
    GET  /users/me           Bearer JWT                     -> 200 UserResponse
    PUT  /users/{user_id}    Bearer JWT, {email?, password?, is_active?} -> 200
    GET  /admin/dashboard    Bearer JWT, ADMIN only         -> 403 for USER
    POST /simulations/run    Bearer JWT, SimulationRequest  -> 201 {id, user_id, coordinates, created_at}

Every virtual user registers its own account in on_start, so the test can be
run against an empty database and users never fight over the same row.
"""

import random
import uuid

from locust import HttpUser, between, events, task

PASSWORD = "LoadTest#2026"
REQUEST_TIMEOUT = (
    60  # s; a real client gives up eventually, Locust reports it as a failure
)


def _short(resp) -> str:
    """Status-0 responses carry the client error (timeout / connection reset) instead of a body."""
    if resp.status_code == 0 and resp.error is not None:
        return type(resp.error).__name__
    return (resp.text or "")[:120]


def _unique_email(prefix: str = "lt") -> str:
    return f"{prefix}-{uuid.uuid4().hex[:12]}@loadtest.example.com"


def _random_simulation_payload() -> dict:
    """Parameters for the geodesic trajectory computation.

    complexity drives the work: the server computes max(8, complexity*8)+1
    points. Most real requests are light, a few are heavy (up to 100 -> 801 points).
    """
    complexity = random.choices(
        population=[
            random.randint(1, 10),
            random.randint(11, 50),
            random.randint(51, 100),
        ],
        weights=[70, 25, 5],
    )[0]
    return {
        "dimension_id": random.randint(1, 1000),
        "complexity": complexity,
        "initial_speed": round(random.uniform(0.0, 5000.0), 3),
        "object_mass": round(random.uniform(0.1, 10_000.0), 3),
    }


def _random_coordinates_payload() -> dict:
    """Alternative branch of /simulations/run: transform user-supplied coordinates."""
    n = random.randint(3, 60)
    return {"coordinates": [round(random.uniform(-1e4, 1e4), 4) for _ in range(n)]}


class PortalUser(HttpUser):
    wait_time = between(1, 3)

    def on_start(self) -> None:
        self.email = _unique_email()
        self.token = None
        self.user_id = None
        self.simulations_created = 0
        if self._register():
            self._login()

    # ---------------------------------------------------------------- helpers
    @property
    def auth(self) -> dict:
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    def _register(self) -> bool:
        with self.client.post(
            "/auth/register",
            json={"email": self.email, "password": PASSWORD},
            name="/auth/register",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code == 201:
                self.user_id = resp.json().get("id")
                resp.success()
                return True
            if (
                resp.status_code == 409
            ):  # an earlier attempt did commit; start over with a new e-mail
                self.email = _unique_email()
            resp.failure(f"register: HTTP {resp.status_code} {_short(resp)}")
            return False

    def _login(self) -> None:
        with self.client.post(
            "/auth/login",
            json={"email": self.email, "password": PASSWORD},
            name="/auth/login",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"login: HTTP {resp.status_code} {_short(resp)}")
                return
            token = resp.json().get("access_token")
            if not token:
                resp.failure("login: no access_token in response")
                return
            self.token = token
            resp.success()

    def _ensure_auth(self) -> bool:
        """A user whose sign-up failed retries sign-up (not login for a missing account)."""
        if self.user_id is None and not self._register():
            return False
        if self.token is None:
            self._login()
        return self.token is not None

    # ------------------------------------------------------------------ tasks
    @task(6)
    def view_profile(self) -> None:
        """Most frequent action: the dashboard loads the current user's profile."""
        if not self._ensure_auth():
            return
        with self.client.get(
            "/users/me",
            headers=self.auth,
            name="/users/me",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code == 401:
                self.token = None
                resp.failure("users/me: token rejected (401)")
            elif resp.status_code != 200:
                resp.failure(f"users/me: HTTP {resp.status_code} {_short(resp)}")
            elif resp.json().get("id") != self.user_id:
                resp.failure("users/me: returned a different user")
            else:
                resp.success()

    @task(4)
    def run_simulation(self) -> None:
        """Main business write: compute a portal trajectory and store it."""
        if not self._ensure_auth():
            return
        payload = _random_simulation_payload()
        expected_points = max(8, payload["complexity"] * 8) + 1
        with self.client.post(
            "/simulations/run",
            json=payload,
            headers=self.auth,
            name="/simulations/run [geodesic]",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code != 201:
                resp.failure(f"simulation: HTTP {resp.status_code} {_short(resp)}")
                return
            body = resp.json()
            coords = body.get("coordinates") or []
            if len(coords) != expected_points:
                resp.failure(
                    f"simulation: expected {expected_points} points, got {len(coords)}"
                )
            elif body.get("user_id") != self.user_id:
                resp.failure("simulation: stored for a different user")
            else:
                self.simulations_created += 1
                resp.success()

    @task(1)
    def run_coordinates_transform(self) -> None:
        """Rarer branch of the same endpoint: user-supplied coordinates."""
        if not self._ensure_auth():
            return
        payload = _random_coordinates_payload()
        with self.client.post(
            "/simulations/run",
            json=payload,
            headers=self.auth,
            name="/simulations/run [coordinates]",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code != 201:
                resp.failure(f"coordinates: HTTP {resp.status_code} {_short(resp)}")
            elif len(resp.json().get("coordinates") or []) != len(
                payload["coordinates"]
            ):
                resp.failure("coordinates: length mismatch")
            else:
                resp.success()

    @task(1)
    def update_profile(self) -> None:
        """Infrequent write: change own e-mail (no password -> no extra bcrypt)."""
        if not self._ensure_auth() or self.user_id is None:
            return
        new_email = _unique_email("upd")
        with self.client.put(
            f"/users/{self.user_id}",
            json={"email": new_email},
            headers=self.auth,
            name="/users/[id]",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code == 200 and resp.json().get("email") == new_email:
                self.email = new_email
                resp.success()
            else:
                resp.failure(f"update user: HTTP {resp.status_code} {_short(resp)}")

    @task(1)
    def relogin(self) -> None:
        """Session refresh: a token is valid for 30 min, clients log in again."""
        if self.user_id is None:
            self._ensure_auth()
            return
        self._login()

    @task(1)
    def probe_admin_forbidden(self) -> None:
        """A regular user opening the admin page must get 403 (RBAC check)."""
        if not self._ensure_auth():
            return
        with self.client.get(
            "/admin/dashboard",
            headers=self.auth,
            name="/admin/dashboard (expect 403)",
            timeout=REQUEST_TIMEOUT,
            catch_response=True,
        ) as resp:
            if resp.status_code == 403:
                resp.success()
            else:
                resp.failure(
                    f"admin: expected 403, got {resp.status_code} {_short(resp)}"
                )


@events.test_stop.add_listener
def _summary(environment, **_kwargs) -> None:
    total = environment.stats.total
    print(
        f"[summary] requests={total.num_requests} failures={total.num_failures} "
        f"fail_ratio={total.fail_ratio:.2%} avg={total.avg_response_time:.1f}ms "
        f"p95={total.get_response_time_percentile(0.95)}ms rps={total.total_rps:.2f}"
    )
