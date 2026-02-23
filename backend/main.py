"""
Tesla Nav Backend
FastAPI proxy: Tesla Fleet API + Google Maps route resolution & optimization

Install: pip install fastapi uvicorn httpx python-dotenv
Run:     uvicorn main:app --reload --port 8000
"""

import os, time, asyncio, urllib.parse
from typing import Optional
from fastapi import FastAPI, HTTPException, Header
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(title="Tesla Nav Proxy")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

TESLA_BASE = "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1"
GOOGLE_KEY = os.getenv("GOOGLE_MAPS_API_KEY", "")

# Shared HTTP client for connection reuse
http = httpx.AsyncClient(timeout=15)


# ─── MODELS ──────────────────────────────────────────────────────────────────

class RouteStop(BaseModel):
    id: str
    address: str
    label: Optional[str] = None
    notes: Optional[str] = None
    stopType: Optional[str] = "specific"
    searchQuery: Optional[str] = None
    openTime: Optional[str] = None
    closeTime: Optional[str] = None
    dwellMinutes: int = 20
    estimatedArrival: Optional[str] = None
    driveMinutesFromPrev: Optional[int] = None
    hasConflict: bool = False

class RoutePreferences(BaseModel):
    scenic: bool = False
    avoidHighways: bool = False
    avoidTolls: bool = False
    avoidFerries: bool = False
    preferenceNotes: Optional[str] = None

class RouteRequest(BaseModel):
    origin: Optional[str] = None
    stops: list[RouteStop]
    preferences: Optional[RoutePreferences] = None

class NavigateRequest(BaseModel):
    stops: list[str]


# ─── GOOGLE MAPS HELPERS ─────────────────────────────────────────────────────

async def geocode(address: str) -> Optional[dict]:
    """Geocode an address → {lat, lng}."""
    if not GOOGLE_KEY:
        return None
    r = await http.get(
        "https://maps.googleapis.com/maps/api/geocode/json",
        params={"address": address, "key": GOOGLE_KEY},
    )
    data = r.json()
    if data["status"] == "OK" and data["results"]:
        return data["results"][0]["geometry"]["location"]
    return None


async def search_places_along_route(
    query: str,
    origin_addr: str,
    destination_addr: str,
    prev_stop_addr: Optional[str] = None,
    next_stop_addr: Optional[str] = None,
) -> Optional[dict]:
    """
    Find a place matching `query` along the route.
    Strategy: search near the midpoint between the previous and next stop
    (or origin/destination if those aren't available).
    Returns {address, name, lat, lng} or None.
    """
    if not GOOGLE_KEY:
        return None

    # Use the tightest corridor: prev_stop → next_stop, falling back to origin → dest
    point_a = prev_stop_addr or origin_addr
    point_b = next_stop_addr or destination_addr

    # Geocode both endpoints concurrently
    geo_a, geo_b = await asyncio.gather(
        geocode(point_a),
        geocode(point_b),
    )
    if not geo_a or not geo_b:
        # Fallback: text search without location bias
        return await text_search_place(query)

    # Search near the midpoint
    mid_lat = (geo_a["lat"] + geo_b["lat"]) / 2
    mid_lng = (geo_a["lng"] + geo_b["lng"]) / 2

    # Radius = half the distance between points, clamped to 5-50 km
    import math
    dlat = geo_a["lat"] - geo_b["lat"]
    dlng = geo_a["lng"] - geo_b["lng"]
    dist_deg = math.sqrt(dlat**2 + dlng**2)
    radius_m = int(max(5000, min(50000, dist_deg * 111_000 / 2)))

    r = await http.get(
        "https://maps.googleapis.com/maps/api/place/textsearch/json",
        params={
            "query": query,
            "location": f"{mid_lat},{mid_lng}",
            "radius": radius_m,
            "key": GOOGLE_KEY,
        },
    )
    data = r.json()
    if data.get("status") == "OK" and data.get("results"):
        place = data["results"][0]
        return {
            "address": place.get("formatted_address", ""),
            "name": place.get("name", query),
            "lat": place["geometry"]["location"]["lat"],
            "lng": place["geometry"]["location"]["lng"],
        }
    return None


async def text_search_place(query: str) -> Optional[dict]:
    """Simple text search fallback without location bias."""
    if not GOOGLE_KEY:
        return None
    r = await http.get(
        "https://maps.googleapis.com/maps/api/place/textsearch/json",
        params={"query": query, "key": GOOGLE_KEY},
    )
    data = r.json()
    if data.get("status") == "OK" and data.get("results"):
        place = data["results"][0]
        return {
            "address": place.get("formatted_address", ""),
            "name": place.get("name", query),
            "lat": place["geometry"]["location"]["lat"],
            "lng": place["geometry"]["location"]["lng"],
        }
    return None


async def get_directions(
    origin: str,
    destination: str,
    waypoints: list[str],
    prefs: Optional[RoutePreferences] = None,
) -> Optional[dict]:
    """
    Google Directions API with waypoints and route preferences.
    Returns {legs: [{duration_min, distance_km}, ...], total_duration_min, total_distance_km}.
    """
    if not GOOGLE_KEY:
        return None

    avoid_parts = []
    if prefs:
        if prefs.avoidHighways or prefs.scenic:
            avoid_parts.append("highways")
        if prefs.avoidTolls:
            avoid_parts.append("tolls")
        if prefs.avoidFerries:
            avoid_parts.append("ferries")

    params = {
        "origin": origin,
        "destination": destination,
        "departure_time": "now",
        "key": GOOGLE_KEY,
    }
    if waypoints:
        params["waypoints"] = "|".join(waypoints)
    if avoid_parts:
        params["avoid"] = "|".join(avoid_parts)

    r = await http.get(
        "https://maps.googleapis.com/maps/api/directions/json",
        params=params,
    )
    data = r.json()
    if data["status"] != "OK" or not data.get("routes"):
        return None

    route = data["routes"][0]
    legs = []
    total_dur = 0
    total_dist = 0
    for leg in route["legs"]:
        dur_sec = leg.get("duration_in_traffic", leg["duration"])["value"]
        dist_m = leg["distance"]["value"]
        dur_min = dur_sec // 60
        legs.append({"duration_min": dur_min, "distance_km": round(dist_m / 1000, 1)})
        total_dur += dur_min
        total_dist += dist_m

    return {
        "legs": legs,
        "total_duration_min": total_dur,
        "total_distance_km": round(total_dist / 1000, 1),
    }


# ─── HELPERS ─────────────────────────────────────────────────────────────────

def time_to_minutes(t: str) -> int:
    h, m = map(int, t.split(":"))
    return h * 60 + m

def minutes_to_time(m: int) -> str:
    h = (m // 60) % 24
    mn = m % 60
    ampm = "PM" if h >= 12 else "AM"
    h12 = h % 12 or 12
    return f"{h12}:{mn:02d} {ampm}"


# ─── ROUTE RESOLUTION + OPTIMIZATION ─────────────────────────────────────────

@app.post("/route")
async def resolve_and_optimize(body: RouteRequest):
    """
    Main endpoint: resolves search-type stops, gets directions with preferences,
    and returns the fully resolved route with drive times.
    """
    if not body.stops:
        raise HTTPException(400, "No stops")

    origin = body.origin or body.stops[0].address
    final_dest = body.stops[-1].address
    prefs = body.preferences
    resolved_stops: list[RouteStop] = []

    # Phase 1: Resolve search-type stops via Google Places
    for i, stop in enumerate(body.stops):
        if stop.stopType == "search" and stop.searchQuery:
            prev_addr = body.stops[i - 1].address if i > 0 else origin
            next_addr = body.stops[i + 1].address if i < len(body.stops) - 1 else final_dest

            place = await search_places_along_route(
                query=stop.searchQuery,
                origin_addr=origin,
                destination_addr=final_dest,
                prev_stop_addr=prev_addr,
                next_stop_addr=next_addr,
            )
            if place:
                resolved = stop.model_copy(update={
                    "address": place["address"],
                    "label": stop.label or place["name"],
                    "stopType": "resolved",
                })
            else:
                resolved = stop.model_copy(update={
                    "notes": f"Could not find '{stop.searchQuery}' along route — using as-is",
                })
            resolved_stops.append(resolved)
        else:
            resolved_stops.append(stop)

    # Phase 2: Get directions with route preferences (scenic, avoid highways, etc.)
    waypoint_addrs = [s.address for s in resolved_stops[:-1]] if len(resolved_stops) > 1 else []
    dest_addr = resolved_stops[-1].address

    directions = await get_directions(
        origin=origin,
        destination=dest_addr,
        waypoints=waypoint_addrs,
        prefs=prefs,
    )

    # Phase 3: Attach drive times from Directions API to each stop
    if directions and directions["legs"]:
        for i, stop in enumerate(resolved_stops):
            if i < len(directions["legs"]):
                leg = directions["legs"][i]
                resolved_stops[i] = stop.model_copy(update={
                    "driveMinutesFromPrev": leg["duration_min"],
                })

    # Phase 4: Time-window conflict detection (if any stops have time constraints)
    has_windows = any(s.openTime or s.closeTime for s in resolved_stops)
    if has_windows and directions:
        current_time = 8 * 60  # default 8 AM start
        for i, stop in enumerate(resolved_stops):
            drive = stop.driveMinutesFromPrev or 0
            arrival = current_time + drive
            open_min = time_to_minutes(stop.openTime) if stop.openTime else 0
            close_min = time_to_minutes(stop.closeTime) if stop.closeTime else 23 * 60 + 59
            visit_start = max(arrival, open_min)
            conflict = visit_start + stop.dwellMinutes > close_min

            resolved_stops[i] = stop.model_copy(update={
                "estimatedArrival": minutes_to_time(visit_start),
                "hasConflict": conflict,
            })
            current_time = visit_start + stop.dwellMinutes

    return {
        "stops": [s.model_dump() for s in resolved_stops],
        "directions": directions,
    }


# ─── LEGACY OPTIMIZE (kept for backward compat) ──────────────────────────────

@app.post("/optimize")
async def optimize_route(body: RouteRequest):
    """Redirect to the new /route endpoint."""
    return await resolve_and_optimize(body)


# ─── TESLA PROXY ──────────────────────────────────────────────────────────────

@app.get("/vehicles")
async def get_vehicles(authorization: str = Header(...)):
    r = await http.get(
        f"{TESLA_BASE}/vehicles",
        headers={"Authorization": authorization},
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    return r.json()


@app.post("/vehicles/{vehicle_id}/wake")
async def wake_vehicle(vehicle_id: str, authorization: str = Header(...)):
    r = await http.post(
        f"{TESLA_BASE}/vehicles/{vehicle_id}/wake",
        headers={"Authorization": authorization},
    )
    return r.json()


@app.post("/vehicles/{vehicle_id}/navigate")
async def send_navigation(vehicle_id: str, body: NavigateRequest,
                          authorization: str = Header(...)):
    if not body.stops:
        raise HTTPException(400, "No stops provided")

    destination = body.stops[-1]
    waypoints = body.stops[:-1]

    waypoints_str = "|".join(waypoints)
    maps_url = f"https://maps.google.com/maps?daddr={urllib.parse.quote(destination)}"
    if waypoints:
        maps_url += f"&waypoints={urllib.parse.quote(waypoints_str)}"

    payload = {
        "type": "share_ext_content_raw",
        "locale": "en-US",
        "timestamp_ms": str(time.time_ns() // 1_000_000),
        "value": {
            "android.intent.extra.TEXT": maps_url,
        },
    }

    r = await http.post(
        f"{TESLA_BASE}/vehicles/{vehicle_id}/command/navigation_request",
        json=payload,
        headers={"Authorization": authorization, "Content-Type": "application/json"},
    )

    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)

    data = r.json()
    if not data.get("response", {}).get("result"):
        reason = data.get("response", {}).get("reason", "Unknown")
        raise HTTPException(400, f"Tesla rejected command: {reason}")

    return {"ok": True, "stops_sent": len(body.stops)}


@app.get("/health")
async def health():
    return {"status": "ok", "google_maps": bool(GOOGLE_KEY)}


@app.on_event("shutdown")
async def shutdown():
    await http.aclose()
