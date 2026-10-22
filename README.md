# Seguros – IBM i

A small insurance-policy app that spans two platforms:

```
Browser ──> seguros-web (Node.js, OpenShift) ──> seguros-api (Node.js on IBM i, port 8090) ──> SEGPOL / SEGAPI (ILE RPG) ──> Db2 for i
```

| Folder | Content |
|---|---|
| `ocp-web/` | Web UI (Node.js + Express), `Dockerfile` (UBI 9 Node.js 20), Kubernetes manifests in `k8s/` (Deployment, Service, Route, load generator) |
| `api/` | REST API that runs in PASE on IBM i and calls the RPG programs |
| `qrpglesrc/` | ILE RPG sources (`SEGPOL` 5250 inquiry, `SEGAPI` API program, `SEGVAL`, `SEGLOAD`) |
| `qddssrc/` | Display file for `SEGPOL` |
| `sql/` | Db2 for i schema and demo data |

The container image is published as `ghcr.io/grvuolo/seguros-web`.

Both Node.js tiers and the RPG programs are instrumented with IBM Instana, so a single trace covers the web tier, the API and the RPG call.
