**FREE
// SEGLOAD - Generador de trafico batch para Seguros Demo
// Simula lo que haria un usuario en las pantallas de SEGPOL, con las mismas trazas en Instana:
//   ~25% "SEGPOL Listar polizas", ~30% "SEGPOL Consultar poliza", ~45% "SEGPOL Alta siniestro"
// Las altas usan polizas e importes aleatorios, asi que mezclan los casos de SEGVAL
// (aceptado, IMPAGO ~1 s, antifraude ~3 s, ANULADA en error). Todas llevan el tag canal=batch.
//
// Uso:   SBMJOB CMD(CALL PGM(INSDEMO/SEGLOAD) PARM('0300' '03')) JOB(SEGLOAD) JOBQ(QUSRNOMAX)
//          parm 1: numero de transacciones (0000 = sin fin)   parm 2: pausa en segundos
// Parar: ENDJOB JOB(SEGLOAD) OPTION(*CNTRLD)
ctl-opt dftactgrp(*no) actgrp(*new) main(SEGLOAD)
        bnddir('RPGTRACE/RPGTRACE') option(*srcstmt:*nodebugio);

/INCLUDE RPGTRACE/QRPGLESRC,RPGTRACE_H

dcl-pr SEGLOAD extpgm('SEGLOAD');
  pTotal char(4) const;
  pPausa char(2) const;
end-pr;

dcl-s segvalPgm char(21) inz('INSDEMO/SEGVAL');
dcl-pr SEGVAL extpgm(segvalPgm);
  pNumPol  char(10) const;
  pImporte packed(11:2) const;
  pEstado  char(10);
  pMensaje char(60);
  pRc      int(10);
end-pr;

dcl-ds psds psds qualified;
  job     char(10) pos(244);
  usuario char(10) pos(254);
  numJob  char(6)  pos(264);
end-ds;

dcl-ds textos qualified;
  *n varchar(50) inz('Golpe en aparcamiento');
  *n varchar(50) inz('Rotura de cristal');
  *n varchar(50) inz('Danos por agua');
  *n varchar(50) inz('Robo en vivienda');
  *n varchar(50) inz('Accidente en autopista');
  *n varchar(50) inz('Hospitalizacion');
  texto varchar(50) dim(6) pos(1);
end-ds;

dcl-ds filtros qualified;
  *n varchar(10) inz('GARCIA');
  *n varchar(10) inz('LOPEZ');
  *n varchar(10) inz('RUIZ');
  *n varchar(10) inz('PEREZ');
  *n varchar(10) inz('');
  filtro varchar(10) dim(5) pos(1);
end-ds;

dcl-proc SEGLOAD;
  dcl-pi *n;
    pTotal char(4) const;
    pPausa char(2) const;
  end-pi;
  dcl-s total int(10) inz(100);
  dcl-s pausa int(10) inz(3);
  dcl-s n     int(10);
  dcl-s r     float(8);

  exec sql set option commit = *none, closqlcsr = *endmod;

  monitor;
    if %parms >= 1;
      total = %int(pTotal);
    endif;
    if %parms >= 2;
      pausa = %int(pPausa);
    endif;
  on-error;
  endmon;

  initTraceSDK();
  setServiceName('segpol-5250');

  dow (total = 0 or n < total) and not %shtdn;
    n += 1;
    r = aleatorio();
    select;
    when r < 0.25;
      listar();
    when r < 0.55;
      consultar();
    other;
      alta();
    endsl;
    if pausa > 0;
      esperar(pausa);
    endif;
  enddo;
  return;
end-proc;

// ---------------------------------------------------------------------------
dcl-proc listar;
  dcl-s span   pointer;
  dcl-s child  pointer;
  dcl-s filtro varchar(12);
  dcl-s f      varchar(10);
  dcl-s filas  int(10);

  f = filtros.filtro(indice(%elem(filtros.filtro)));
  filtro = '%' + f + '%';

  span = nuevaTraza('SEGPOL Listar polizas');
  addSpanData(span : 'filtro' : f);

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT NUMPOL, TITULAR, RAMO, PRIMA, ESTADO FROM INSDEMO.POLIZAS ' +
     'WHERE UPPER(TITULAR) LIKE UPPER(?) ORDER BY NUMPOL');
  exec sql select count(*) into :filas
             from insdemo.polizas
            where upper(titular) like upper(:filtro);
  addSpanData(child : 'db.rows' : %char(filas));
  endSpan(child : rcSql());

  addSpanData(span : 'polizas' : %char(filas));
  endSpan(span : rcSql());
end-proc;

// ---------------------------------------------------------------------------
dcl-proc consultar;
  dcl-s span    pointer;
  dcl-s child   pointer;
  dcl-s numPol  char(10);
  dcl-s estado  char(8);
  dcl-s nSin    int(10);
  dcl-s total   packed(13:2);
  dcl-s rc      int(10);

  numPol = polizaAleatoria();

  span = nuevaTraza('SEGPOL Consultar poliza');
  addSpanData(span : 'poliza' : %trim(numPol));

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT TITULAR, RAMO, PRIMA, FECVTO, ESTADO FROM INSDEMO.POLIZAS WHERE NUMPOL = ?');
  exec sql select estado into :estado
             from insdemo.polizas
            where numpol = :numPol;
  rc = rcSql();
  endSpan(child : rc);

  child = startSpan('Db2 SELECT INSDEMO.SINIESTROS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT COUNT(*), SUM(IMPORTE) FROM INSDEMO.SINIESTROS WHERE NUMPOL = ?');
  exec sql select count(*), coalesce(sum(importe), 0)
             into :nSin, :total
             from insdemo.siniestros
            where numpol = :numPol;
  endSpan(child : rcSql());

  addSpanData(span : 'estado' : %trim(estado));
  addSpanData(span : 'siniestros' : %char(nSin));
  endSpan(span : rc);
end-proc;

// ---------------------------------------------------------------------------
dcl-proc alta;
  dcl-s span     pointer;
  dcl-s child    pointer;
  dcl-s numPol   char(10);
  dcl-s importe  packed(11:2);
  dcl-s descrip  varchar(50);
  dcl-s estado   char(10);
  dcl-s mensaje  char(60);
  dcl-s rc       int(10);
  dcl-s traceId  char(33);
  dcl-s idTraza  char(32);

  numPol = polizaAleatoria();
  if aleatorio() < 0.2;
    importe = %dech(10001 + aleatorio() * 20000 : 11 : 2);   // pasa por antifraude
  else;
    importe = %dech(100 + aleatorio() * 8900 : 11 : 2);
  endif;
  descrip = textos.texto(indice(%elem(textos.texto)));

  span = nuevaTraza('SEGPOL Alta siniestro');
  addSpanData(span : 'poliza' : %trim(numPol));
  addSpanData(span : 'importe' : %char(importe));
  getTraceId(span : traceId : %size(traceId));
  idTraza = %subst(traceId : 1 : 32);

  SEGVAL(numPol : importe : estado : mensaje : rc);

  child = startSpan('Db2 INSERT INSDEMO.SINIESTROS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'INSERT INTO INSDEMO.SINIESTROS (NUMPOL, IMPORTE, DESCRIP, ESTADO, TRACEID) ' +
     'VALUES (?, ?, ?, ?, ?)');
  exec sql insert into insdemo.siniestros
                  (numpol, importe, descrip, estado, traceid)
           values (:numPol, :importe, :descrip, :estado, :idTraza);
  if rcSql() <> 0;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
    rc = 1;
  endif;
  endSpan(child : rcSql());

  addSpanData(span : 'resultado' : %trim(estado));
  endSpan(span : rc);
end-proc;

// ---------------------------------------------------------------------------
// Abre un span ENTRY en una traza nueva. initTraceSDK() reinicia el contexto de traza
// (startSpanTraceparent(*null) por si solo reutiliza el trace ID de la traza anterior).
dcl-proc nuevaTraza;
  dcl-pi *n pointer;
    nombre varchar(255) const;
  end-pi;
  dcl-s span pointer;

  initTraceSDK();
  setServiceName('segpol-5250');
  span = startSpanTraceparent(*null : nombre : 'ENTRY');
  addSpanData(span : 'ibmi.program' : 'INSDEMO/SEGLOAD');
  addSpanData(span : 'canal' : 'batch');
  addSpanData(span : 'ibmi.user' : %trim(psds.usuario));
  addSpanData(span : 'ibmi.job' :
              psds.numJob + '/' + %trim(psds.usuario) + '/' + %trim(psds.job));
  return span;
end-proc;

dcl-proc polizaAleatoria;
  dcl-pi *n char(10) end-pi;
  dcl-s numPol char(10);

  exec sql select numpol into :numPol
             from insdemo.polizas
            order by rand()
            fetch first 1 row only;
  return numPol;
end-proc;

dcl-proc aleatorio;
  dcl-pi *n float(8) end-pi;
  dcl-s r float(8);

  exec sql values rand() into :r;
  return r;
end-proc;

// Indice aleatorio entre 1 y max
dcl-proc indice;
  dcl-pi *n int(10);
    max int(10) const;
  end-pi;
  dcl-s i int(10);

  i = %int(aleatorio() * max) + 1;
  if i > max;
    i = max;
  endif;
  return i;
end-proc;

// 0 si la ultima sentencia SQL fue bien (o sin filas), 1 si fallo
dcl-proc rcSql;
  dcl-pi *n int(10) end-pi;

  if sqlcode < 0;
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
