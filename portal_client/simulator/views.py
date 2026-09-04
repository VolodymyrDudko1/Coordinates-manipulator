import httpx
from django.conf import settings
from django.http import HttpRequest, HttpResponse, JsonResponse
from django.shortcuts import render

# External Industry Standards: Using asynchronous HTTPX client to ensure
# our Django worker threads are not blocked during FastAPI communication.


async def simulation_dashboard(request: HttpRequest) -> HttpResponse:
    """
    Renders the main dashboard containing our inputs and HTML5 Canvas.
    """
    return render(request, "simulator/index.html")


async def run_simulation_proxy(request: HttpRequest) -> JsonResponse:
    """
    Asynchronously forwards user parameters (coordinates, speed, mass)
    to our FastAPI calculations engine and proxies the trajectory back to the client.
    """
    if request.method != "POST":
        return JsonResponse({"error": "Method not allowed"}, status=405)

    try:
        # 1. Parse incoming parameters safely
        dimension_id = int(request.POST.get("dimension_id", 1))
        complexity = int(request.POST.get("complexity", 1))
        initial_speed = float(request.POST.get("initial_speed", 0.0))
        object_mass = float(request.POST.get("object_mass", 1.0))
    except (ValueError, TypeError):
        return JsonResponse({"error": "Invalid parameter values provided"}, status=400)

    payload = {
        "dimension_id": dimension_id,
        "complexity": complexity,
        "initial_speed": initial_speed,
        "object_mass": object_mass,
    }

    # settings.FASTAPI_BACKEND_URL should be configured in settings.py (e.g. "http://localhost:8000")
    fastapi_url = f"{settings.FASTAPI_BACKEND_URL}/simulations/run"

    async with httpx.AsyncClient() as client:
        try:
            response = await client.post(fastapi_url, json=payload, timeout=10.0)
            return JsonResponse(response.json(), status=response.status_code)
        except httpx.RequestError as exc:
            return JsonResponse(
                {"error": f"Calculation engine unreachable: {str(exc)}"}, status=503
            )
