**FREE
// SEGPOL - Seguros Demo: cartera de polizas en pantalla verde 5250, instrumentada con Instana
//
// Cada accion del usuario es una traza independiente (span ENTRY):
//   "SEGPOL Listar polizas"   -> Db2 SELECT POLIZAS
//   "SEGPOL Consultar poliza" -> Db2 SELECT POLIZAS + SINIESTROS
//   "SEGPOL Alta siniestro"   -> SEGVAL (validacion, programa aparte) + Db2 INSERT SINIESTROS
// Los spans se cierran antes de mostrar la pantalla para no medir el tiempo de lectura del usuario.
ctl-opt dftactgrp(*no) actgrp('INSDEMO') bnddir('RPGTRACE/RPGTRACE')
        option(*srcstmt:*nodebugio);

/INCLUDE RPGTRACE/QRPGLESRC,RPGTRACE_H

dcl-f SEGPOLD workstn extdesc('INSDEMO/SEGPOLD') extfile(*extdesc)
                      sfile(POLSFL:rrn) indds(ind);

dcl-ds ind qualified;
  salir      ind pos(3);
  refrescar  ind pos(5);
  alta       ind pos(6);
  volver     ind pos(12);
  sflDsp     ind pos(31);
  sflDspCtl  ind pos(32);
  sflClr     ind pos(33);
  sflEnd     ind pos(34);
  anulada    ind pos(60);
end-ds;

dcl-ds psds psds qualified;
  job     char(10) pos(244);
  usuario char(10) pos(254);
  numJob  char(6)  pos(264);
end-ds;

dcl-s segvalPgm char(21) inz('INSDEMO/SEGVAL');
dcl-pr SEGVAL extpgm(segvalPgm);
  pNumPol  char(10) const;
  pImporte packed(11:2) const;
  pEstado  char(10);
  pMensaje char(60);
  pRc      int(10);
end-pr;

dcl-s rrn  packed(4:0);
dcl-s fin  ind inz(*off);
dcl-s seleccion char(10) dim(99);
dcl-s accion    char(1)  dim(99);
dcl-s nSel int(10);
dcl-s i    int(10);

exec sql set option commit = *none, closqlcsr = *endmod, datfmt = *iso;

initTraceSDK();
setServiceName('segpol-5250');

cargarLista();
dow not fin;
  write FOOTER;
  exfmt POLCTL;
  MSG = *blanks;

  select;
  when ind.salir;
    fin = *on;
  when ind.refrescar;
    cargarLista();
  other;
    // Recoger opciones antes de cambiar de pantalla
    nSel = 0;
    readc POLSFL;
    dow not %eof(SEGPOLD) and nSel < %elem(seleccion);
      if OPC = '5' or OPC = '6';
        nSel += 1;
        seleccion(nSel) = NUMPOL;
        accion(nSel) = OPC;
      endif;
      readc POLSFL;
    enddo;
    for i = 1 to nSel;
      if not fin;
        consultarPoliza(seleccion(i) : accion(i) = '6');
      endif;
    endfor;
    if not fin;
      cargarLista();
    endif;
  endsl;
enddo;

*inlr = *on;
return;

// ---------------------------------------------------------------------------
dcl-proc cargarLista;
  dcl-s span   pointer;
  dcl-s child  pointer;
  dcl-s filtro varchar(22);
  dcl-s rc     int(10) inz(0);
  dcl-ds pol qualified;
    numpol  char(10);
    titular varchar(40);
    ramo    char(10);
    prima   packed(9:2);
    estado  char(8);
  end-ds;

  span = nuevaTraza('SEGPOL Listar polizas');
  filtro = '%' + %trim(BUSCAR) + '%';
  addSpanData(span : 'filtro' : %trim(BUSCAR));

  ind.sflClr = *on;
  ind.sflDsp = *off;
  ind.sflDspCtl = *off;
  write POLCTL;
  ind.sflClr = *off;
  rrn = 0;

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT NUMPOL, TITULAR, RAMO, PRIMA, ESTADO FROM INSDEMO.POLIZAS ' +
     'WHERE UPPER(TITULAR) LIKE UPPER(?) ORDER BY NUMPOL');

  exec sql declare cPol cursor for
             select numpol, titular, ramo, prima, estado
               from insdemo.polizas
              where upper(titular) like upper(:filtro)
              order by numpol;
  exec sql open cPol;
  exec sql fetch cPol into :pol;
  dow sqlcode = 0 and rrn < 99;
    rrn += 1;
    OPC = ' ';
    NUMPOL = pol.numpol;
    TITULAR = pol.titular;
    RAMO = pol.ramo;
    evalr PRIMA = %trim(%editc(pol.prima : 'J'));
    ESTADO = pol.estado;
    ind.anulada = (pol.estado = 'ANULADA');
    write POLSFL;
    exec sql fetch cPol into :pol;
  enddo;
  if sqlcode < 0;
    rc = 1;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
    MSG = 'Error SQL ' + %char(sqlcode) + ' al leer las polizas';
  endif;
  exec sql close cPol;

  addSpanData(child : 'db.rows' : %char(rrn));
  endSpan(child : rc);

  ind.sflDsp = (rrn > 0);
  ind.sflDspCtl = *on;
  ind.sflEnd = *on;
  if rrn = 0 and rc = 0;
    MSG = 'No hay polizas que coincidan con el filtro';
  endif;

  addSpanData(span : 'polizas' : %char(rrn));
  endSpan(span : rc);
end-proc;

// ---------------------------------------------------------------------------
dcl-proc consultarPoliza;
  dcl-pi *n;
    numPol char(10) const;
    irAlta ind const;
  end-pi;
  dcl-s pendienteAlta ind;

  DMSG = *blanks;
  if not cargarDetalle(numPol);
    MSG = 'No se pudo leer la poliza ' + numPol;
    return;
  endif;

  pendienteAlta = irAlta;
  dow *on;
    if pendienteAlta;
      pendienteAlta = *off;
      if altaSiniestro();
        cargarDetalle(numPol);
      endif;
    endif;
    exfmt DETALLE;
    DMSG = *blanks;
    select;
    when ind.salir;
      fin = *on;
      leave;
    when ind.volver;
      leave;
    when ind.alta;
      pendienteAlta = *on;
    endsl;
  enddo;
end-proc;

// ---------------------------------------------------------------------------
dcl-proc cargarDetalle;
  dcl-pi *n ind;
    numPol char(10) const;
  end-pi;
  dcl-s span    pointer;
  dcl-s child   pointer;
  dcl-s titular varchar(40);
  dcl-s ramo    char(10);
  dcl-s prima   packed(9:2);
  dcl-s fecvto  date;
  dcl-s estado  char(8);
  dcl-s nSin    int(10);
  dcl-s total   packed(13:2);
  dcl-s ultFec  date;
  dcl-s ultDes  varchar(50);
  dcl-s ultEst  char(10);
  dcl-s ok      ind inz(*on);

  span = nuevaTraza('SEGPOL Consultar poliza');
  addSpanData(span : 'poliza' : %trim(numPol));

  child = startSpan('Db2 SELECT INSDEMO.POLIZAS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT TITULAR, RAMO, PRIMA, FECVTO, ESTADO FROM INSDEMO.POLIZAS WHERE NUMPOL = ?');
  exec sql select titular, ramo, prima, fecvto, estado
             into :titular, :ramo, :prima, :fecvto, :estado
             from insdemo.polizas
            where numpol = :numPol;
  if sqlcode <> 0;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
    endSpan(child : 1);
    endSpan(span : 1);
    return *off;
  endif;
  endSpan(child : 0);

  child = startSpan('Db2 SELECT INSDEMO.SINIESTROS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'SELECT COUNT(*), SUM(IMPORTE) FROM INSDEMO.SINIESTROS WHERE NUMPOL = ?');
  exec sql select count(*), coalesce(sum(importe), 0)
             into :nSin, :total
             from insdemo.siniestros
            where numpol = :numPol;
  DULTSIN = 'Sin siniestros';
  if nSin > 0;
    exec sql select date(fecha), descrip, estado
               into :ultFec, :ultDes, :ultEst
               from insdemo.siniestros
              where numpol = :numPol
              order by idsin desc
              fetch first 1 row only;
    if sqlcode = 0;
      DULTSIN = %char(ultFec : *eur) + ' ' + %trim(ultEst) + ' - ' + ultDes;
    endif;
  endif;
  if sqlcode < 0;
    ok = *off;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
  endif;
  if ok;
    endSpan(child : 0);
  else;
    endSpan(child : 1);
  endif;

  DNUMPOL = numPol;
  DTITULAR = titular;
  DRAMO = ramo;
  evalr DPRIMA = %trim(%editc(prima : 'J'));
  DFECVTO = %char(fecvto : *eur);
  DESTADO = estado;
  DNUMSIN = %char(nSin);
  evalr DTOTSIN = %trim(%editc(total : 'J'));
  ind.anulada = (estado = 'ANULADA');

  addSpanData(span : 'estado' : %trim(estado));
  addSpanData(span : 'siniestros' : %char(nSin));
  if ok;
    endSpan(span : 0);
  else;
    endSpan(span : 1);
  endif;
  return *on;
end-proc;

// ---------------------------------------------------------------------------
dcl-proc altaSiniestro;
  dcl-pi *n ind end-pi;
  dcl-s span     pointer;
  dcl-s child    pointer;
  dcl-s importe  packed(11:2);
  dcl-s descrip  varchar(50);
  dcl-s estado   char(10);
  dcl-s mensaje  char(60);
  dcl-s rc       int(10);
  dcl-s traceId  char(33);
  dcl-s idTraza  char(32);

  ANUMPOL = DNUMPOL;
  ATITULAR = DTITULAR;
  AIMPORTE = 0;
  ADESCRIP = *blanks;
  AMSG = *blanks;

  dow *on;
    exfmt ALTASIN;
    AMSG = *blanks;
    if ind.volver;
      return *off;
    endif;
    if AIMPORTE <= 0;
      AMSG = 'Indique un importe mayor que cero';
      iter;
    endif;
    if ADESCRIP = *blanks;
      AMSG = 'Indique una descripcion';
      iter;
    endif;
    leave;
  enddo;

  importe = AIMPORTE;
  descrip = %trim(ADESCRIP);

  span = nuevaTraza('SEGPOL Alta siniestro');
  addSpanData(span : 'poliza' : %trim(ANUMPOL));
  addSpanData(span : 'importe' : %char(importe));
  getTraceId(span : traceId : %size(traceId));
  idTraza = %subst(traceId : 1 : 32);

  SEGVAL(ANUMPOL : importe : estado : mensaje : rc);

  child = startSpan('Db2 INSERT INSDEMO.SINIESTROS' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
     'INSERT INTO INSDEMO.SINIESTROS (NUMPOL, IMPORTE, DESCRIP, ESTADO, TRACEID) ' +
     'VALUES (?, ?, ?, ?, ?)');
  exec sql insert into insdemo.siniestros
                  (numpol, importe, descrip, estado, traceid)
           values (:ANUMPOL, :importe, :descrip, :estado, :idTraza);
  if sqlcode < 0;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
    endSpan(child : 1);
    rc = 1;
    mensaje = 'Error SQL ' + %char(sqlcode) + ' al registrar el siniestro';
  else;
    endSpan(child : 0);
  endif;

  addSpanData(span : 'resultado' : %trim(estado));
  endSpan(span : rc);

  DMSG = %trim(estado) + ': ' + %trim(mensaje) + '  Traza ' + idTraza;
  return *on;
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
  addSpanData(span : 'ibmi.program' : 'INSDEMO/SEGPOL');
  addSpanData(span : 'ibmi.user' : %trim(psds.usuario));
  addSpanData(span : 'ibmi.job' :
              psds.numJob + '/' + %trim(psds.usuario) + '/' + %trim(psds.job));
  return span;
end-proc;
