"""
Tesla Nav Backend
FastAPI proxy: Tesla Fleet API + Google Maps route resolution & optimization

Install: pip install fastapi uvicorn httpx python-dotenv
Run:     uvicorn main:app --reload --port 8000
"""

import os, re, json, time, asyncio, urllib.parse, logging, traceback, csv, io, math
from typing import Optional
from datetime import datetime
from fastapi import FastAPI, HTTPException, Header, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import httpx
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("teslanav")

app = FastAPI(title="Tesla Nav Proxy")

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.error(f"Unhandled error on {request.method} {request.url.path}: {exc}\n{traceback.format_exc()}")
    return JSONResponse(status_code=500, content={"detail": str(exc)})

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

TESLA_BASE = "https://fleet-api.prd.na.vn.cloud.tesla.com/api/1"
TESLA_AUTH_BASE = "https://auth.tesla.com/oauth2/v3"
GOOGLE_KEY_ENV = os.getenv("GOOGLE_MAPS_API_KEY", "")

def get_google_key(header_key: str = "") -> str:
    """Use client-provided key if available, else fall back to env var."""
    return header_key.strip() if header_key.strip() else GOOGLE_KEY_ENV

TESLA_CLIENT_ID = os.getenv("TESLA_CLIENT_ID", "")
TESLA_CLIENT_SECRET = os.getenv("TESLA_CLIENT_SECRET", "")
TESLA_REDIRECT_URI = os.getenv("TESLA_REDIRECT_URI", "http://localhost:8000/tesla/callback")

# Shared HTTP client for connection reuse
http = httpx.AsyncClient(timeout=15)


# ─── TOKEN REFRESH HELPER ─────────────────────────────────────────────────

async def refresh_tesla_token(refresh_token: str) -> Optional[dict]:
    """Exchange a refresh token for a new access + refresh token pair."""
    if not TESLA_CLIENT_ID or not refresh_token:
        return None
    try:
        r = await http.post(
            f"{TESLA_AUTH_BASE}/token",
            data={
                "grant_type": "refresh_token",
                "client_id": TESLA_CLIENT_ID,
                "refresh_token": refresh_token,
            },
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        if r.status_code == 200:
            tokens = r.json()
            logger.info("Token refreshed successfully")
            return tokens
        logger.error(f"Token refresh failed: {r.status_code} {r.text[:200]}")
    except Exception as e:
        logger.error(f"Token refresh error: {e}")
    return None


async def tesla_request(
    method: str,
    path: str,
    authorization: str,
    refresh_token: str = "",
    **kwargs,
) -> tuple:
    """
    Make a Tesla API request with automatic token refresh on 401.
    Returns (httpx.Response, new_tokens_dict_or_None).
    """
    headers = {"Authorization": authorization, **kwargs.pop("headers", {})}
    r = await http.request(method, f"{TESLA_BASE}{path}", headers=headers, **kwargs)

    if r.status_code == 401 and refresh_token:
        logger.info(f"Got 401 on {path}, attempting token refresh")
        tokens = await refresh_tesla_token(refresh_token)
        if tokens and tokens.get("access_token"):
            new_auth = f"Bearer {tokens['access_token']}"
            headers["Authorization"] = new_auth
            r = await http.request(method, f"{TESLA_BASE}{path}", headers=headers, **kwargs)
            return r, tokens

    return r, None


def add_token_headers(response, tokens: Optional[dict]):
    """Add refreshed token headers to the response if tokens were refreshed."""
    if tokens:
        response.headers["X-New-Access-Token"] = tokens.get("access_token", "")
        if tokens.get("refresh_token"):
            response.headers["X-New-Refresh-Token"] = tokens["refresh_token"]


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
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    distanceMeters: Optional[int] = None

class ClimateRequest(BaseModel):
    on: bool = True
    temp_c: Optional[float] = None

class OptimizeRequest(BaseModel):
    origin: Optional[str] = None
    stops: list[RouteStop]

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


# ─── REDFIN MODELS + CONFIG ──────────────────────────────────────────────────

REDFIN_CITIES = {
    "Redwood City":  {"region_id": 15525, "slug": "Redwood-City"},
    "San Mateo":     {"region_id": 17490, "slug": "San-Mateo"},
    "San Carlos":    {"region_id": 16687, "slug": "San-Carlos"},
    "Belmont":       {"region_id": 1362,  "slug": "Belmont"},
    "Millbrae":      {"region_id": 12130, "slug": "Millbrae"},
}

REDFIN_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://www.redfin.com/",
}

def lat_lng_to_poly(lat: float, lng: float, radius_miles: float) -> str:
    """Return a closed polygon string (5 points: SW, NW, NE, SE, SW) for Redfin poly param."""
    lat_deg = radius_miles / 69.0
    lng_deg = radius_miles / (69.0 * math.cos(math.radians(lat)))
    sw_lat, sw_lng = lat - lat_deg, lng - lng_deg
    nw_lat, nw_lng = lat + lat_deg, lng - lng_deg
    ne_lat, ne_lng = lat + lat_deg, lng + lng_deg
    se_lat, se_lng = lat - lat_deg, lng + lng_deg
    return f"{sw_lng} {sw_lat},{nw_lng} {nw_lat},{ne_lng} {ne_lat},{se_lng} {se_lat},{sw_lng} {sw_lat}"

# Map Redfin CSV SOURCE values to dataSourceId for photo URLs
REDFIN_SOURCE_TO_DSID = {
    "MLSListings": 8,
    "San Francisco MLS": 9,
    "Bay East MLS": 6,
    "MetroList MLS": 10,
    "BAREIS MLS": 7,
    "CRMLS": 1,
    "CLAW MLS": 14,
    "SDMLS": 5,
    "TheMLS": 2,
    "FMLS": 17,
    "Bright MLS": 4,
    "NWMLS": 3,
    "RMLS": 11,
    "ARMLS": 16,
    "HAR": 15,
    "Stellar MLS": 18,
    "GAMLS": 19,
    "Canopy MLS": 20,
}

REMODEL_KW = ["remodel", "renovated", "renovation", "updated kitchen", "updated bath",
              "newly updated", "fully updated", "move-in ready", "turn-key", "turnkey"]
CONVERT_KW = ["office", "den", "bonus room", "family room", "flex room", "flex space"]
EXPAND_KW = ["adu potential", "build", "large lot", "development potential",
             "expansion", "add-on", "addition possible", "room to grow"]

# In-memory cache: {cache_key: (timestamp, results)}
_listings_cache: dict[str, tuple[float, list]] = {}
CACHE_TTL = 3600  # 1 hour

class SearchCriteria(BaseModel):
    cities: list[str] = list(REDFIN_CITIES.keys())
    minPrice: int = 1_500_000
    maxPrice: int = 2_900_000
    minBeds: int = 3
    maxBeds: Optional[int] = None
    minBaths: Optional[float] = None
    minSqft: int = 1750
    maxSqft: Optional[int] = None
    bedroomsIdeal: int = 4
    sqftPreferred: int = 2000
    lotSqftMin: int = 5500
    lotSqftMax: Optional[int] = None
    remodelPreference: str = "any"  # "must", "prefer", "any", "open_to_renovating"
    maxDaysOnMarket: Optional[int] = None  # None = no limit
    numPerCity: int = 10  # max listings per city
    listingStatus: str = "for_sale"  # "for_sale", "recently_sold", "pending" — comma-separated for multi e.g. "recently_sold,pending"
    soldWithinDays: int = 365  # only for recently_sold
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    radiusMiles: int = 50


# ─── GOOGLE MAPS HELPERS ─────────────────────────────────────────────────────

async def geocode(address: str, gkey: str) -> Optional[dict]:
    """Geocode an address → {lat, lng}. Uses Google Maps if key available, else Nominatim."""
    if gkey:
        r = await http.get(
            "https://maps.googleapis.com/maps/api/geocode/json",
            params={"address": address, "key": gkey},
        )
        data = r.json()
        if data["status"] == "OK" and data["results"]:
            return data["results"][0]["geometry"]["location"]
    # Fallback to Nominatim (free, no key needed)
    try:
        r = await http.get(
            "https://nominatim.openstreetmap.org/search",
            params={"q": address, "format": "json", "limit": 1, "countrycodes": "us"},
            headers={"User-Agent": "OpenHouseApp/1.0"},
        )
        results = r.json()
        if results:
            return {"lat": float(results[0]["lat"]), "lng": float(results[0]["lon"])}
    except Exception:
        pass
    return None


async def search_places_along_route(
    query: str,
    origin_addr: str,
    destination_addr: str,
    gkey: str,
    prev_stop_addr: Optional[str] = None,
    next_stop_addr: Optional[str] = None,
) -> Optional[dict]:
    """
    Find a place matching `query` along the route.
    Strategy: search near the midpoint between the previous and next stop
    (or origin/destination if those aren't available).
    Returns {address, name, lat, lng} or None.
    """
    if not gkey:
        return None

    # Use the tightest corridor: prev_stop → next_stop, falling back to origin → dest
    point_a = prev_stop_addr or origin_addr
    point_b = next_stop_addr or destination_addr

    # Geocode both endpoints concurrently
    geo_a, geo_b = await asyncio.gather(
        geocode(point_a, gkey),
        geocode(point_b, gkey),
    )
    if not geo_a or not geo_b:
        # Fallback: text search without location bias
        return await text_search_place(query, gkey)

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
            "key": gkey,
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


async def text_search_place(query: str, gkey: str) -> Optional[dict]:
    """Simple text search fallback without location bias."""
    if not gkey:
        return None
    r = await http.get(
        "https://maps.googleapis.com/maps/api/place/textsearch/json",
        params={"query": query, "key": gkey},
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
    gkey: str,
    prefs: Optional[RoutePreferences] = None,
) -> Optional[dict]:
    """
    Google Routes API (v2) with waypoints and route preferences.
    Returns {legs: [{duration_min, distance_km}, ...], total_duration_min, total_distance_km}.
    """
    if not gkey:
        return None

    # Build route modifiers
    route_modifiers = {}
    if prefs:
        if prefs.avoidHighways or prefs.scenic:
            route_modifiers["avoidHighways"] = True
        if prefs.avoidTolls:
            route_modifiers["avoidTolls"] = True
        if prefs.avoidFerries:
            route_modifiers["avoidFerries"] = True

    body = {
        "origin": {"address": origin},
        "destination": {"address": destination},
        "travelMode": "DRIVE",
        "routingPreference": "TRAFFIC_AWARE",
    }
    if waypoints:
        body["intermediates"] = [{"address": wp} for wp in waypoints]
    if route_modifiers:
        body["routeModifiers"] = route_modifiers

    r = await http.post(
        "https://routes.googleapis.com/directions/v2:computeRoutes",
        json=body,
        headers={
            "X-Goog-Api-Key": gkey,
            "X-Goog-FieldMask": "routes.legs.duration,routes.legs.distanceMeters",
        },
    )
    data = r.json()
    if "routes" not in data or not data["routes"]:
        return None

    route = data["routes"][0]
    legs = []
    total_dur = 0
    total_dist = 0
    for leg in route.get("legs", []):
        dur_sec = int(leg.get("duration", "0s").rstrip("s"))
        dist_m = leg.get("distanceMeters", 0)
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
async def resolve_and_optimize(
    body: RouteRequest,
    x_google_maps_key: Optional[str] = Header(None),
):
    """
    Main endpoint: resolves search-type stops, gets directions with preferences,
    and returns the fully resolved route with drive times.
    Google Maps key can be passed via X-Google-Maps-Key header or .env.
    """
    if not body.stops:
        raise HTTPException(400, "No stops")

    gkey = get_google_key(x_google_maps_key or "")
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
                gkey=gkey,
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

    # Phase 1b: Geocode all resolved stops for lat/lng
    async def geocode_stop(stop: RouteStop) -> RouteStop:
        if stop.latitude and stop.longitude:
            return stop
        geo = await geocode(stop.address, gkey)
        if geo:
            return stop.model_copy(update={"latitude": geo["lat"], "longitude": geo["lng"]})
        return stop

    resolved_stops = list(await asyncio.gather(*[geocode_stop(s) for s in resolved_stops]))

    # Phase 2: Get directions with route preferences (scenic, avoid highways, etc.)
    waypoint_addrs = [s.address for s in resolved_stops[:-1]] if len(resolved_stops) > 1 else []
    dest_addr = resolved_stops[-1].address

    directions = await get_directions(
        origin=origin,
        destination=dest_addr,
        waypoints=waypoint_addrs,
        gkey=gkey,
        prefs=prefs,
    )

    # Phase 3: Attach drive times + distance from Directions API to each stop
    if directions and directions["legs"]:
        for i, stop in enumerate(resolved_stops):
            if i < len(directions["legs"]):
                leg = directions["legs"][i]
                resolved_stops[i] = stop.model_copy(update={
                    "driveMinutesFromPrev": leg["duration_min"],
                    "distanceMeters": int(leg["distance_km"] * 1000),
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


# ─── REDFIN LISTING HELPERS ──────────────────────────────────────────────────

async def fetch_redfin_api(city_name: str, city_info: dict, criteria: SearchCriteria, poly: str = None) -> list[dict]:
    """Fetch active listings from Redfin stingray GIS JSON API for a single city.
    Note: JSON endpoint ignores status param — only use for active/for_sale.
    For sold/pending, use fetch_redfin_csv() instead."""

    params = {
        "al": 1,
        "num_homes": max(criteria.numPerCity * 2, 50),
        "ord": "days-on-redfin-asc",
        "page_number": 1,
        "sf": "1,2,3,5,6,7",
        "status": 9,
        "uipt": 1,
        "v": 8,
        "min_price": criteria.minPrice,
        "max_price": criteria.maxPrice,
        "num_beds": criteria.minBeds,
        "min_sqft": criteria.minSqft,
    }
    if poly:
        params["poly"] = poly
    else:
        params["market"] = "sanfrancisco"
        params["region_id"] = city_info["region_id"]
        params["region_type"] = 6
    try:
        r = await http.get(
            "https://www.redfin.com/stingray/api/gis",
            params=params,
            headers=REDFIN_HEADERS,
            timeout=15,
        )
        if r.status_code != 200:
            return []
        text = r.text
        if text.startswith("{}&&"):
            text = text[4:]
        data = json.loads(text)
        homes = data.get("payload", {}).get("homes", [])
        listings = []
        for h in homes:
            # Redfin GIS API returns flat structure (not nested under homeData)
            # Price
            price_obj = h.get("price", {})
            price = price_obj.get("value", 0) if isinstance(price_obj, dict) else (price_obj or 0)

            # Address
            street_obj = h.get("streetLine", {})
            address = street_obj.get("value", "Unknown") if isinstance(street_obj, dict) else (street_obj or "Unknown")
            city_val = h.get("city", city_name)

            # Sqft / Lot
            sqft_obj = h.get("sqFt", {})
            sqft = sqft_obj.get("value", 0) if isinstance(sqft_obj, dict) else (sqft_obj or 0)
            lot_obj = h.get("lotSize", {})
            lot = lot_obj.get("value", 0) if isinstance(lot_obj, dict) else (lot_obj or 0)

            # Year built
            yb_obj = h.get("yearBuilt", {})
            year_built = yb_obj.get("value") if isinstance(yb_obj, dict) else yb_obj

            # Days on market (dom.value is the correct field)
            dom_obj = h.get("dom", {})
            dom = dom_obj.get("value", 0) if isinstance(dom_obj, dict) else (dom_obj or 0)
            dom = int(dom) if dom else 0

            # Filter by max days on market
            if criteria.maxDaysOnMarket is not None and dom > criteria.maxDaysOnMarket:
                continue

            # MLS ID
            mls_obj = h.get("mlsId", {})
            mls_id = mls_obj.get("value", "") if isinstance(mls_obj, dict) else ""

            # Photo URL — pattern: /photo/{dataSourceId}/bigphoto/{last3ofMLS}/{MLS_ID}_0.jpg
            image_url = ""
            data_source_id = h.get("dataSourceId", 0)
            if mls_id:
                last3 = mls_id[-3:] if len(mls_id) >= 3 else mls_id
                image_url = f"https://ssl.cdn-redfin.com/photo/{data_source_id}/bigphoto/{last3}/{mls_id}_0.jpg"

            # Open house info — use timestamps for accurate start/end
            open_houses = []
            oh_start_ts = h.get("openHouseStart")
            oh_end_ts = h.get("openHouseEnd")
            if oh_start_ts and oh_end_ts:
                try:
                    from datetime import timezone
                    start_dt = datetime.fromtimestamp(int(oh_start_ts) / 1000)
                    end_dt = datetime.fromtimestamp(int(oh_end_ts) / 1000)
                    open_houses.append({
                        "date": start_dt.strftime("%b %d"),
                        "startTime": start_dt.strftime("%-I:%M %p"),
                        "endTime": end_dt.strftime("%-I:%M %p"),
                    })
                except Exception:
                    pass
            if not open_houses:
                # Fallback: parse eventName "Open House - 1:00 - 4:00 PM"
                oh_event = h.get("openHouseEventName", "")
                oh_start_fmt = h.get("openHouseStartFormatted", "")
                if oh_event and oh_start_fmt:
                    import re as _re
                    time_match = _re.findall(r'(\d{1,2}:\d{2})\s*(?:-\s*)?(\d{1,2}:\d{2}\s*[AP]M)', oh_event)
                    if time_match:
                        start_t, end_t = time_match[0]
                        # Add AM/PM to start if missing — assume same meridian as end
                        if "AM" not in start_t.upper() and "PM" not in start_t.upper():
                            meridian = "PM" if "PM" in end_t.upper() else "AM"
                            start_t = f"{start_t} {meridian}"
                        date_part = oh_start_fmt.split(",")[0].strip() if "," in oh_start_fmt else oh_start_fmt
                        open_houses.append({
                            "date": date_part,
                            "startTime": start_t,
                            "endTime": end_t,
                        })

            # Detect features from listingRemarks and listingTags
            remarks = (h.get("listingRemarks", "") or "").lower()
            tags_list = h.get("listingTags", []) or []
            tags_lower = " ".join(t.lower() for t in tags_list)
            combined_text = remarks + " " + tags_lower

            remodeled = any(kw in combined_text for kw in REMODEL_KW)
            convertible = any(kw in combined_text for kw in CONVERT_KW)
            expandable = any(kw in combined_text for kw in EXPAND_KW)

            remodel_year = None
            if remodeled:
                yr_match = re.search(r'(?:remodel|renovate|update)(?:ed|d)?\s+(?:in\s+)?(\d{4})', combined_text)
                if yr_match:
                    remodel_year = int(yr_match.group(1))

            # Key facts as notes
            key_facts = h.get("keyFacts", [])
            notes = ". ".join(kf.get("description", "") for kf in (key_facts or []) if kf.get("description"))
            if remarks:
                notes = remarks[:300]

            beds = h.get("beds") or 0
            baths = h.get("baths") or 0

            # Strict post-fetch filtering — Redfin API doesn't always respect params
            if int(price) < criteria.minPrice or int(price) > criteria.maxPrice:
                continue
            if beds < criteria.minBeds:
                continue
            if criteria.maxBeds is not None and beds > criteria.maxBeds:
                continue
            if criteria.minBaths is not None and baths < criteria.minBaths:
                continue
            if int(sqft) < criteria.minSqft and int(sqft) > 0:
                continue
            if criteria.maxSqft is not None and int(sqft) > criteria.maxSqft and int(sqft) > 0:
                continue

            # Extract sold price/date for recently sold listings
            sold_price = None
            sold_date = None
            if criteria.listingStatus == "recently_sold":
                sp_obj = h.get("soldPrice", h.get("price", {}))
                if isinstance(sp_obj, dict):
                    sold_price = int(sp_obj.get("value", 0) or 0) or None
                elif sp_obj:
                    sold_price = int(sp_obj) if sp_obj else None
                sd_ts = h.get("soldDate") or h.get("saleDate")
                if sd_ts:
                    try:
                        sold_date = datetime.fromtimestamp(int(sd_ts) / 1000).strftime("%Y-%m-%d")
                    except Exception:
                        sold_date = None
                # For sold: use the original list price as "price"
                lp_obj = h.get("listPrice", h.get("price", {}))
                if isinstance(lp_obj, dict):
                    list_price = int(lp_obj.get("value", price) or price)
                else:
                    list_price = int(lp_obj) if lp_obj else int(price)
                price = list_price

            listing = {
                "address": address,
                "city": city_val,
                "price": int(price),
                "bedrooms": beds,
                "bathrooms": baths,
                "sqft": int(sqft),
                "lotSqft": int(lot),
                "yearBuilt": year_built,
                "daysOnMarket": dom,
                "url": "https://www.redfin.com" + (h.get("url", "") or ""),
                "imageUrl": image_url,
                "mlsId": mls_id,
                "remodeled": remodeled,
                "remodelYear": remodel_year,
                "convertibleRooms": convertible,
                "expandable": expandable,
                "notes": notes,
                "openHouses": open_houses if open_houses else None,
                "soldPrice": sold_price,
                "soldDate": sold_date,
                "listingStatus": criteria.listingStatus,
            }
            listings.append(listing)

        # Sort appropriately
        if criteria.listingStatus == "recently_sold":
            listings.sort(key=lambda l: l.get("soldDate") or "", reverse=True)
        else:
            listings.sort(key=lambda l: l["daysOnMarket"])
        return listings[:criteria.numPerCity]
    except Exception:
        return []


async def fetch_redfin_csv(
    criteria: SearchCriteria,
    poly: str = None,
    region_id: int = None,
    city_name: str = "",
    status_override: int = None,
) -> list[dict]:
    """Fetch listings via Redfin gis-csv endpoint. Correctly handles sold/pending status."""
    status_map = {"for_sale": 9, "recently_sold": 130, "pending": 2}
    redfin_status = status_override or status_map.get(criteria.listingStatus, 9)

    params = {
        "al": 1,
        "num_homes": max(criteria.numPerCity * 3, 200),
        "ord": "days-on-redfin-asc",
        "page_number": 1,
        "sf": "1,2,3,5,6,7",
        "status": redfin_status,
        "uipt": 1,
        "v": 8,
    }
    if poly:
        params["poly"] = poly
    elif region_id:
        params["region_id"] = region_id
        params["region_type"] = 6
        params["market"] = "sanfrancisco"
    else:
        return []

    if criteria.minPrice:
        params["min_price"] = criteria.minPrice
    if criteria.maxPrice:
        params["max_price"] = criteria.maxPrice
    if criteria.minBeds:
        params["num_beds"] = criteria.minBeds
    if criteria.minSqft:
        params["min_sqft"] = criteria.minSqft
    if criteria.listingStatus == "recently_sold":
        params["sold_within_days"] = criteria.soldWithinDays

    try:
        r = await http.get(
            "https://www.redfin.com/stingray/api/gis-csv",
            params=params,
            headers=REDFIN_HEADERS,
            timeout=30,
        )
        if r.status_code != 200:
            logger.warning(f"gis-csv returned {r.status_code}")
            return []
        reader = csv.DictReader(io.StringIO(r.text))
        listings = []
        for row in reader:
            try:
                price = int(float(row.get("PRICE", "0") or "0"))
                beds = int(float(row.get("BEDS", "0") or "0"))
                baths = float(row.get("BATHS", "0") or "0")
                sqft = int(float(row.get("SQUARE FEET", "0") or "0"))
                lot = int(float(row.get("LOT SIZE", "0") or "0"))
                dom = int(float(row.get("DAYS ON MARKET", "0") or "0"))
                year_built_str = row.get("YEAR BUILT", "")
                year_built = int(year_built_str) if year_built_str else None
                address = row.get("ADDRESS", "Unknown")
                city_val = row.get("CITY", city_name) or city_name
                mls_id = row.get("MLS#", "")
                url = row.get("URL (SEE https://www.redfin.com/buy-a-home/comparative-market-analysis FOR INFO ON PRICING)", "")
                if not url:
                    url = row.get("URL", "")
                lat_val = row.get("LATITUDE", "")
                lng_val = row.get("LONGITUDE", "")
                status_val = row.get("STATUS", "Active")

                # Filtering
                if criteria.minPrice and price < criteria.minPrice:
                    continue
                if criteria.maxPrice and price > criteria.maxPrice:
                    continue
                if criteria.minBeds and beds < criteria.minBeds:
                    continue
                if criteria.maxBeds is not None and beds > criteria.maxBeds:
                    continue
                if criteria.minBaths is not None and baths < criteria.minBaths:
                    continue
                if criteria.minSqft and sqft > 0 and sqft < criteria.minSqft:
                    continue
                if criteria.maxSqft is not None and sqft > 0 and sqft > criteria.maxSqft:
                    continue
                if criteria.maxDaysOnMarket is not None and dom > criteria.maxDaysOnMarket:
                    continue

                # Image URL — use SOURCE column to resolve dataSourceId
                image_url = ""
                source = row.get("SOURCE", "")
                data_source_id = REDFIN_SOURCE_TO_DSID.get(source, 8)
                if mls_id:
                    last3 = mls_id[-3:] if len(mls_id) >= 3 else mls_id
                    image_url = f"https://ssl.cdn-redfin.com/photo/{data_source_id}/bigphoto/{last3}/{mls_id}_0.jpg"

                # Sold info
                sold_price = None
                sold_date = None
                listing_status = criteria.listingStatus
                if status_val and "sold" in status_val.lower():
                    listing_status = "recently_sold"
                    sold_price = price
                    sold_date_str = row.get("SOLD DATE", "")
                    if sold_date_str:
                        try:
                            sold_date = datetime.strptime(sold_date_str, "%B-%d-%Y").strftime("%Y-%m-%d")
                        except Exception:
                            try:
                                sold_date = datetime.strptime(sold_date_str, "%m/%d/%Y").strftime("%Y-%m-%d")
                            except Exception:
                                sold_date = sold_date_str
                elif status_val and "pending" in status_val.lower():
                    listing_status = "pending"
                elif status_val and ("contingent" in status_val.lower()):
                    listing_status = "pending"

                listing = {
                    "address": address,
                    "city": city_val,
                    "price": price,
                    "bedrooms": beds,
                    "bathrooms": baths,
                    "sqft": sqft,
                    "lotSqft": lot,
                    "yearBuilt": year_built,
                    "daysOnMarket": dom,
                    "url": url if url.startswith("http") else f"https://www.redfin.com{url}",
                    "imageUrl": image_url,
                    "mlsId": mls_id,
                    "remodeled": False,
                    "remodelYear": None,
                    "convertibleRooms": False,
                    "expandable": False,
                    "notes": "",
                    "openHouses": None,
                    "soldPrice": sold_price,
                    "soldDate": sold_date,
                    "listingStatus": listing_status,
                    "latitude": float(lat_val) if lat_val else None,
                    "longitude": float(lng_val) if lng_val else None,
                }
                listings.append(listing)
            except Exception as e:
                logger.debug(f"Skipping CSV row: {e}")
                continue

        # Sort
        if criteria.listingStatus == "recently_sold":
            listings.sort(key=lambda l: l.get("soldDate") or "", reverse=True)
        else:
            listings.sort(key=lambda l: l["daysOnMarket"])
        return listings
    except Exception as e:
        logger.error(f"fetch_redfin_csv error: {e}")
        return []


def _extract_prices_from_page(listing: dict, text: str):
    """Extract list price and sold price from Redfin listing page embedded data.

    Validates price history dates: sold date must be after list date,
    and list date must be within 4 months of sold date.
    """
    found_list = False
    found_sold = False

    # Strategy 1: listingPrice from initialInfo cache
    # In escaped JSON within the page: \"listingPrice\":\"1998000_US_DOLLAR\"
    lp = re.search(r'listingPrice\\?"\\?:\s*\\?"(\d{5,})_', text)
    if lp:
        listing["price"] = int(lp.group(1))
        found_list = True

    # Strategy 2: Sold price from the FIRST priceInfo on the page (main listing, not comps).
    # The first priceInfo always belongs to the main listing.
    first_pi = re.search(r'\\?"priceInfo\\?":\s*\{\\?"amount\\?":\s*(\d{5,}),\\?"label\\?":\s*\\?"([^\\"]*)\\?"', text)
    if not first_pi:
        first_pi = re.search(r'\\?"priceInfo\\?":\s*\{[^}]*?\\?"amount\\?":\s*(\d{5,})[^}]*?\\?"label\\?":\s*\\?"([^\\"]*)\\?"', text)
    if first_pi and "Sold" in first_pi.group(2):
        listing["soldPrice"] = int(first_pi.group(1))
        found_sold = True

    # Strategy 3: Price history events as fallback — with date validation
    if not found_list or not found_sold:
        listed_events = []  # [(price, timestamp_ms)]
        sold_events = []    # [(price, timestamp_ms, date_string)]
        for m in re.finditer(r'\\?"eventDescription\\?":\s*\\?"(Listed|Sold[^\\"]*)\\?"', text):
            desc = m.group(1)
            chunk = text[max(0, m.start() - 600):min(len(text), m.end() + 600)]
            pm = re.search(r'\\?"price\\?":\s*(\d{5,})', chunk)
            dm = re.search(r'\\?"eventDate\\?":\s*(\d{10,})', chunk)
            ds = re.search(r'\\?"eventDateString\\?":\s*\\?"([^\\"]*)\\?"', chunk)
            if pm:
                price_val = int(pm.group(1))
                ts = int(dm.group(1)) if dm else 0
                ds_val = ds.group(1) if ds else None
                if desc == "Listed":
                    listed_events.append((price_val, ts))
                elif desc.startswith("Sold") and "Public Records" not in desc:
                    sold_events.append((price_val, ts, ds_val))

        # Validate: find most recent Listed+Sold pair within 4 months of each other
        four_months_ms = 4 * 30 * 24 * 3600 * 1000
        if listed_events and sold_events and (not found_list or not found_sold):
            best_listed = listed_events[0]   # First = most recent
            best_sold = sold_events[0]
            sold_ts = best_sold[1]
            list_ts = best_listed[1]
            # Sold must be after Listed, and within 4 months
            if sold_ts > 0 and list_ts > 0:
                if sold_ts >= list_ts and (sold_ts - list_ts) <= four_months_ms:
                    if not found_list:
                        listing["price"] = best_listed[0]
                        found_list = True
                    if not found_sold:
                        listing["soldPrice"] = best_sold[0]
                        found_sold = True
                    if best_sold[2]:
                        listing["soldDate"] = best_sold[2]
            elif sold_ts == 0 and list_ts == 0:
                # No timestamps available, use events as-is (first = most recent)
                if not found_list:
                    listing["price"] = best_listed[0]
                    found_list = True
                if not found_sold:
                    listing["soldPrice"] = best_sold[0]
                    found_sold = True
                if best_sold[2]:
                    listing["soldDate"] = best_sold[2]
        elif listed_events and not found_list:
            listing["price"] = listed_events[0][0]
            found_list = True


_enrich_sem = asyncio.Semaphore(8)


async def enrich_listing(listing: dict) -> dict:
    """Fetch individual listing page to extract prices, remodel info, lot size, etc."""
    url = listing.get("url", "")
    if not url or url == "https://www.redfin.com":
        return listing
    try:
        async with _enrich_sem:
            r = await http.get(url, headers=REDFIN_HEADERS, timeout=12)
        if r.status_code != 200:
            return listing
        text = r.text

        # Price extraction for sold listings
        if listing.get("listingStatus") == "recently_sold":
            _extract_prices_from_page(listing, text)

        # Lot size from page
        lot_match = re.search(r'Lot Size[:\s]*([0-9,]+)\s*(?:sq\.?\s*ft|sqft|SF)', text, re.IGNORECASE)
        if lot_match and not listing.get("lotSqft"):
            listing["lotSqft"] = int(lot_match.group(1).replace(",", ""))
        lot_acre = re.search(r'Lot Size[:\s]*([\d.]+)\s*(?:acre|ac)', text, re.IGNORECASE)
        if lot_acre and not listing.get("lotSqft"):
            listing["lotSqft"] = int(float(lot_acre.group(1)) * 43560)

        # Year built
        yr_match = re.search(r'Year Built[:\s]*(\d{4})', text, re.IGNORECASE)
        if yr_match and not listing.get("yearBuilt"):
            listing["yearBuilt"] = int(yr_match.group(1))

        desc_lower = text.lower()

        # Remodel detection
        if any(kw in desc_lower for kw in REMODEL_KW):
            listing["remodeled"] = True
            yr_remodel = re.search(r'(?:remodel|renovate|update)(?:ed|d)?\s+(?:in\s+)?(\d{4})', desc_lower)
            if yr_remodel:
                listing["remodelYear"] = int(yr_remodel.group(1))

        # Convertible rooms
        if any(kw in desc_lower for kw in CONVERT_KW):
            listing["convertibleRooms"] = True

        # Expandability
        if any(kw in desc_lower for kw in EXPAND_KW):
            listing["expandable"] = True

        # Description snippet
        desc_match = re.search(r'"text"\s*:\s*"([^"]{50,500})"', text)
        if desc_match:
            listing["notes"] = desc_match.group(1)[:300].replace("\\n", " ").strip()

    except Exception as e:
        logger.debug(f"enrich_listing error for {url}: {e}")
    return listing


def compute_score(listing: dict, criteria: SearchCriteria) -> int:
    """100-point scoring algorithm matching buyahouse logic."""
    s = 0
    m = 0

    # Price: 20 pts
    m += 20
    if criteria.minPrice <= listing.get("price", 0) <= criteria.maxPrice:
        s += 20

    # Bedrooms: 20 pts
    m += 20
    beds = listing.get("bedrooms", 0)
    if beds >= criteria.bedroomsIdeal:
        s += 20
    elif beds >= criteria.minBeds and (listing.get("convertibleRooms") or listing.get("expandable")):
        s += 14
    elif beds >= criteria.minBeds:
        s += 8

    # Sqft: 20 pts
    m += 20
    sqft = listing.get("sqft", 0)
    if sqft >= criteria.sqftPreferred:
        s += 20
    elif sqft >= criteria.minSqft:
        s += 12
    elif sqft >= 1500:
        s += 5

    # Lot size: 20 pts
    m += 20
    lot = listing.get("lotSqft", 0)
    if lot >= criteria.lotSqftMin:
        s += 15
        if lot >= 7000:
            s += 5
        else:
            s += min(5, round(((lot - criteria.lotSqftMin) / 1500) * 5))
    elif lot >= 4500:
        s += 6

    # Remodel: 15 pts
    m += 15
    if listing.get("remodeled"):
        s += 15
    elif listing.get("price", 0) <= 2_400_000:
        s += 5

    # Convertible/Expandable: 5 pts
    m += 5
    if listing.get("convertibleRooms"):
        s += 3
    if listing.get("expandable"):
        s += 2

    return min(100, round((s / m) * 100)) if m > 0 else 0


async def scrape_open_houses(listing_url: str) -> list[dict]:
    """Scrape open house schedule from a Redfin listing page."""
    if not listing_url:
        return []
    try:
        r = await http.get(listing_url, headers=REDFIN_HEADERS, timeout=10)
        if r.status_code != 200:
            return []
        text = r.text
        events = []
        # Look for open house JSON in page
        oh_matches = re.findall(
            r'"openHouse(?:Event)?"\s*:\s*\{[^}]*"date"\s*:\s*"([^"]+)"[^}]*"startTime"\s*:\s*"([^"]+)"[^}]*"endTime"\s*:\s*"([^"]+)"',
            text
        )
        for date_str, start, end in oh_matches:
            events.append({"date": date_str, "startTime": start, "endTime": end})

        # Fallback: look for common open house text patterns
        if not events:
            oh_text = re.findall(
                r'Open\s+(?:House|house)[:\s]*(?:Sat|Sun|Mon|Tue|Wed|Thu|Fri)\w*[,.]?\s*(\w+\s+\d+)[,.]?\s*(\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm))\s*(?:to|-)\s*(\d{1,2}(?::\d{2})?\s*(?:AM|PM|am|pm))',
                text
            )
            for date_part, start, end in oh_text:
                events.append({"date": date_part, "startTime": start, "endTime": end})

        return events
    except Exception:
        return []


# ─── REDFIN LISTING ENDPOINTS ────────────────────────────────────────────────

# City discovery cache: {rounded_lat_lng: (timestamp, result)}
_discover_cache: dict[str, tuple[float, list]] = {}
DISCOVER_CACHE_TTL = 1800  # 30 min


class DiscoverRequest(BaseModel):
    latitude: float
    longitude: float
    radiusMiles: int = 50


class AddressSearchRequest(BaseModel):
    address: str
    criteria: Optional[SearchCriteria] = None


@app.post("/cities/discover")
async def discover_cities(req: DiscoverRequest):
    """Discover cities with listings near a GPS coordinate using Redfin CSV endpoint."""
    rounded_key = f"{round(req.latitude, 2)},{round(req.longitude, 2)},{req.radiusMiles}"
    now = time.time()
    if rounded_key in _discover_cache:
        cached_time, cached_result = _discover_cache[rounded_key]
        if now - cached_time < DISCOVER_CACHE_TTL:
            return {"cities": cached_result, "cached": True}

    poly = lat_lng_to_poly(req.latitude, req.longitude, req.radiusMiles)
    # Use minimal criteria for discovery
    disc_criteria = SearchCriteria(
        minPrice=0, maxPrice=999_999_999, minBeds=0, minSqft=0,
        numPerCity=350, listingStatus="for_sale",
    )
    params = {
        "al": 1,
        "num_homes": 350,
        "ord": "days-on-redfin-asc",
        "page_number": 1,
        "poly": poly,
        "sf": "1,2,3,5,6,7",
        "status": 9,
        "uipt": 1,
        "v": 8,
    }
    try:
        r = await http.get(
            "https://www.redfin.com/stingray/api/gis-csv",
            params=params,
            headers=REDFIN_HEADERS,
            timeout=30,
        )
        if r.status_code != 200:
            raise HTTPException(502, f"Redfin returned {r.status_code}")
        reader = csv.DictReader(io.StringIO(r.text))
        city_counts: dict[str, int] = {}
        for row in reader:
            city = row.get("CITY", "").strip()
            if city:
                city_counts[city] = city_counts.get(city, 0) + 1
        result = sorted(
            [{"name": c, "count": n} for c, n in city_counts.items()],
            key=lambda x: x["count"],
            reverse=True,
        )
        _discover_cache[rounded_key] = (now, result)
        # Expire old entries
        expired = [k for k, (t, _) in _discover_cache.items() if now - t > DISCOVER_CACHE_TTL]
        for k in expired:
            del _discover_cache[k]
        return {"cities": result, "cached": False}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"discover_cities error: {e}")
        raise HTTPException(500, str(e))


@app.post("/listings/search-address")
async def search_by_address(req: AddressSearchRequest):
    """Search for a specific property by address using geocoding + tiny poly search."""
    gkey = get_google_key()
    loc = await geocode(req.address, gkey)
    if not loc:
        raise HTTPException(404, f"Could not geocode address: {req.address}")
    # Tiny poly (~0.3 mi) around the address
    poly = lat_lng_to_poly(loc["lat"], loc["lng"], 0.3)
    # Search all statuses
    criteria_active = SearchCriteria(
        minPrice=0, maxPrice=999_999_999, minBeds=0, minSqft=0,
        numPerCity=50, listingStatus="for_sale",
    )
    criteria_sold = SearchCriteria(
        minPrice=0, maxPrice=999_999_999, minBeds=0, minSqft=0,
        numPerCity=50, listingStatus="recently_sold", soldWithinDays=730,
    )
    criteria_pending = SearchCriteria(
        minPrice=0, maxPrice=999_999_999, minBeds=0, minSqft=0,
        numPerCity=50, listingStatus="pending",
    )
    results = await asyncio.gather(
        fetch_redfin_csv(criteria_active, poly=poly, status_override=9),
        fetch_redfin_csv(criteria_sold, poly=poly, status_override=130),
        fetch_redfin_csv(criteria_pending, poly=poly, status_override=2),
    )
    all_listings = []
    for batch in results:
        all_listings.extend(batch)

    # Fuzzy match by address
    query_parts = set(re.sub(r'[^a-z0-9\s]', '', req.address.lower()).split())
    matched = []
    for listing in all_listings:
        if not listing.get("address"):
            continue
        addr_parts = set(re.sub(r'[^a-z0-9\s]', '', listing["address"].lower()).split())
        overlap = len(query_parts & addr_parts)
        if overlap >= min(2, len(query_parts)):
            matched.append((overlap, listing))
    matched.sort(key=lambda x: x[0], reverse=True)
    final = [m[1] for m in matched]

    # Deduplicate by address
    seen_addrs = set()
    deduped = []
    scoring_criteria = req.criteria or SearchCriteria()
    for l in final:
        key = l["address"].lower().strip()
        if key not in seen_addrs:
            seen_addrs.add(key)
            l["score"] = compute_score(l, scoring_criteria)
            l["id"] = len(deduped) + 1
            l["addedDate"] = datetime.now().strftime("%Y-%m-%d")
            deduped.append(l)
    if not deduped:
        # Return all nearby even without fuzzy match
        for i, l in enumerate(all_listings[:20]):
            l["id"] = i + 1
            l["score"] = compute_score(l, scoring_criteria)
            l["addedDate"] = datetime.now().strftime("%Y-%m-%d")
        deduped = all_listings[:20]

    # Enrich sold listings to get correct list prices
    sold = [l for l in deduped if l.get("listingStatus") == "recently_sold"]
    if sold:
        await asyncio.gather(*[enrich_listing(l) for l in sold])

    return {"listings": deduped, "count": len(deduped), "geocoded": loc}


@app.get("/address/autocomplete")
async def address_autocomplete(q: str = ""):
    """Autocomplete addresses using Nominatim (free, no API key)."""
    q = q.strip()
    if len(q) < 5:
        return {"suggestions": []}
    try:
        r = await http.get(
            "https://nominatim.openstreetmap.org/search",
            params={
                "q": q,
                "format": "json",
                "limit": 5,
                "countrycodes": "us",
                "addressdetails": 1,
            },
            headers={"User-Agent": "OpenHouseApp/1.0"},
        )
        results = r.json()
        suggestions = []
        for item in results:
            display = item.get("display_name", "")
            # Shorten: take first 3 parts (street, city, county or state)
            parts = [p.strip() for p in display.split(",")]
            short = ", ".join(parts[:3]) if len(parts) >= 3 else display
            suggestions.append({
                "display": short,
                "full": display,
                "lat": float(item["lat"]),
                "lng": float(item["lon"]),
            })
        return {"suggestions": suggestions}
    except Exception:
        return {"suggestions": []}


def _parse_statuses(listing_status: str) -> list[str]:
    """Parse comma-separated status string into list."""
    return [s.strip() for s in listing_status.split(",") if s.strip()]


async def _fetch_for_status(
    criteria: SearchCriteria, status: str, known_cities: list[str],
    unknown_cities: list[str], has_location: bool,
) -> list[dict]:
    """Fetch listings for a single status, handling CSV vs JSON routing."""
    use_csv = status in ("recently_sold", "pending")
    status_map = {"for_sale": 9, "recently_sold": 130, "pending": 2}
    # Create a single-status copy of criteria for the fetch functions
    single = criteria.model_copy()
    single.listingStatus = status
    results = []

    if known_cities:
        if use_csv:
            tasks = [
                fetch_redfin_csv(single, region_id=REDFIN_CITIES[c]["region_id"], city_name=c)
                for c in known_cities
            ]
        else:
            tasks = [fetch_redfin_api(c, REDFIN_CITIES[c], single) for c in known_cities]
        city_results = await asyncio.gather(*tasks)
        for batch in city_results:
            results.extend(batch)

    if (unknown_cities or (not known_cities)) and has_location:
        poly = lat_lng_to_poly(single.latitude, single.longitude, single.radiusMiles)
        if use_csv:
            poly_results = await fetch_redfin_csv(single, poly=poly)
        else:
            poly_results = await fetch_redfin_api("", {}, single, poly=poly)
        if unknown_cities:
            poly_results = [l for l in poly_results if l.get("city", "").strip() in unknown_cities]
        results.extend(poly_results)

    return results


@app.post("/listings/search")
async def search_listings(criteria: SearchCriteria):
    """
    Search Redfin for listings matching criteria.
    Supports comma-separated listingStatus (e.g. "recently_sold,pending").
    Uses CSV endpoint for sold/pending, JSON for active.
    """
    cache_key = json.dumps(criteria.model_dump(), sort_keys=True)
    now = time.time()
    if cache_key in _listings_cache:
        cached_time, cached_results = _listings_cache[cache_key]
        if now - cached_time < CACHE_TTL:
            return {"listings": cached_results, "cached": True, "count": len(cached_results)}

    statuses = _parse_statuses(criteria.listingStatus)
    known_cities = [c for c in criteria.cities if c in REDFIN_CITIES]
    unknown_cities = [c for c in criteria.cities if c not in REDFIN_CITIES]
    has_location = criteria.latitude is not None and criteria.longitude is not None

    if not known_cities and not has_location:
        if unknown_cities:
            logger.warning(f"Unknown cities without lat/lng: {unknown_cities}")

    # Fetch all statuses concurrently
    status_tasks = [
        _fetch_for_status(criteria, s, known_cities, unknown_cities, has_location)
        for s in statuses
    ]
    status_results = await asyncio.gather(*status_tasks)
    all_listings = []
    for batch in status_results:
        all_listings.extend(batch)

    # Enrich sold listings to get correct list prices from individual pages
    sold = [l for l in all_listings if l.get("listingStatus") == "recently_sold"]
    if sold:
        await asyncio.gather(*[enrich_listing(l) for l in sold])

    # Score, sort, assign IDs
    for i, listing in enumerate(all_listings):
        listing["id"] = i + 1
        listing["score"] = compute_score(listing, criteria)
        listing["addedDate"] = datetime.now().strftime("%Y-%m-%d")

    all_listings.sort(key=lambda l: l["daysOnMarket"])

    # Cache
    _listings_cache[cache_key] = (now, all_listings)
    expired = [k for k, (t, _) in _listings_cache.items() if now - t > CACHE_TTL]
    for k in expired:
        del _listings_cache[k]

    return {"listings": all_listings, "cached": False, "count": len(all_listings)}


@app.post("/listings/search/{city}")
async def search_city(city: str, criteria: SearchCriteria):
    """Search a single city. Supports multi-status."""
    statuses = _parse_statuses(criteria.listingStatus)
    has_location = criteria.latitude is not None and criteria.longitude is not None

    known = [city] if city in REDFIN_CITIES else []
    unknown = [city] if city not in REDFIN_CITIES else []

    if not known and not has_location:
        raise HTTPException(400, f"Unknown city '{city}' and no lat/lng provided for poly search")

    status_tasks = [
        _fetch_for_status(criteria, s, known, unknown, has_location)
        for s in statuses
    ]
    status_results = await asyncio.gather(*status_tasks)
    listings = []
    for batch in status_results:
        listings.extend(batch)

    # Enrich sold listings to get correct list prices
    sold = [l for l in listings if l.get("listingStatus") == "recently_sold"]
    if sold:
        await asyncio.gather(*[enrich_listing(l) for l in sold])

    for i, listing in enumerate(listings):
        listing["id"] = i + 1
        listing["score"] = compute_score(listing, criteria)
        listing["addedDate"] = datetime.now().strftime("%Y-%m-%d")

    listings.sort(key=lambda l: l["daysOnMarket"])
    return {"city": city, "listings": listings, "count": len(listings)}


@app.get("/listings/open-houses")
async def get_open_houses(url: str):
    """Scrape open house schedule from individual Redfin listing page."""
    if not url.startswith("https://www.redfin.com/"):
        raise HTTPException(400, "URL must be a Redfin listing URL")
    events = await scrape_open_houses(url)
    return {"events": events, "url": url}


@app.post("/listings/check-sold")
async def check_if_sold(request: dict):
    """Check if a Redfin listing has sold by fetching its page.

    Uses the FIRST longerDefinitionToken on the page to detect the main listing's
    current status. The first token always belongs to the main listing, not comps.
    - "sold" = currently sold
    - "pending" = pending/contingent
    - "active" = still for sale
    """
    url = request.get("url", "")
    if not url.startswith("https://www.redfin.com/"):
        raise HTTPException(400, "Invalid Redfin URL")
    try:
        r = await http.get(url, headers=REDFIN_HEADERS, timeout=10)
        if r.status_code != 200:
            return {"sold": False, "soldPrice": None, "soldDate": None, "listPrice": None, "status": "unknown"}
        text = r.text

        # Detect current status from the FIRST longerDefinitionToken (main listing)
        # Format in HTML: longerDefinitionToken\":\"sold\" (escaped quotes)
        status_match = re.search(r'longerDefinitionToken\\?"\\?:\s*\\?"(active|sold|pending|contingent)\\?"', text)
        page_status = status_match.group(1) if status_match else "unknown"

        if page_status == "sold":
            listing = {"listingStatus": "recently_sold", "price": 0, "soldPrice": None, "soldDate": None}
            _extract_prices_from_page(listing, text)
            return {
                "sold": True,
                "soldPrice": listing.get("soldPrice"),
                "soldDate": listing.get("soldDate"),
                "listPrice": listing.get("price") if listing.get("price", 0) > 0 else None,
                "status": "recently_sold",
                "url": url,
            }
        else:
            status = "pending" if page_status in ("pending", "contingent") else "for_sale"
            return {"sold": False, "soldPrice": None, "soldDate": None, "listPrice": None, "status": status, "url": url}
    except Exception as e:
        logger.error(f"check_if_sold error: {e}")
        return {"sold": False, "soldPrice": None, "soldDate": None, "listPrice": None, "status": "for_sale", "error": str(e)}


# ─── TESLA PROXY ──────────────────────────────────────────────────────────────

@app.get("/vehicles")
async def get_vehicles(authorization: str = Header(...),
                       x_refresh_token: Optional[str] = Header(None)):
    r, tokens = await tesla_request("GET", "/vehicles", authorization, x_refresh_token or "")
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    data = r.json()
    for v in data.get("response", []):
        logger.info(f"Vehicle '{v.get('display_name')}': option_codes={v.get('option_codes', 'MISSING')}, color={v.get('color', 'MISSING')}")
    resp = JSONResponse(content=data)
    add_token_headers(resp, tokens)
    return resp


@app.post("/vehicles/{vehicle_id}/wake")
async def wake_vehicle(vehicle_id: str, authorization: str = Header(...),
                       x_refresh_token: Optional[str] = Header(None)):
    """Wake vehicle and poll until online (up to ~30 seconds)."""
    # Auto-refresh token if needed
    r, tokens = await tesla_request("POST", f"/vehicles/{vehicle_id}/wake_up",
                                     authorization, x_refresh_token or "")
    auth = authorization
    if tokens:
        auth = f"Bearer {tokens['access_token']}"
    logger.info(f"Wake request for {vehicle_id}: status={r.status_code}")

    # If wake_up fails, try /wake endpoint
    if r.status_code != 200:
        r = await http.post(
            f"{TESLA_BASE}/vehicles/{vehicle_id}/wake",
            headers={"Authorization": auth},
        )
        logger.info(f"Wake fallback for {vehicle_id}: status={r.status_code}")

    try:
        data = r.json()
        state = data.get("response", {}).get("state", "unknown")
        logger.info(f"Wake initial state for {vehicle_id}: {state}")
    except Exception as e:
        logger.error(f"Wake parse error for {vehicle_id}: {e}, body={r.text[:200]}")
        data = {"response": {"state": "unknown"}}
        state = "unknown"

    # Poll until online (max 6 attempts, ~30 seconds total)
    for attempt in range(6):
        if state == "online":
            logger.info(f"Vehicle {vehicle_id} is online after {attempt} poll(s)")
            resp = JSONResponse(content=data)
            add_token_headers(resp, tokens)
            return resp
        await asyncio.sleep(5)
        try:
            check = await http.get(
                f"{TESLA_BASE}/vehicles/{vehicle_id}",
                headers={"Authorization": auth},
            )
            if check.status_code == 200:
                check_data = check.json()
                state = check_data.get("response", {}).get("state", "unknown")
                logger.info(f"Wake poll {attempt+1} for {vehicle_id}: state={state}")
                if state == "online":
                    resp = JSONResponse(content=check_data)
                    add_token_headers(resp, tokens)
                    return resp
        except Exception as e:
            logger.error(f"Wake poll error for {vehicle_id}: {e}")

    logger.warning(f"Vehicle {vehicle_id} did not come online after polling")
    resp = JSONResponse(content=data)
    add_token_headers(resp, tokens)
    return resp


@app.post("/vehicles/{vehicle_id}/navigate")
async def send_navigation(vehicle_id: str, body: NavigateRequest,
                          authorization: str = Header(...),
                          x_refresh_token: Optional[str] = Header(None)):
    if not body.stops:
        raise HTTPException(400, "No stops provided")

    # Build Google Maps multi-stop URL using /dir/ format
    if len(body.stops) == 1:
        maps_url = f"https://maps.google.com/maps?daddr={urllib.parse.quote(body.stops[0])}"
    else:
        parts = "/".join(urllib.parse.quote(s) for s in body.stops)
        maps_url = f"https://www.google.com/maps/dir/{parts}"

    payload = {
        "type": "share_ext_content_raw",
        "locale": "en-US",
        "timestamp_ms": str(time.time_ns() // 1_000_000),
        "value": {
            "android.intent.extra.TEXT": maps_url,
        },
    }

    logger.info(f"Sending nav to vehicle {vehicle_id}: {maps_url}")

    r, tokens = await tesla_request(
        "POST", f"/vehicles/{vehicle_id}/command/navigation_request",
        authorization, x_refresh_token or "",
        json=payload, headers={"Content-Type": "application/json"},
    )

    if r.status_code != 200:
        logger.error(f"Tesla nav response {r.status_code}: {r.text[:500]}")
        raise HTTPException(r.status_code, r.text)

    try:
        data = r.json()
    except Exception:
        raise HTTPException(502, "Tesla returned non-JSON response")

    if not data.get("response", {}).get("result"):
        reason = data.get("response", {}).get("reason", "Unknown")
        raise HTTPException(400, f"Tesla rejected command: {reason}")

    resp = JSONResponse(content={"ok": True, "stops_sent": len(body.stops)})
    add_token_headers(resp, tokens)
    return resp


# ─── VEHICLE DATA + COMMANDS ──────────────────────────────────────────────

@app.get("/vehicles/{vehicle_id}/vehicle_data")
async def get_vehicle_data(vehicle_id: str, authorization: str = Header(...),
                           x_refresh_token: Optional[str] = Header(None)):
    """Proxy Tesla vehicle_data → flattened battery/climate/sentry status."""
    try:
        # Try Fleet API first, with auto-refresh
        r, tokens = await tesla_request("GET", f"/vehicles/{vehicle_id}/vehicle_data",
                                         authorization, x_refresh_token or "")
        auth = authorization
        if tokens:
            auth = f"Bearer {tokens['access_token']}"
        logger.info(f"vehicle_data for {vehicle_id}: status={r.status_code}")

        # If Fleet API returns 403 (virtual key not installed), try the data_request endpoint
        if r.status_code == 403:
            logger.info(f"Fleet API 403, trying data_request for {vehicle_id}")
            r2 = await http.get(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/data_request/charge_state",
                headers={"Authorization": auth},
            )
            r3 = await http.get(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/data_request/climate_state",
                headers={"Authorization": auth},
            )
            r4 = await http.get(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/data_request/vehicle_state",
                headers={"Authorization": auth},
            )
            logger.info(f"data_request statuses: charge={r2.status_code}, climate={r3.status_code}, vehicle={r4.status_code}")

            charge = r2.json().get("response", {}) if r2.status_code == 200 else {}
            climate = r3.json().get("response", {}) if r3.status_code == 200 else {}
            vehicle = r4.json().get("response", {}) if r4.status_code == 200 else {}

            # Try to get vehicle_config for exterior_color
            r5 = await http.get(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/data_request/vehicle_config",
                headers={"Authorization": auth},
            )
            config = r5.json().get("response", {}) if r5.status_code == 200 else {}
            logger.info(f"data_request vehicle_config for {vehicle_id}: status={r5.status_code}, color={config.get('exterior_color', 'N/A')}")

            result = {
                "battery_level": charge.get("battery_level", 0),
                "battery_range": charge.get("battery_range", 0),
                "is_climate_on": climate.get("is_climate_on", False),
                "interior_temp": climate.get("inside_temp"),
                "exterior_temp": climate.get("outside_temp"),
                "locked": vehicle.get("locked", True),
                "sentry_mode": vehicle.get("sentry_mode", False),
                "exterior_color": config.get("exterior_color"),
                "paint_color": config.get("paint_color"),
            }
            resp = JSONResponse(content=result)
            add_token_headers(resp, tokens)
            return resp

        if r.status_code != 200:
            logger.error(f"vehicle_data error body: {r.text[:500]}")
            raise HTTPException(r.status_code, r.text)

        data = r.json().get("response", {})
        if not data:
            raise HTTPException(404, "No vehicle data returned")

        charge = data.get("charge_state") or {}
        climate = data.get("climate_state") or {}
        vehicle = data.get("vehicle_state") or {}
        config = data.get("vehicle_config") or {}

        result = {
            "battery_level": charge.get("battery_level", 0),
            "battery_range": charge.get("battery_range", 0),
            "is_climate_on": climate.get("is_climate_on", False),
            "interior_temp": climate.get("inside_temp"),
            "exterior_temp": climate.get("outside_temp"),
            "locked": vehicle.get("locked", True),
            "sentry_mode": vehicle.get("sentry_mode", False),
            "exterior_color": config.get("exterior_color"),
            "paint_color": config.get("paint_color"),
        }
        resp = JSONResponse(content=result)
        add_token_headers(resp, tokens)
        return resp
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"vehicle_data error for {vehicle_id}: {e}")
        raise HTTPException(502, f"Failed to get vehicle data: {e}")


@app.post("/vehicles/{vehicle_id}/command/climate")
async def set_climate(vehicle_id: str, body: ClimateRequest,
                      authorization: str = Header(...),
                      x_refresh_token: Optional[str] = Header(None)):
    """Start/stop climate and optionally set temperature."""
    # Auto-refresh token if needed via a simple test call
    auth = authorization
    if x_refresh_token:
        # Quick check if token is valid
        test_r, tokens = await tesla_request("GET", "/vehicles", authorization, x_refresh_token)
        if tokens:
            auth = f"Bearer {tokens['access_token']}"

    headers = {"Authorization": auth, "Content-Type": "application/json"}
    logger.info(f"Climate command for {vehicle_id}: on={body.on}, temp_c={body.temp_c}")

    if body.on:
        if body.temp_c is not None:
            tr = await http.post(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/command/set_temps",
                json={"driver_temp": body.temp_c, "passenger_temp": body.temp_c},
                headers=headers,
            )
            logger.info(f"set_temps response: {tr.status_code} {tr.text[:200]}")
        r = await http.post(
            f"{TESLA_BASE}/vehicles/{vehicle_id}/command/auto_conditioning_start",
            headers=headers,
        )
    else:
        r = await http.post(
            f"{TESLA_BASE}/vehicles/{vehicle_id}/command/auto_conditioning_stop",
            headers=headers,
        )

    logger.info(f"Climate response: {r.status_code} {r.text[:500]}")
    if r.status_code == 403:
        raise HTTPException(403, f"Tesla rejected climate command (403). The vehicle may need the app's virtual key installed. Details: {r.text[:300]}")
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    try:
        resp_data = r.json()
        resp = JSONResponse(content=resp_data)
        if x_refresh_token and 'tokens' in dir() and tokens:
            add_token_headers(resp, tokens)
        return resp
    except Exception:
        raise HTTPException(502, f"Tesla returned non-JSON: {r.text[:200]}")


@app.post("/route/optimize-order")
async def optimize_stop_order(
    body: OptimizeRequest,
    x_google_maps_key: Optional[str] = Header(None),
):
    """Nearest-neighbor TSP reorder for shortest total distance."""
    import math

    gkey = get_google_key(x_google_maps_key or "")
    stops = list(body.stops)

    if len(stops) <= 2:
        return {"stops": [s.model_dump() for s in stops]}

    # Geocode all stops that don't have coordinates
    async def ensure_coords(stop: RouteStop) -> RouteStop:
        if stop.latitude and stop.longitude:
            return stop
        geo = await geocode(stop.address, gkey)
        if geo:
            return stop.model_copy(update={"latitude": geo["lat"], "longitude": geo["lng"]})
        return stop

    stops = await asyncio.gather(*[ensure_coords(s) for s in stops])
    stops = list(stops)

    # Geocode origin if provided
    origin_coords = None
    if body.origin:
        origin_coords = await geocode(body.origin, gkey)

    def haversine(lat1, lon1, lat2, lon2):
        R = 6371000
        p1, p2, dp, dl = math.radians(lat1), math.radians(lat2), math.radians(lat2 - lat1), math.radians(lon2 - lon1)
        a = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
        return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

    # Nearest-neighbor from origin (or first stop)
    remaining = list(range(len(stops)))
    ordered = []

    if origin_coords:
        cur_lat, cur_lng = origin_coords["lat"], origin_coords["lng"]
    elif stops[0].latitude and stops[0].longitude:
        first = remaining.pop(0)
        ordered.append(first)
        cur_lat, cur_lng = stops[first].latitude, stops[first].longitude
    else:
        return {"stops": [s.model_dump() for s in stops]}

    while remaining:
        best_idx = None
        best_dist = float("inf")
        for idx in remaining:
            s = stops[idx]
            if s.latitude and s.longitude:
                d = haversine(cur_lat, cur_lng, s.latitude, s.longitude)
                if d < best_dist:
                    best_dist = d
                    best_idx = idx
        if best_idx is None:
            ordered.extend(remaining)
            break
        ordered.append(best_idx)
        remaining.remove(best_idx)
        cur_lat, cur_lng = stops[best_idx].latitude, stops[best_idx].longitude

    reordered = [stops[i] for i in ordered]
    return {"stops": [s.model_dump() for s in reordered]}


# ─── TESLA OAUTH ──────────────────────────────────────────────────────────────

@app.get("/tesla/auth")
async def tesla_auth():
    """Open this URL in your browser to start the Tesla OAuth flow."""
    if not TESLA_CLIENT_ID:
        raise HTTPException(400, "Set TESLA_CLIENT_ID in .env first")
    params = urllib.parse.urlencode({
        "client_id": TESLA_CLIENT_ID,
        "redirect_uri": TESLA_REDIRECT_URI,
        "response_type": "code",
        "scope": "openid offline_access vehicle_device_data vehicle_cmds",
        "state": "teslanav",
    })
    auth_url = f"{TESLA_AUTH_BASE}/authorize?{params}"
    from fastapi.responses import RedirectResponse
    return RedirectResponse(auth_url)


@app.get("/callback")
async def tesla_callback(code: str, state: str = ""):
    """Tesla redirects here after user authorizes. Exchanges code for access token."""
    if not TESLA_CLIENT_ID or not TESLA_CLIENT_SECRET:
        raise HTTPException(400, "Set TESLA_CLIENT_ID and TESLA_CLIENT_SECRET in .env")

    r = await http.post(
        f"{TESLA_AUTH_BASE}/token",
        data={
            "grant_type": "authorization_code",
            "client_id": TESLA_CLIENT_ID,
            "client_secret": TESLA_CLIENT_SECRET,
            "code": code,
            "redirect_uri": TESLA_REDIRECT_URI,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )

    if r.status_code != 200:
        raise HTTPException(r.status_code, f"Token exchange failed: {r.text}")

    tokens = r.json()
    logger.info(f"Token exchange keys: {list(tokens.keys())}")
    access_token = tokens.get("access_token", "")
    refresh_token = tokens.get("refresh_token", "")
    expires_in = tokens.get("expires_in", 0)
    logger.info(f"Got tokens: access={'yes' if access_token else 'no'}, refresh={'yes' if refresh_token else 'no'}, expires_in={expires_in}")

    from fastapi.responses import HTMLResponse
    return HTMLResponse(f"""
    <html>
    <body style="background:#000;color:#fff;font-family:monospace;padding:40px;">
    <h2 style="color:#FFD200;">Tesla Authorization Successful</h2>
    <p>Copy <b>both</b> tokens into the TeslaNav app Settings:</p>
    <p style="color:#0f0;">Access Token:</p>
    <textarea style="width:100%;height:80px;background:#111;color:#0f0;border:1px solid #333;
    font-family:monospace;padding:10px;font-size:13px;" readonly onclick="this.select()">{access_token}</textarea>
    <p style="color:#888;">Expires in {expires_in // 3600} hours — auto-refreshes if you set the refresh token below.</p>
    <p style="color:#FFD200;">Refresh Token (required for auto-refresh):</p>
    <textarea style="width:100%;height:80px;background:#111;color:#FFD200;border:1px solid #555;
    font-family:monospace;padding:10px;font-size:13px;" readonly onclick="this.select()">{refresh_token}</textarea>
    <p style="color:#888;">Paste this into "Tesla refresh token" in Settings. The app will automatically refresh your access token — no more manual sign-ins.</p>
    </body></html>
    """)


@app.get("/.well-known/appspecific/com.tesla.3p.public-key.pem")
async def tesla_public_key():
    from fastapi.responses import FileResponse
    key_path = os.path.join(os.path.dirname(__file__), ".well-known", "appspecific", "com.tesla.3p.public-key.pem")
    return FileResponse(key_path, media_type="application/x-pem-file")


@app.get("/health")
async def health():
    return {"status": "ok", "google_maps": bool(GOOGLE_KEY_ENV), "tesla_oauth": bool(TESLA_CLIENT_ID)}


@app.on_event("shutdown")
async def shutdown():
    await http.aclose()
