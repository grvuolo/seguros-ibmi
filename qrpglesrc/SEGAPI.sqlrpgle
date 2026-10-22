**FREE
// SEGAPI - Seguros Demo: logica de SEGPOL expuesta como procedimiento SQL INSDEMO.SEGAPI
// Lo llama la API Node (seguros-api) del IBM i, que a su vez llama la web de OCP (seguros-web).
// Recibe el W3C traceparent de la API y continua su traza, asi Instana muestra
// OCP -> IBM i (Node) -> RPG -> SEGVAL -> Db2 en una sola traza.
//
// Acciones (parametro ACCION):
//   LISTAR     result set: polizas cuyo titular contiene FILTRO
//   CONSULTAR  result set: la poliza NUMPOL con numero e importe de siniestros
//   ALTA       registra un siniestro (valida con SEGVAL) y devuelve result set con
//              ESTADO, MENSAJE, RC (0 ok, 1 rechazo de negocio, 2 fallo tecnico) y TRACEID
// Casos de demo en ALTA:
//   - Importe > 50.000         -> "Reaseguro (sistema externo)" tarda ~2 s y falla (RC 2)
//   - Poliza ANULADA           -> RECHAZADO en SEGVAL (RC 1, span en error)
//   - Importe > 10.000 / IMPAGO -> REVISION tras antifraude (~3 s) / cobros (~1 s)
ctl-opt dftactgrp(*no) actgrp(*caller) main(SEGAPI)
        bnddir('RPGTRACE/RPGTRACE') option(*srcstmt:*nodebugio);

/INCLUDE RPGTRACE/QRPGLESRC,RPGTRACE_H

dcl-pr SEGAPI extpgm('SEGAPI');
  pAccion      char(10) const;
  pNumPol      char(10) const;
  pFiltro      char(20) const;
  pImporte     packed(11:2) const;
  pDescrip     char(50) const;
  pTraceparent char(55) const;
end-pr;

dcl-s segvalPgm char(21) inz('INSDEMO/SEGVAL');
dcl-pr SEGVAL extpgm(segvalPgm);
  pNumPol  char(10) const;
  pImporte packed(11:2) const;
  pEstado  char(10);
  pMensaje char(60);
  pRc      int(10);
end-pr;

dcl-c LIMITE_REASEGURO 50000;

// Resultado de ALTA, devuelto como result set de una fila
dcl-s rEstado  char(10);
dcl-s rMensaje char(60);
dcl-s rRc      int(10);
dcl-s rTraceId char(32);

dcl-proc SEGAPI;
  dcl-pi *n;
    pAccion      char(10) const;
    pNumPol      char(10) const;
    pFiltro      char(20) const;
    pImporte     packed(11:2) const;
    pDescrip     char(50) const;
    pTraceparent char(55) const;
  end-pi;
  dcl-s span   pointer;
  dcl-s nombre varchar(60);
  dcl-s accion char(10);

  exec sql set option commit = *none, closqlcsr = *endactgrp;

  accion = %upper(pAccion);
  select;
  when accion = 'LISTAR';
    nombre = 'SEGAPI Listar polizas';
  when accion = 'CONSULTAR';
    nombre = 'SEGAPI Consultar poliza';
  when accion = 'ALTA';
    nombre = 'SEGAPI Alta siniestro';
  other;
    nombre = 'SEGAPI ' + %trim(accion);
  endsl;

  // Cada llamada es su propia traza, o continua la de la API si llega traceparent
  initTraceSDK();
  setServiceName('segpol-rpg');
  if %trim(pTraceparent) = '';
    span = startSpanTraceparent(*null : nombre : 'ENTRY');
  else;
    span = startSpanTraceparent(%trim(pTraceparent) : nombre : 'ENTRY');
  endif;
  addSpanData(span : 'ibmi.program' : 'INSDEMO/SEGAPI');
  addSpanData(span : 'canal' : 'api');

  select;
  when accion = 'LISTAR';
    listar(span : pFiltro);
  when accion = 'CONSULTAR';
    consultar(span : pNumPol);
  when accion = 'ALTA';
    alta(span : pNumPol : pImporte : pDescrip);
  other;
    addSpanData(span : 'error' : 'Accion desconocida');
    endSpan(span : 1);
  endsl;
  return;
end-proc;

// ---------------------------------------------------------------------------
dcl-proc listar;
  dcl-pi *n;
    span  pointer;
    pFiltro char(20) const;
  end-pi;
  dcl-s child  pointer;
  dcl-s filtro varchar(22);

  filtro = '%' + %trim(pFiltro) + '%';
  addSpanData(span : 'filtro' : %trim(pFiltro));

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT NUMPOL, TITULAR, RAMO, PRIMA, FECVTO, ESTADO FROM INSDEMO.POLIZAS ' +
     'WHERE UPPER(TITULAR) LIKE UPPER(?) ORDER BY NUMPOL');
  exec sql declare cLista cursor with return to client for
             select numpol, titular, ramo, prima, char(fecvto, iso) as fecvto, estado
               from insdemo.polizas
              where upper(titular) like upper(:filtro)
              order by numpol;
  exec sql open cLista;
  endSpan(child : rcSql(child));
  endSpan(span : rcSql(span));
end-proc;

// ---------------------------------------------------------------------------
dcl-proc consultar;
  dcl-pi *n;
    span    pointer;
    pNumPol char(10) const;
  end-pi;
  dcl-s child pointer;

  addSpanData(span : 'poliza' : %trim(pNumPol));

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS + SINIESTROS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT P.*, COUNT(S.IDSIN), SUM(S.IMPORTE) FROM INSDEMO.POLIZAS P ' +
     'LEFT JOIN INSDEMO.SINIESTROS S ON S.NUMPOL = P.NUMPOL WHERE P.NUMPOL = ?');
  exec sql declare cPoliza cursor with return to client for
             select p.numpol, p.titular, p.ramo, p.prima, char(p.fecvto, iso) as fecvto, p.estado,
                    count(s.idsin) as siniestros,
                    coalesce(sum(s.importe), 0) as importe_total,
                    varchar_format(max(s.fecha), 'YYYY-MM-DD HH24:MI:SS') as ultimo_siniestro
               from insdemo.polizas p
               left join insdemo.siniestros s on s.numpol = p.numpol
              where p.numpol = :pNumPol
              group by p.numpol, p.titular, p.ramo, p.prima, p.fecvto, p.estado;
  exec sql open cPoliza;
  endSpan(child : rcSql(child));
  endSpan(span : rcSql(span));
end-proc;

// ---------------------------------------------------------------------------
dcl-proc alta;
  dcl-pi *n;
    span     pointer;
    pNumPol  char(10) const;
    pImporte packed(11:2) const;
    pDescrip char(50) const;
  end-pi;
  dcl-s child   pointer;
  dcl-s traceId char(33);
  dcl-s descrip varchar(50);

  addSpanData(span : 'poliza' : %trim(pNumPol));
  addSpanData(span : 'importe' : %char(pImporte));
  getTraceId(span : traceId : %size(traceId));
  rTraceId = %subst(traceId : 1 : 32);
  rRc = 0;

  select;
  when pImporte <= 0 or pDescrip = *blanks;
    rRc = 1;
    rEstado = 'RECHAZADO';
    rMensaje = 'Importe y descripcion son obligatorios';

  when pImporte > LIMITE_REASEGURO;
    // Fallo tecnico simulado: el sistema de reaseguro no responde
    child = startSpan('Reaseguro (sistema externo)' : 'INTERMEDIATE');
    addSpanData(child : 'umbral' : %char(LIMITE_REASEGURO));
    esperar(2);
    addSpanData(child : 'error' : 'Timeout en sistema de reaseguro');
    endSpan(child : 1);
    rRc = 2;
    rEstado = 'ERROR';
    rMensaje = 'Timeout en sistema de reaseguro';

  other;
    SEGVAL(pNumPol : pImporte : rEstado : rMensaje : rRc);

    descrip = %trim(pDescrip);
    child = startSpan('Db2 INSERT INSDEMO.SINIESTROS' : 'INTERMEDIATE');
    addSpanData(child : 'db.statement' :
       'INSERT INTO INSDEMO.SINIESTROS (NUMPOL, IMPORTE, DESCRIP, ESTADO, TRACEID) ' +
       'VALUES (?, ?, ?, ?, ?)');
    exec sql insert into insdemo.siniestros
                    (numpol, importe, descrip, estado, traceid)
             values (:pNumPol, :pImporte, :descrip, :rEstado, :rTraceId);
    if rcSql(child) <> 0;
      rRc = 2;
      rEstado = 'ERROR';
      rMensaje = 'Error SQL ' + %char(sqlcode) + ' al registrar el siniestro';
    endif;
    endSpan(child : rcSql(child));
  endsl;

  exec sql declare cResultado cursor with return to client for
             select :rEstado as estado, :rMensaje as mensaje,
                    :rRc as rc, :rTraceId as traceid
               from sysibm.sysdummy1;
  exec sql open cResultado;

  addSpanData(span : 'resultado' : %trim(rEstado));
  endSpan(span : rRc);
end-proc;

// ---------------------------------------------------------------------------
// 0 si la ultima sentencia SQL fue bien, 1 si fallo (y lo anota en el span)
dcl-proc rcSql;
  dcl-pi *n int(10);
    span pointer;
  end-pi;

  if sqlcode < 0;
    addSpanData(span : 'db.sqlcode' : %char(sqlcode));
    return 1;
  endif;
  return 0;
end-proc;

dcl-proc esperar;
  dcl-pi *n;
    segundos int(10) const;
  end-pi;
  dcl-s cmd varchar(40);

  cmd = 'DLYJOB DLY(' + %char(segundos) + ')';
  exec sql call qsys2.qcmdexc(:cmd);
end-proc;
