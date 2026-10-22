#!/QOpenSys/pkgs/bin/bash
# Arranca seguros-api en el IBM i. Lanzar como trabajo batch:
#   SBMJOB CMD(QSH CMD('exec /QOpenSys/pkgs/bin/bash /home/ADMIN/seguros-api/start.sh')) JOB(SEGURAPI) JOBQ(QUSRNOMAX)
# Parar: ENDJOB JOB(SEGURAPI) OPTION(*CNTRLD)   (o matar el proceso node)
export PATH=/QOpenSys/pkgs/lib/nodejs20/bin:/QOpenSys/pkgs/bin:/QOpenSys/usr/bin:$PATH
cd "$(dirname "$0")"
mkdir -p logs
exec node server.js >> logs/seguros-api.log 2>&1
