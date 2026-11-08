// app.js — Plataforma de Control de Gestión (MVP)
// Lógica de navegación + llamadas a la API REST (ver backend/app.py).

const API = "/api";

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------

function fmtMoney(n) {
  const v = Number(n || 0);
  return v.toLocaleString("es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 });
}

function fmtFecha(f) {
  if (!f) return "";
  return f.slice(0, 10);
}

async function apiGet(path) {
  const res = await fetch(`${API}${path}`);
  if (!res.ok) throw new Error((await res.json()).error || "Error al consultar");
  return res.json();
}

async function apiPost(path, payload) {
  const res = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || "Error al guardar");
  return data;
}

function showMsg(elId, text, ok = true) {
  const el = document.getElementById(elId);
  if (!el) return;
  el.textContent = text;
  el.className = "form-msg " + (ok ? "ok" : "err");
  setTimeout(() => {
    el.textContent = "";
    el.className = "form-msg";
  }, 4000);
}

function formToPayload(form) {
  const data = new FormData(form);
  const payload = {};
  for (const el of form.elements) {
    if (!el.name) continue;
    if (el.type === "checkbox") {
      payload[el.name] = el.checked;
    } else if (data.has(el.name)) {
      const v = data.get(el.name);
      payload[el.name] = v === "" ? null : v;
    }
  }
  return payload;
}

// ---------------------------------------------------------------------------
// Navegación entre vistas
// ---------------------------------------------------------------------------

function initNav() {
  const buttons = document.querySelectorAll(".nav-btn");
  buttons.forEach((btn) => {
    btn.addEventListener("click", () => {
      buttons.forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
      document.getElementById(`view-${btn.dataset.view}`).classList.add("active");

      if (btn.dataset.view === "dashboard") loadDashboard();
      if (btn.dataset.view === "ventas") loadVentas();
      if (btn.dataset.view === "compras") loadCompras();
      if (btn.dataset.view === "caja") loadCaja();
      if (btn.dataset.view === "catalogos") loadCatalogos();
    });
  });
}

// ---------------------------------------------------------------------------
// Catálogos compartidos (selects de tercero / centro de costo)
// ---------------------------------------------------------------------------

let CACHE_TERCEROS = [];
let CACHE_CENTROS = [];

async function refreshCatalogCaches() {
  [CACHE_TERCEROS, CACHE_CENTROS] = await Promise.all([
    apiGet("/terceros"),
    apiGet("/centros_costo"),
  ]);
}

function fillTerceroSelects(role) {
  const selects = document.querySelectorAll(`select[data-role="${role}"], select[name="id_tercero"]`);
  selects.forEach((sel) => {
    const current = sel.value;
    const roleFilter = sel.dataset.role;
    const opts = CACHE_TERCEROS.filter((t) => {
      if (roleFilter === "cliente") return !!t.es_cliente;
      if (roleFilter === "proveedor") return !!t.es_proveedor;
      return true;
    });
    const placeholder = sel.querySelector('option[value=""]');
    sel.innerHTML = "";
    if (placeholder) sel.appendChild(placeholder);
    else if (!sel.hasAttribute("required")) {
      const o = document.createElement("option");
      o.value = "";
      o.textContent = "(ninguno)";
      sel.appendChild(o);
    }
    opts.forEach((t) => {
      const o = document.createElement("option");
      o.value = t.id_tercero;
      o.textContent = `${t.razon_social} (${t.codigo_tercero})`;
      sel.appendChild(o);
    });
    if (current) sel.value = current;
  });
}

function fillCentroSelects() {
  document.querySelectorAll('select[name="id_centro_costo"]').forEach((sel) => {
    const current = sel.value;
    const placeholder = sel.querySelector('option[value=""]');
    sel.innerHTML = "";
    if (placeholder) sel.appendChild(placeholder);
    CACHE_CENTROS.forEach((c) => {
      const o = document.createElement("option");
      o.value = c.id_centro_costo;
      o.textContent = c.nombre;
      sel.appendChild(o);
    });
    if (current) sel.value = current;
  });
}

async function refreshAllSelects() {
  await refreshCatalogCaches();
  fillTerceroSelects("cliente");
  fillTerceroSelects("proveedor");
  fillCentroSelects();
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

async function loadDashboard() {
  try {
    const d = await apiGet("/dashboard");
    document.getElementById("kpi-ventas").textContent = fmtMoney(d.ventas_neto);
    document.getElementById("kpi-ventas-n").textContent = `${d.ventas_count} ventas`;
    document.getElementById("kpi-compras").textContent = fmtMoney(d.compras_neto);
    document.getElementById("kpi-compras-n").textContent = `${d.compras_count} documentos`;
    document.getElementById("kpi-margen").textContent = fmtMoney(d.margen_bruto);
    document.getElementById("kpi-caja").textContent = fmtMoney(d.saldo_caja);

    const meses = new Map();
    d.ventas_por_mes.forEach((r) => meses.set(r.mes, { mes: r.mes, ventas: r.neto, compras: 0 }));
    d.compras_por_mes.forEach((r) => {
      const row = meses.get(r.mes) || { mes: r.mes, ventas: 0, compras: 0 };
      row.compras = r.neto;
      meses.set(r.mes, row);
    });
    const tbody = document.querySelector("#tabla-meses tbody");
    tbody.innerHTML = "";
    [...meses.values()]
      .sort((a, b) => a.mes.localeCompare(b.mes))
      .forEach((r) => {
        const tr = document.createElement("tr");
        tr.innerHTML = `<td>${r.mes}</td><td>${fmtMoney(r.ventas)}</td><td>${fmtMoney(r.compras)}</td>`;
        tbody.appendChild(tr);
      });
  } catch (e) {
    console.error(e);
  }
}

// ---------------------------------------------------------------------------
// Ventas
// ---------------------------------------------------------------------------

async function loadVentas() {
  await refreshAllSelects();
  const rows = await apiGet("/ventas");
  const tbody = document.querySelector("#tabla-ventas tbody");
  tbody.innerHTML = "";
  rows.forEach((v) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${v.folio_factura}</td>
      <td>${v.cliente}</td>
      <td>${v.centro_costo || "—"}</td>
      <td>${fmtFecha(v.fecha_emision)}</td>
      <td>${fmtMoney(v.monto_neto)}</td>
      <td>${fmtMoney(v.monto_iva)}</td>
      <td>${fmtMoney(v.monto_total)}</td>
      <td>${v.estado_venta}</td>`;
    tbody.appendChild(tr);
  });
}

function initFormVenta() {
  const form = document.getElementById("form-venta");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/ventas", formToPayload(form));
      showMsg("msg-venta", "Venta registrada.");
      form.reset();
      loadVentas();
      loadDashboard();
    } catch (err) {
      showMsg("msg-venta", err.message, false);
    }
  });
}

// ---------------------------------------------------------------------------
// Compras
// ---------------------------------------------------------------------------

async function loadCompras() {
  await refreshAllSelects();
  const rows = await apiGet("/compras");
  const tbody = document.querySelector("#tabla-compras tbody");
  tbody.innerHTML = "";
  rows.forEach((c) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${c.folio_documento}</td>
      <td>${c.proveedor}</td>
      <td>${c.centro_costo || "—"}</td>
      <td>${fmtFecha(c.fecha_emision)}</td>
      <td>${c.descripcion}</td>
      <td>${fmtMoney(c.monto_neto)}</td>
      <td>${fmtMoney(c.monto_iva)}</td>
      <td>${fmtMoney(c.monto_total)}</td>`;
    tbody.appendChild(tr);
  });
}

function initFormCompra() {
  const form = document.getElementById("form-compra");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/compras", formToPayload(form));
      showMsg("msg-compra", "Compra/gasto registrado.");
      form.reset();
      loadCompras();
      loadDashboard();
    } catch (err) {
      showMsg("msg-compra", err.message, false);
    }
  });
}

// ---------------------------------------------------------------------------
// Caja
// ---------------------------------------------------------------------------

const TIPO_FLUJO_LABEL = {
  INGRESO: "Ingreso",
  EGRESO: "Egreso",
  TRASPASO_HASTA: "Traspaso (hacia)",
  TRASPASO_DESDE: "Traspaso (desde)",
};

async function loadCaja() {
  await refreshAllSelects();
  const rows = await apiGet("/caja");
  const tbody = document.querySelector("#tabla-caja tbody");
  tbody.innerHTML = "";
  rows.forEach((m) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${fmtFecha(m.fecha_movimiento)}</td>
      <td>${TIPO_FLUJO_LABEL[m.tipo_flujo] || m.tipo_flujo}</td>
      <td>${fmtMoney(m.monto_absoluto)}</td>
      <td>${m.glosa_movimiento}</td>
      <td>${m.tercero || "—"}</td>
      <td>${m.centro_costo || "—"}</td>`;
    tbody.appendChild(tr);
  });
}

function initFormCaja() {
  const form = document.getElementById("form-caja");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/caja", formToPayload(form));
      showMsg("msg-caja", "Movimiento registrado.");
      form.reset();
      loadCaja();
      loadDashboard();
    } catch (err) {
      showMsg("msg-caja", err.message, false);
    }
  });
}

// ---------------------------------------------------------------------------
// Catálogos (terceros, productos, centros de costo)
// ---------------------------------------------------------------------------

async function loadCatalogos() {
  const [terceros, productos, centros] = await Promise.all([
    apiGet("/terceros"),
    apiGet("/productos"),
    apiGet("/centros_costo"),
  ]);

  const tTerceros = document.querySelector("#tabla-terceros tbody");
  tTerceros.innerHTML = "";
  terceros.forEach((t) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${t.codigo_tercero}</td>
      <td>${t.razon_social}</td>
      <td>${t.rut_dni}</td>
      <td>${t.es_cliente ? "✓" : "—"}</td>
      <td>${t.es_proveedor ? "✓" : "—"}</td>`;
    tTerceros.appendChild(tr);
  });

  const tProductos = document.querySelector("#tabla-productos tbody");
  tProductos.innerHTML = "";
  productos.forEach((p) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${p.sku_codigo}</td>
      <td>${p.nombre}</td>
      <td>${fmtMoney(p.precio_venta_base)}</td>
      <td>${p.modo_obtencion || "(sin clasificar)"}</td>`;
    tProductos.appendChild(tr);
  });

  const tCentros = document.querySelector("#tabla-centros tbody");
  tCentros.innerHTML = "";
  centros.forEach((c) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td>${c.nombre}</td>`;
    tCentros.appendChild(tr);
  });
}

function initFormTercero() {
  const form = document.getElementById("form-tercero");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/terceros", formToPayload(form));
      showMsg("msg-tercero", "Tercero agregado.");
      form.reset();
      loadCatalogos();
      refreshCatalogCaches();
    } catch (err) {
      showMsg("msg-tercero", err.message, false);
    }
  });
}

function initFormProducto() {
  const form = document.getElementById("form-producto");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/productos", formToPayload(form));
      showMsg("msg-producto", "Producto agregado.");
      form.reset();
      loadCatalogos();
    } catch (err) {
      showMsg("msg-producto", err.message, false);
    }
  });
}

function initFormCentro() {
  const form = document.getElementById("form-centro");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    try {
      await apiPost("/centros_costo", formToPayload(form));
      showMsg("msg-centro", "Centro de costo agregado.");
      form.reset();
      loadCatalogos();
      refreshCatalogCaches();
    } catch (err) {
      showMsg("msg-centro", err.message, false);
    }
  });
}

// ---------------------------------------------------------------------------
// Arranque
// ---------------------------------------------------------------------------

document.addEventListener("DOMContentLoaded", () => {
  initNav();
  initFormVenta();
  initFormCompra();
  initFormCaja();
  initFormTercero();
  initFormProducto();
  initFormCentro();

  // Carga inicial (vista por defecto: dashboard)
  loadDashboard();
});
