**FREE
// SEGVAL - Validacion de siniestros (llamado por SEGPOL)
// Reglas de negocio de la demo, cada paso es un span hijo en la traza de Instana:
//   - Poliza inexistente o ANULADA  -> RECHAZADO, span en error (rc=1)
//   - Poliza en IMPAGO              -> REVISION tras consultar cobros (~1 s)
//   - Importe > 10.000              -> REVISION tras scoring antifraude (~3 s)
//   - Resto                         -> ACEPTADO
// No llama a initTraceSDK(): hereda el contexto de traza del programa de entrada.
ctl-opt dftactgrp(*no) actgrp(*caller) main(SEGVAL)
        bnddir('RPGTRACE/RPGTRACE') option(*srcstmt:*nodebugio);

/INCLUDE RPGTRACE/QRPGLESRC,RPGTRACE_H

dcl-pr SEGVAL extpgm('SEGVAL');
  pNumPol  char(10) const;
  pImporte packed(11:2) const;
  pEstado  char(10);
  pMensaje char(60);
  pRc      int(10);
end-pr;

dcl-c LIMITE_ANTIFRAUDE 10000;

dcl-proc SEGVAL;
  dcl-pi *n;
    pNumPol  char(10) const;
    pImporte packed(11:2) const;
    pEstado  char(10);
    pMensaje char(60);
    pRc      int(10);
  end-pi;

  dcl-s span    pointer;
  dcl-s child   pointer;
  dcl-s estPol  char(8);

  exec sql set option commit = *none, closqlcsr = *endmod;

  pRc = 0;
  pEstado = 'ACEPTADO';
  pMensaje = 'Siniestro aceptado';

  span = startSpan('SEGVAL Validar siniestro' : 'INTERMEDIATE');
  addSpanData(span : 'ibmi.program' : 'INSDEMO/SEGVAL');
  addSpanData(span : 'poliza' : %trim(pNumPol));
  addSpanData(span : 'importe' : %char(pImporte));

  // 1. Estado de la poliza
  child = startSpan('Db2 SELECT INSDEMO.POLIZAS (estado)' : 'INTERMEDIATE');
  addSpanData(child : 'db.statement' :
              'SELECT ESTADO FROM INSDEMO.POLIZAS WHERE NUMPOL = ?');
  exec sql select estado into :estPol
             from insdemo.polizas
            where numpol = :pNumPol;
  if sqlcode < 0;
    addSpanData(child : 'db.sqlcode' : %char(sqlcode));
    endSpan(child : 1);
  else;
    endSpan(child : 0);
  endif;

  select;
  when sqlcode = 100;
    pRc = 1;
    pEstado = 'RECHAZADO';
    pMensaje = 'La poliza no existe';
  when sqlcode < 0;
    pRc = 1;
    pEstado = 'RECHAZADO';
    pMensaje = 'Error SQL ' + %char(sqlcode) + ' al leer la poliza';
  when estPol = 'ANULADA';
    pRc = 1;
    pEstado = 'RECHAZADO';
    pMensaje = 'Poliza anulada: no admite siniestros';
  other;
    // 2. Recibos pendientes
    if estPol = 'IMPAGO';
      child = startSpan('Consulta cobros pendientes' : 'INTERMEDIATE');
      addSpanData(child : 'sistema' : 'COBROS');
      esperar(1);
      endSpan(child : 0);
      pEstado = 'REVISION';
      pMensaje = 'Recibos pendientes: pasa a revision';
    endif;

    // 3. Scoring antifraude para importes altos
    if pImporte > LIMITE_ANTIFRAUDE;
      child = startSpan('Scoring antifraude' : 'INTERMEDIATE');
      addSpanData(child : 'umbral' : %char(LIMITE_ANTIFRAUDE));
      esperar(3);
      addSpanData(child : 'resultado' : 'REVISAR');
      endSpan(child : 0);
      pEstado = 'REVISION';
      pMensaje = 'Importe alto: revision antifraude';
    endif;
  endsl;

  addSpanData(span : 'estado.poliza' : %trim(estPol));
  addSpanData(span : 'resultado' : %trim(pEstado));
  endSpan(span : pRc);
  return;
end-proc;

// Simula la latencia de un sistema externo
dcl-proc esperar;
  dcl-pi *n;
    segundos int(10) const;
  end-pi;
  dcl-s cmd varchar(40);

  cmd = 'DLYJOB DLY(' + %char(segundos) + ')';
  exec sql call qsys2.qcmdexc(:cmd);
end-proc;
