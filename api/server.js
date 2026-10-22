'use strict';

// seguros-api: API REST en el IBM i que expone el RPG INSDEMO/SEGAPI a la web de OCP.
// Instana: el collector debe cargarse antes que cualquier otro modulo. Reporta al agente
// local del IBM i (localhost:42699).
const instana = require('@instana/collector')({ serviceName: 'seguros-api' });

const express = require('express');
const { DBPool } = require('idb-pconnector');

const PORT = Number(process.env.PORT || 8090);
const CALL_SEGAPI = 'CALL INSDEMO.SEGAPI(?, ?, ?, ?, ?, ?)';
const pool = new DBPool({ url: '*LOCAL' }, { incrementSize: 2 });

// W3C traceparent del span actual, para que el RPG continue esta traza
function traceparent() {
  const span = instana.currentSpan();
  const traceId = span && span.getTraceId && span.getTraceId();
  const spanId = span && span.getSpanId && span.getSpanId();
  if (!traceId || !spanId) return '';
  return `00-${traceId.padStart(32, '0')}-${spanId}-01`;
}

// Llama al procedimiento SQL dentro de un exit span; el RPG recibe el traceparent de ese span
let seq = 0;
const log = (...a) => console.log(new Date().toISOString(), ...a);

async function segapi(accion, { numpol = '', filtro = '', importe = 0, descrip = '' } = {}) {
  const id = ++seq; const t0 = Date.now();
  log(`#${id} ${accion} ${numpol || filtro} inicio`);
  await instana.sdk.promise.startExitSpan('Db2 for i CALL INSDEMO.SEGAPI', { accion, numpol });
  log(`#${id} exit span ${Date.now() - t0}ms`);
  try {
    const result = await pool.prepareExecute(CALL_SEGAPI,
      [accion, numpol, filtro, importe, descrip, traceparent()]);
    log(`#${id} CALL ok ${Date.now() - t0}ms`);
    instana.sdk.promise.completeExitSpan();
    return (result && result.resultSet) || [];
  } catch (err) {
    instana.sdk.promise.completeExitSpan(err);
    throw err;
  }
}

const trim = (v) => (typeof v === 'string' ? v.trim() : v);
const toPoliza = (r) => ({
  numpol: trim(r.NUMPOL),
  titular: trim(r.TITULAR),
  ramo: trim(r.RAMO),
  prima: Number(r.PRIMA),
  vencimiento: trim(r.FECVTO),
  estado: trim(r.ESTADO),
  ...(r.SINIESTROS !== undefined && {
    siniestros: Number(r.SINIESTROS),
    importeTotal: Number(r.IMPORTE_TOTAL),
    ultimoSiniestro: trim(r.ULTIMO_SINIESTRO) || null,
  }),
});

const app = express();
app.use(express.json());

app.get('/health', (req, res) => res.json({ status: 'ok' }));

app.get('/api/polizas', async (req, res, next) => {
  try {
    const rows = await segapi('LISTAR', { filtro: String(req.query.filtro || '').slice(0, 20) });
    res.json(rows.map(toPoliza));
  } catch (err) { next(err); }
});

app.get('/api/polizas/:numpol', async (req, res, next) => {
  try {
    const rows = await segapi('CONSULTAR', { numpol: req.params.numpol.slice(0, 10) });
    if (rows.length === 0) return res.status(404).json({ error: 'Poliza no encontrada' });
    res.json(toPoliza(rows[0]));
  } catch (err) { next(err); }
});

// rc 0 -> 201, rc 1 (rechazo de negocio) -> 422, rc 2 (fallo tecnico) -> 502
app.post('/api/polizas/:numpol/siniestros', async (req, res, next) => {
  try {
    const importe = Number(req.body && req.body.importe);
    const descrip = String((req.body && req.body.descripcion) || '').slice(0, 50);
    const rows = await segapi('ALTA', { numpol: req.params.numpol.slice(0, 10), importe, descrip });
    const r = rows[0] || {};
    const rc = Number(r.RC);
    const body = { estado: trim(r.ESTADO), mensaje: trim(r.MENSAJE), rc, traceId: trim(r.TRACEID) };
    res.status(rc === 0 ? 201 : rc === 1 ? 422 : 502).json(body);
  } catch (err) { next(err); }
});

app.use((err, req, res, next) => {
  console.error(new Date().toISOString(), req.method, req.originalUrl, err.message);
  res.status(500).json({ error: 'Error llamando al IBM i', detalle: err.message });
});

const server = app.listen(PORT, () => console.log(`seguros-api escuchando en el puerto ${PORT}`));
// Conexiones persistentes con seguros-web (OCP): abrir una conexion por peticion detras del NAT
// de OCP provocaba cuelgues intermitentes al conectar (puertos reutilizados en TIME_WAIT).
server.keepAliveTimeout = 120000;
server.headersTimeout = 121000;

// Diagnostico: avisa si el event loop se bloquea mas de 1 s
let ultimoTick = Date.now();
setInterval(() => {
  const retraso = Date.now() - ultimoTick - 100;
  if (retraso > 1000) log(`EVENT LOOP BLOQUEADO ${retraso}ms`);
  ultimoTick = Date.now();
}, 100).unref();
