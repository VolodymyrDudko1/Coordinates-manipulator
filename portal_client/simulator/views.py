import logging
from typing import Any

import httpx
from django.conf import settings
from django.http import HttpRequest, JsonResponse
from django.shortcuts import redirect, render

logger = logging.getLogger(__name__)


def _backend_error(response: httpx.Response) -> str:
    try:
        detail = response.json().get("detail")
    except ValueError:
        detail = None
    return str(detail or "Backend request failed")


async def _post_backend(path: str, **kwargs: Any) -> httpx.Response:
    async with httpx.AsyncClient(base_url=settings.FASTAPI_BACKEND_URL) as client:
        return await client.post(path, timeout=10.0, **kwargs)


async def login_view(request: HttpRequest):
    error = None
    if request.method == "POST":
        try:
            response = await _post_backend(
                "/auth/login",
                json={
                    "email": request.POST.get("email", ""),
                    "password": request.POST.get("password", ""),
                },
            )
            logger.info(
                "FastAPI POST /auth/login status=%s body=%s",
                response.status_code,
                response.text,
            )
            if response.is_success:
                request.session["access_token"] = response.json()["access_token"]
                return redirect("dashboard")
            error = _backend_error(response)
        except httpx.RequestError:
            error = "Authentication service is unavailable."
    return render(request, "simulator/login.html", {"error": error})


async def register_view(request: HttpRequest):
    error = None
    if request.method == "POST":
        try:
            response = await _post_backend(
                "/auth/register",
                json={
                    "email": request.POST.get("email", ""),
                    "password": request.POST.get("password", ""),
                },
            )
            logger.info(
                "FastAPI POST /auth/register status=%s body=%s",
                response.status_code,
                response.text,
            )
            if response.is_success:
                return redirect("login")
            error = _backend_error(response)
        except httpx.RequestError:
            error = "Registration service is unavailable."
    return render(request, "simulator/register.html", {"error": error})


async def dashboard_view(request: HttpRequest):
    if not request.session.get("access_token"):
        return redirect("login")
    return render(request, "simulator/dashboard.html")


async def run_simulation_proxy(request: HttpRequest):
    if request.method != "POST":
        return JsonResponse({"error": "Method not allowed"}, status=405)
    token = request.session.get("access_token")
    if not token:
        return JsonResponse({"error": "Authentication required"}, status=401)
    try:
        payload = {
            "dimension_id": int(request.POST.get("dimension_id", "1")),
            "complexity": int(request.POST.get("complexity", "1")),
            "initial_speed": float(request.POST.get("initial_speed", "0")),
            "object_mass": float(request.POST.get("object_mass", "1")),
        }
    except (TypeError, ValueError):
        return JsonResponse({"error": "Invalid simulation parameters"}, status=400)
    try:
        response = await _post_backend(
            "/simulations/run",
            json=payload,
            headers={"Authorization": f"Bearer {token}"},
        )
        logger.info(
            "FastAPI POST /simulations/run status=%s body=%s "
            "authorization_attached=%s",
            response.status_code,
            response.text,
            bool(token),
        )
    except httpx.RequestError:
        return JsonResponse({"error": "Calculation engine unavailable"}, status=503)
    if response.status_code == 401:
        request.session.flush()
    try:
        body = response.json()
    except ValueError:
        body = {"error": "Invalid response from calculation engine"}
    return JsonResponse(body, status=response.status_code)


async def logout_view(request: HttpRequest):
    request.session.flush()
    return redirect("login")
