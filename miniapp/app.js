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
