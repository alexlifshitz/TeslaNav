"""
Tesla Nav Backend
FastAPI proxy: Tesla Fleet API + Google Maps route resolution & optimization

Install: pip install fastapi uvicorn httpx python-dotenv
Run:     uvicorn main:app --reload --port 8000
"""

import os, re, json, time, asyncio, urllib.parse
from typing import Optional
from datetime import datetime
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
    minSqft: int = 1750
    bedroomsIdeal: int = 4
    sqftPreferred: int = 2000
    lotSqftMin: int = 5500
    remodelPreference: str = "any"  # "must", "prefer", "any", "open_to_renovating"


# ─── GOOGLE MAPS HELPERS ─────────────────────────────────────────────────────

async def geocode(address: str, gkey: str) -> Optional[dict]:
    """Geocode an address → {lat, lng}."""
    if not gkey:
        return None
    r = await http.get(
        "https://maps.googleapis.com/maps/api/geocode/json",
        params={"address": address, "key": gkey},
    )
    data = r.json()
    if data["status"] == "OK" and data["results"]:
        return data["results"][0]["geometry"]["location"]
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

async def fetch_redfin_api(city_name: str, city_info: dict, criteria: SearchCriteria) -> list[dict]:
    """Fetch listings from Redfin stingray GIS API for a single city."""
    params = {
        "al": 1,
        "market": "sanfrancisco",
        "num_homes": 100,
        "ord": "redfin-recommended-asc",
        "page_number": 1,
        "region_id": city_info["region_id"],
        "region_type": 6,
        "sf": "1,2,3,5,6,7",
        "status": 9,
        "uipt": 1,
        "v": 8,
        "min_price": criteria.minPrice,
        "max_price": criteria.maxPrice,
        "num_beds": criteria.minBeds,
        "min_sqft": criteria.minSqft,
    }
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
            hd = h.get("homeData", {})
            addr_info = hd.get("addressInfo", {})
            price_info = h.get("priceInfo", {})
            sqft_info = hd.get("sqFt", {})
            lot_info = hd.get("lotSize", {})

            price = price_info.get("amount", 0) if isinstance(price_info, dict) else 0
            if not price:
                price = hd.get("priceInfo", {}).get("amount", 0)

            image_url = ""
            photos = hd.get("photos")
            if isinstance(photos, dict):
                photo_list = photos.get("photos", [])
                if photo_list and isinstance(photo_list, list):
                    first = photo_list[0] if photo_list else {}
                    if isinstance(first, dict):
                        urls = first.get("photoUrls", {})
                        if isinstance(urls, dict):
                            image_url = urls.get("fullScreenPhotoUrl", urls.get("nonFullScreenPhotoUrl", ""))
            if not image_url:
                image_url = hd.get("staticMapUrl", "")

            listing = {
                "address": addr_info.get("streetAddress", "Unknown"),
                "city": city_name,
                "price": price,
                "bedrooms": hd.get("beds") or 0,
                "bathrooms": hd.get("baths") or 0,
                "sqft": sqft_info.get("value", 0) if isinstance(sqft_info, dict) else (sqft_info or 0),
                "lotSqft": lot_info.get("value", 0) if isinstance(lot_info, dict) else (lot_info or 0),
                "yearBuilt": hd.get("yearBuilt"),
                "url": "https://www.redfin.com" + hd.get("url", ""),
                "imageUrl": image_url,
                "mlsId": hd.get("mlsId", {}).get("value", "") if isinstance(hd.get("mlsId"), dict) else "",
                "remodeled": False,
                "remodelYear": None,
                "convertibleRooms": False,
                "expandable": False,
                "notes": "",
            }
            listings.append(listing)
        return listings
    except Exception:
        return []


async def enrich_listing(listing: dict) -> dict:
    """Fetch individual listing page to detect remodel, convertible rooms, lot size, etc."""
    url = listing.get("url", "")
    if not url or url == "https://www.redfin.com":
        return listing
    try:
        r = await http.get(url, headers=REDFIN_HEADERS, timeout=10)
        if r.status_code != 200:
            return listing
        text = r.text

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

    except Exception:
        pass
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

@app.post("/listings/search")
async def search_listings(criteria: SearchCriteria):
    """
    Search Redfin for listings matching criteria. Returns scored + enriched listings.
    Results cached for 1 hour per unique criteria set.
    """
    # Build cache key from criteria
    cache_key = json.dumps(criteria.model_dump(), sort_keys=True)
    now = time.time()
    if cache_key in _listings_cache:
        cached_time, cached_results = _listings_cache[cache_key]
        if now - cached_time < CACHE_TTL:
            return {"listings": cached_results, "cached": True, "count": len(cached_results)}

    # Validate cities
    valid_cities = [c for c in criteria.cities if c in REDFIN_CITIES]
    if not valid_cities:
        raise HTTPException(400, f"No valid cities. Available: {list(REDFIN_CITIES.keys())}")

    # Fetch from all cities concurrently
    tasks = [
        fetch_redfin_api(city, REDFIN_CITIES[city], criteria)
        for city in valid_cities
    ]
    city_results = await asyncio.gather(*tasks)
    all_listings = []
    for listings in city_results:
        all_listings.extend(listings)

    # Enrich listings concurrently (batched to avoid hammering Redfin)
    enriched = []
    batch_size = 5
    for i in range(0, len(all_listings), batch_size):
        batch = all_listings[i:i + batch_size]
        results = await asyncio.gather(*[enrich_listing(l) for l in batch])
        enriched.extend(results)
        if i + batch_size < len(all_listings):
            await asyncio.sleep(0.5)

    # Score and sort
    for i, listing in enumerate(enriched):
        listing["id"] = i + 1
        listing["score"] = compute_score(listing, criteria)
        listing["addedDate"] = datetime.now().strftime("%Y-%m-%d")

    enriched.sort(key=lambda l: l["score"], reverse=True)

    # Cache results
    _listings_cache[cache_key] = (now, enriched)

    # Clean old cache entries
    expired = [k for k, (t, _) in _listings_cache.items() if now - t > CACHE_TTL]
    for k in expired:
        del _listings_cache[k]

    return {"listings": enriched, "cached": False, "count": len(enriched)}


@app.get("/listings/open-houses")
async def get_open_houses(url: str):
    """Scrape open house schedule from individual Redfin listing page."""
    if not url.startswith("https://www.redfin.com/"):
        raise HTTPException(400, "URL must be a Redfin listing URL")
    events = await scrape_open_houses(url)
    return {"events": events, "url": url}


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


# ─── VEHICLE DATA + COMMANDS ──────────────────────────────────────────────

@app.get("/vehicles/{vehicle_id}/vehicle_data")
async def get_vehicle_data(vehicle_id: str, authorization: str = Header(...)):
    """Proxy Tesla vehicle_data → flattened battery/climate/sentry status."""
    r = await http.get(
        f"{TESLA_BASE}/vehicles/{vehicle_id}/vehicle_data",
        headers={"Authorization": authorization},
        params={"endpoints": "charge_state;climate_state;vehicle_state;location_data"},
    )
    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)

    data = r.json().get("response", {})
    charge = data.get("charge_state", {})
    climate = data.get("climate_state", {})
    vehicle = data.get("vehicle_state", {})

    return {
        "battery_level": charge.get("battery_level", 0),
        "battery_range": charge.get("battery_range", 0),
        "is_climate_on": climate.get("is_climate_on", False),
        "interior_temp": climate.get("inside_temp"),
        "exterior_temp": climate.get("outside_temp"),
        "locked": vehicle.get("locked", True),
        "sentry_mode": vehicle.get("sentry_mode", False),
    }


@app.post("/vehicles/{vehicle_id}/command/climate")
async def set_climate(vehicle_id: str, body: ClimateRequest,
                      authorization: str = Header(...)):
    """Start/stop climate and optionally set temperature."""
    headers = {"Authorization": authorization, "Content-Type": "application/json"}

    if body.on:
        # Set temperature first if provided
        if body.temp_c is not None:
            await http.post(
                f"{TESLA_BASE}/vehicles/{vehicle_id}/command/set_temps",
                json={"driver_temp": body.temp_c, "passenger_temp": body.temp_c},
                headers=headers,
            )
        r = await http.post(
            f"{TESLA_BASE}/vehicles/{vehicle_id}/command/auto_conditioning_start",
            headers=headers,
        )
    else:
        r = await http.post(
            f"{TESLA_BASE}/vehicles/{vehicle_id}/command/auto_conditioning_stop",
            headers=headers,
        )

    if r.status_code != 200:
        raise HTTPException(r.status_code, r.text)
    return r.json()


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
        "scope": "openid vehicle_device_data vehicle_cmds",
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
    access_token = tokens.get("access_token", "")
    refresh_token = tokens.get("refresh_token", "")
    expires_in = tokens.get("expires_in", 0)

    from fastapi.responses import HTMLResponse
    return HTMLResponse(f"""
    <html>
    <body style="background:#000;color:#fff;font-family:monospace;padding:40px;">
    <h2 style="color:#FFD200;">Tesla Authorization Successful</h2>
    <p>Copy this access token and paste it into the TeslaNav app Settings:</p>
    <textarea style="width:100%;height:80px;background:#111;color:#0f0;border:1px solid #333;
    font-family:monospace;padding:10px;font-size:13px;" readonly onclick="this.select()">{access_token}</textarea>
    <p style="color:#888;">Token expires in {expires_in // 3600} hours.</p>
    <p style="color:#888;">Refresh token (save this for later):</p>
    <textarea style="width:100%;height:60px;background:#111;color:#888;border:1px solid #333;
    font-family:monospace;padding:10px;font-size:11px;" readonly onclick="this.select()">{refresh_token}</textarea>
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
