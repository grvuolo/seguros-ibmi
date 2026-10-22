'use strict';

// seguros-web: UI web en OpenShift que llama a seguros-api en el IBM i.
// Instana: el collector debe cargarse antes que cualquier otro modulo. En OCP el agente
// corre en cada nodo; el Deployment pasa su IP en INSTANA_AGENT_HOST (status.hostIP).
require('@instana/collector')({ serviceName: 'seguros-web' });

const express = require('express');
const http = require('http');
const path = require('path');

const PORT = Number(process.env.PORT || 8080);
const IBMI_API_URL = new URL(process.env.IBMI_API_URL || 'http://10.1.3.125:8090');
const TIMEOUT_MS = Number(process.env.IBMI_TIMEOUT_MS || 15000);

// Conexiones persistentes con el IBM i: abrir una por peticion detras del NAT de OCP hacia
// que algunas no llegaran a conectar. La API del IBM i las mantiene 120 s (keepAliveTimeout).
const agenteIbmi = new http.Agent({ keepAlive: true, keepAliveMsecs: 10000, maxSockets: 10 });

const CONNECT_TIMEOUT_MS = Number(process.env.IBMI_CONNECT_TIMEOUT_MS || 3000);
const REINTENTOS = Number(process.env.IBMI_REINTENTOS || 2);

// Algunas conexiones TCP hacia el IBM i tardan en establecerse de forma intermitente.
// Si el socket no conecta en CONNECT_TIMEOUT_MS se reintenta: la peticion no salio, asi
// que es seguro tambien para POST. El timeout de respuesta (TIMEOUT_MS) no se toca.
async function llamarIbmi(method, apiPath, body) {
  for (let intento = 0; ; intento++) {
    try {
      return await llamarIbmiUnaVez(method, apiPath, body);
    } catch (err) {
      if (!err.sinConexion || intento >= REINTENTOS) throw err;
      console.warn(new Date().toISOString(), `reintento ${intento + 1} ${method} ${apiPath}: ${err.message}`);
    }
  }
}

// Llamada HTTP a seguros-api (modulo http: Instana la traza y propaga el contexto)
function llamarIbmiUnaVez(method, apiPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = http.request({
      host: IBMI_API_URL.hostname,
      port: IBMI_API_URL.port || 80,
      method,
      path: apiPath,
      timeout: TIMEOUT_MS,
      agent: agenteIbmi,
      headers: {
        Accept: 'application/json',
        ...(payload && { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }),
      },
    }, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { data += c; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('socket', (socket) => {
      if (!socket.connecting) return;
      const t = setTimeout(() => {
        const e = new Error(`Sin conexion con el IBM i en ${CONNECT_TIMEOUT_MS} ms`);
        e.sinConexion = true;
        req.destroy(e);
      }, CONNECT_TIMEOUT_MS);
      socket.once('connect', () => clearTimeout(t));
      socket.once('close', () => clearTimeout(t));
    });
    req.on('timeout', () => req.destroy(new Error(`Timeout de ${TIMEOUT_MS} ms llamando al IBM i`)));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

const app = express();
app.use(express.json());

app.get('/healthz', (req, res) => res.json({ status: 'ok' }));

// Proxy de /api/* hacia seguros-api en el IBM i
app.use('/api', async (req, res) => {
  try {
    const body = ['POST', 'PUT', 'PATCH'].includes(req.method) ? req.body : null;
    const r = await llamarIbmi(req.method, '/api' + req.url, body);
    res.status(r.status).type('application/json').send(r.body || '{}');
  } catch (err) {
    console.error(new Date().toISOString(), req.method, req.originalUrl, err.message);
    res.status(504).json({ error: 'El IBM i no responde', detalle: err.message });
  }
});

app.use(express.static(path.join(__dirname, 'public')));

app.listen(PORT, () => console.log(`seguros-web escuchando en ${PORT}; IBM i: ${IBMI_API_URL.href}`));
