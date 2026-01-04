#!/usr/bin/env bash
set -euo pipefail

echo "== Step02: rewrite miniapp client UI =="

# 1) styles
cat > miniapp/styles.css <<'CSS'
:root{
  --bg: #ffffff;
  --fg: #111111;
  --muted: #6b7280;
  --line: rgba(0,0,0,.08);
  --card: rgba(255,255,255,.92);
  --shadow: 0 10px 30px rgba(0,0,0,.12);
  --btn: #111111;
  --btnfg: #ffffff;
  --danger: #ef4444;
  --ok: #16a34a;
  --radius: 16px;
}

html,body{height:100%;margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Arial}
#map{position:fixed;inset:0}
#topbar{
  position:fixed;left:10px;right:10px;top:10px;
  display:flex;gap:8px;align-items:center;justify-content:space-between;
  z-index:5;
  pointer-events:none;
}
.badge{
  pointer-events:auto;
  background: var(--card);
  border:1px solid var(--line);
  box-shadow: var(--shadow);
  color: var(--fg);
  padding:8px 10px;
  border-radius: 999px;
  font-size: 13px;
  backdrop-filter: blur(10px);
}
#sheet{
  position:fixed;left:10px;right:10px;bottom:10px;
  z-index:6;
  background: var(--card);
  border:1px solid var(--line);
  box-shadow: var(--shadow);
  border-radius: var(--radius);
  padding:12px;
  backdrop-filter: blur(10px);
}
.handle{
  width:42px;height:4px;border-radius:999px;
  background: rgba(0,0,0,.15);
  margin:0 auto 10px auto;
}
.row{display:flex;gap:8px;align-items:center}
.row + .row{margin-top:8px}
.col{flex:1}
label{display:block;font-size:12px;color:var(--muted);margin-bottom:6px}
.input{
  width:100%;
  box-sizing:border-box;
  padding:10px 10px;
  border-radius: 12px;
  border:1px solid var(--line);
  background: rgba(255,255,255,.9);
  outline:none;
  font-size:14px;
}
.input[readonly]{color:#111}
.btn{
  border:0;
  padding:10px 12px;
  border-radius: 12px;
  background: var(--btn);
  color: var(--btnfg);
  font-size:14px;
  cursor:pointer;
  white-space:nowrap;
}
.btn.secondary{
  background: rgba(0,0,0,.06);
  color: #111;
  border:1px solid var(--line);
}
.btn.danger{
  background: var(--danger);
  color:#fff;
}
.small{
  font-size:12px;color:var(--muted)
}

#results{
  position:relative;
}
#resultsList{
  position:absolute;left:0;right:0;top:6px;
  background: rgba(255,255,255,.98);
  border:1px solid var(--line);
  border-radius: 12px;
  box-shadow: var(--shadow);
  overflow:hidden;
  display:none;
  max-height: 220px;
  overflow:auto;
  z-index: 10;
}
.resItem{
  padding:10px 10px;
  border-bottom:1px solid var(--line);
  font-size:13px;
  cursor:pointer;
}
.resItem:last-child{border-bottom:0}
.resItem:hover{background: rgba(0,0,0,.04)}
.pill{
  display:inline-flex;gap:6px;align-items:center;
  padding:6px 10px;border-radius:999px;
  border:1px solid var(--line);
  background: rgba(255,255,255,.8);
  font-size:12px;color: var(--muted);
}
.dot{width:8px;height:8px;border-radius:999px;background:#111}
.dot.ok{background: var(--ok)}
.dot.warn{background: #f59e0b}
CSS

# 2) app.js
cat > miniapp/app.js <<'JS'
(function(){
  const tg = window.Telegram?.WebApp || null;
  const API_BASE  = (window.TAXI_API_BASE  || "").trim() || location.origin;
  const STYLE_URL = (window.TAXI_STYLE_URL || "").trim();

  // Theme from Telegram (best-effort)
  function applyTgTheme(){
    if (!tg || !tg.themeParams) return;
    const tp = tg.themeParams;
    const root = document.documentElement.style;

    const bg = tp.bg_color || "#ffffff";
    const fg = tp.text_color || "#111111";
    const hint = tp.hint_color || "#6b7280";
    const btn = tp.button_color || "#111111";
    const btnfg = tp.button_text_color || "#ffffff";

    root.setProperty("--bg", bg);
    root.setProperty("--fg", fg);
    root.setProperty("--muted", hint);
    root.setProperty("--btn", btn);
    root.setProperty("--btnfg", btnfg);
  }

  function $(id){ return document.getElementById(id); }

  const statusBadge = $("statusBadge");
  const driversBadge = $("driversBadge");

  const fromInput = $("fromInput");
  const toInput = $("toInput");
  const searchInput = $("searchInput");
  const resultsList = $("resultsList");
  const commentInput = $("commentInput");

  const btnPickFrom = $("btnPickFrom");
  const btnPickTo = $("btnPickTo");
  const btnMyPos = $("btnMyPos");
  const btnClear = $("btnClear");

  let pickMode = null; // "from" | "to" | null
  let fromPoint = null; // {lat,lon,address}
  let toPoint = null;   // {lat,lon,address}

  let fromMarker = null;
  let toMarker = null;

  let driverMarkers = [];

  function setStatus(text, kind){
    statusBadge.textContent = text;
    const dot = statusBadge.querySelector(".dot");
    if (dot){
      dot.classList.remove("ok","warn");
      if (kind === "ok") dot.classList.add("ok");
      else if (kind === "warn") dot.classList.add("warn");
    }
  }

  function setDriversCount(n){
    driversBadge.innerHTML = `<span class="dot ${n>0?'ok':'warn'}"></span> Машины рядом: <b>${n}</b>`;
  }

  function showResults(items){
    resultsList.innerHTML = "";
    if (!items || !items.length){
      resultsList.style.display = "none";
      return;
    }
    for (const it of items){
      const div = document.createElement("div");
      div.className = "resItem";
      div.textContent = it.display_name || "";
      div.addEventListener("click", ()=>{
        resultsList.style.display = "none";
        const lat = parseFloat(it.lat);
        const lon = parseFloat(it.lon);
        const addr = it.display_name || `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
        map.flyTo({center:[lon,lat], zoom: 15});
        pickPoint({lat, lon}, addr);
      });
      resultsList.appendChild(div);
    }
    resultsList.style.display = "block";
  }

  async function apiGet(path, params){
    const u = new URL(API_BASE + path);
    for (const [k,v] of Object.entries(params||{})){
      if (v === undefined || v === null) continue;
      u.searchParams.set(k, String(v));
    }
    const r = await fetch(u.toString(), {credentials:"omit"});
    if (!r.ok) throw new Error(await r.text());
    return await r.json();
  }

  async function reverse(lat, lon){
    return await apiGet("/api/geo/reverse", {lat, lon});
  }

  async function search(q){
    return await apiGet("/api/geo/search", {q, limit: 6});
  }

  async function driversNearby(lat, lon){
    return await apiGet("/api/drivers/nearby", {lat, lon});
  }

  function updateInputs(){
    fromInput.value = fromPoint?.address || "";
    toInput.value = toPoint?.address || "";
    updateMainButton();
  }

  function updateMainButton(){
    if (!tg) return;
    if (fromPoint && toPoint){
      tg.MainButton.setText("🚕 Заказать");
      tg.MainButton.show();
      tg.MainButton.enable();
    } else {
      tg.MainButton.hide();
    }
  }

  async function pickPoint(lngLatObj, address){
    const lat = lngLatObj.lat;
    const lon = lngLatObj.lon ?? lngLatObj.lng ?? lngLatObj.lngLat?.lng ?? lngLatObj.lng ?? null;

    // normalize
    const L = (typeof lngLatObj.lng === "number") ? lngLatObj.lng : (typeof lngLatObj.lon === "number" ? lngLatObj.lon : null);
    const fixed = {lat: lat, lon: L};

    // if no mode selected -> set missing one
    if (!pickMode){
      pickMode = fromPoint ? "to" : "from";
    }

    if (pickMode === "from"){
      fromPoint = {lat: fixed.lat, lon: fixed.lon, address};
      if (fromMarker) fromMarker.remove();
      fromMarker = new maplibregl.Marker({color:"#16a34a"}).setLngLat([fixed.lon, fixed.lat]).addTo(map);
      setStatus("Выбрано: Откуда ✅. Теперь выбери «Куда»", "ok");
      pickMode = "to";
    } else {
      toPoint = {lat: fixed.lat, lon: fixed.lon, address};
      if (toMarker) toMarker.remove();
      toMarker = new maplibregl.Marker({color:"#111111"}).setLngLat([fixed.lon, fixed.lat]).addTo(map);
      setStatus("Выбрано: Куда ✅. Можно нажимать «Заказать»", "ok");
      pickMode = null;
    }

    updateInputs();
    // refresh drivers markers around FROM if available
    if (fromPoint){
      try{
        const drv = await driversNearby(fromPoint.lat, fromPoint.lon);
        setDrivers(drv);
      }catch(e){/*ignore*/}
    }
  }

  function setDrivers(drivers){
    driverMarkers.forEach(m=>m.remove());
    driverMarkers = [];
    const arr = Array.isArray(drivers) ? drivers : [];
    setDriversCount(arr.length);

    for (const d of arr){
      const m = new maplibregl.Marker({color:"#0f172a"})
        .setLngLat([d.lon, d.lat])
        .setPopup(new maplibregl.Popup().setText(`Водитель ${d.driver_id} • ${d.age_seconds}s`))
        .addTo(map);
      driverMarkers.push(m);
    }
  }

  function buildPayload(){
    if (!fromPoint || !toPoint) return null;
    return {
      from: {lat: fromPoint.lat, lon: fromPoint.lon, address: fromPoint.address},
      to: [{lat: toPoint.lat, lon: toPoint.lon, address: toPoint.address}],
      comment: (commentInput.value || "").trim()
    };
  }

  function sendOrder(){
    const payload = buildPayload();
    if (!payload){
      alert("Нужно выбрать «Откуда» и «Куда».");
      return;
    }
    const json = JSON.stringify(payload);

    if (tg){
      tg.sendData(json);
      // TG сам закроет, но можно помочь
      try{ tg.close(); }catch(e){}
    }else{
      console.log("WebAppData:", json);
      alert("Открыто в браузере. В Telegram MiniApp заказ уйдёт в бота автоматически.");
    }
  }

  function clearAll(){
    fromPoint = null;
    toPoint = null;
    pickMode = null;
    if (fromMarker) { fromMarker.remove(); fromMarker=null; }
    if (toMarker) { toMarker.remove(); toMarker=null; }
    setDrivers([]);
    updateInputs();
    setStatus("Выбери «Откуда» и ткни на карту", "warn");
  }

  // map init
  applyTgTheme();

  if (tg){
    tg.ready();
    tg.expand();
    tg.MainButton.hide();
    tg.onEvent("themeChanged", applyTgTheme);
    tg.MainButton.onClick(sendOrder);
  }

  const map = new maplibregl.Map({
    container: "map",
    style: STYLE_URL || "https://demotiles.maplibre.org/style.json",
    center: [158.40, 52.93],
    zoom: 11
  });
  map.addControl(new maplibregl.NavigationControl({visualizePitch:true}));

  map.on("click", async (e)=>{
    try{
      const lat = e.lngLat.lat;
      const lon = e.lngLat.lng;
      const rev = await reverse(lat, lon);
      const addr = rev?.display_name || `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
      await pickPoint({lat, lon}, addr);
    }catch(err){
      console.warn(err);
      alert("Не удалось определить адрес. Попробуй ещё раз.");
    }
  });

  // UI actions
  btnPickFrom.addEventListener("click", ()=>{
    pickMode = "from";
    setStatus("Режим: выбираем «Откуда». Ткни на карту", "warn");
  });
  btnPickTo.addEventListener("click", ()=>{
    pickMode = "to";
    setStatus("Режим: выбираем «Куда». Ткни на карту", "warn");
  });

  btnClear.addEventListener("click", clearAll);

  btnMyPos.addEventListener("click", ()=>{
    if (!navigator.geolocation){
      alert("Геолокация недоступна.");
      return;
    }
    navigator.geolocation.getCurrentPosition(async (pos)=>{
      const lat = pos.coords.latitude;
      const lon = pos.coords.longitude;
      map.flyTo({center:[lon,lat], zoom: 15});
      try{
        const rev = await reverse(lat, lon);
        const addr = rev?.display_name || `${lat.toFixed(6)}, ${lon.toFixed(6)}`;
        // если from не выбран — ставим как "Откуда"
        if (!fromPoint){
          pickMode = "from";
        }
        await pickPoint({lat, lon}, addr);
      }catch(e){
        // fallback without reverse
        if (!fromPoint){
          pickMode = "from";
        }
        await pickPoint({lat, lon}, `${lat.toFixed(6)}, ${lon.toFixed(6)}`);
      }
    }, ()=>{
      alert("Не получилось получить геопозицию.");
    }, {enableHighAccuracy:true, timeout: 8000});
  });

  // Search with debounce
  let t = null;
  searchInput.addEventListener("input", ()=>{
    const q = (searchInput.value || "").trim();
    if (t) clearTimeout(t);
    if (q.length < 3){
      showResults([]);
      return;
    }
    t = setTimeout(async ()=>{
      try{
        const res = await search(q);
        showResults(Array.isArray(res) ? res : []);
      }catch(e){
        console.warn(e);
        showResults([]);
      }
    }, 300);
  });

  // periodic drivers refresh (around FROM)
  setInterval(async ()=>{
    if (!fromPoint) return;
    try{
      const drv = await driversNearby(fromPoint.lat, fromPoint.lon);
      setDrivers(drv);
    }catch(e){/*ignore*/}
  }, 5000);

  // init
  clearAll();

})();
JS

# 3) index.html (clean, no giant inline scripts)
cat > miniapp/index.html <<'HTML'
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Быстро и точка — заказ</title>

  <script src="https://telegram.org/js/telegram-web-app.js"></script>

  <link href="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css" rel="stylesheet">
  <script src="https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js"></script>

  <script src="./config.js"></script>
  <link rel="stylesheet" href="./styles.css">
</head>
<body>
  <div id="map"></div>

  <div id="topbar">
    <div id="statusBadge" class="badge"><span class="dot warn"></span> Выбери «Откуда» и ткни на карту</div>
    <div id="driversBadge" class="badge"><span class="dot warn"></span> Машины рядом: <b>0</b></div>
  </div>

  <div id="sheet">
    <div class="handle"></div>

    <div class="row">
      <div class="col">
        <label>Откуда</label>
        <input id="fromInput" class="input" readonly placeholder="Нажми «Откуда» и ткни на карту"/>
      </div>
      <button id="btnPickFrom" class="btn">Откуда</button>
    </div>

    <div class="row">
      <div class="col">
        <label>Куда</label>
        <input id="toInput" class="input" readonly placeholder="Нажми «Куда» и ткни на карту"/>
      </div>
      <button id="btnPickTo" class="btn">Куда</button>
    </div>

    <div class="row" id="results">
      <div class="col">
        <label>Поиск адреса</label>
        <input id="searchInput" class="input" placeholder="Например: Вилючинск, Нахимова 12"/>
        <div id="resultsList"></div>
      </div>
    </div>

    <div class="row">
      <div class="col">
        <label>Комментарий (необязательно)</label>
        <input id="commentInput" class="input" placeholder="Подъезд, ориентир, детское кресло..."/>
        <div class="small" style="margin-top:6px;">Кнопка «🚕 Заказать» появится внизу Telegram, когда точки выбраны.</div>
      </div>
    </div>

    <div class="row">
      <button id="btnMyPos" class="btn secondary">Моё местоположение</button>
      <button id="btnClear" class="btn danger">Сброс</button>
    </div>
  </div>

  <script defer src="./app.js"></script>
</body>
</html>
HTML

echo "== git commit/push =="
git add miniapp/index.html miniapp/app.js miniapp/styles.css
git commit -m "MiniApp: new client UX (from/to picker, search, comment, TG MainButton)" || true
git push origin main

echo "== done. MiniApp files updated. =="
