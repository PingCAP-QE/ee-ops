# GCP OpenFGA and authzd

The two services share the dedicated ee-authz namespace. Restrict pod creation,
deployment updates, exec and port-forward in this namespace to infrastructure
administrators. NetworkPolicy selectors and the administration service account
rely on this namespace boundary. There is no Gateway attachment. The authzd
reader reaches only the check proxy. Metrics are scraped by GKE Managed
Prometheus from the private pod port.

## Database and bootstrap

1. On the existing GCP TiDB cluster, provision a dedicated database named
   `ee_openfga` and separate migration and runtime accounts scoped to that database. The OpenFGA
   migration job needs schema DDL and the server needs DML. Configure TLS with
   server verification. Confirm the TiDB cluster's backup schedule, retention,
   and a successful backup before the first migration. Record the restore owner
   and rehearse restoring to a separate cluster before upgrades.
2. Create the Secret Manager JSON secret `ee-openfga-backend` with string keys
   `uri` (Go MySQL DSN for that database, including `parseTime=true&tls=true`)
   (migration account), `runtime_uri` (DML account), and `keys` (a generated OpenFGA API key). Grant the existing External Secrets
   controller read access. Keep database and API credentials out of Git.
3. Flux installs chart 0.4.3, which runs the OpenFGA migration job against TiDB
   through the MySQL driver. Check the migration Job and HelmRelease Ready
   condition before publishing a model. Verify migration compatibility on the
   target TiDB version. An application rollback cannot reverse database DDL.
4. From a trusted administration workload labeled `app: openfga-admin` running
   as the `openfga-admin` service account, create a store once and write the
   reviewed authorization model to it with the OpenFGA CLI. Use the internal
   API at http://openfga:8080 with token authentication. Retain the store ID,
   immutable model ID and reviewed model revision. Reuse the store on upgrade.
5. Populate `ee-authzd-config` in GCP Secret Manager. Provide string properties
   `AUTHZD_OPENFGA_STORE_ID`, `AUTHZD_OPENFGA_MODEL_ID`,
   `AUTHZD_OPENFGA_API_TOKEN` (the API key), `AUTHZD_CREDENTIAL_MODES` (JSON)
   and `registry.json` (reviewed registry JSON). Restart authzd after changing
   configuration supplied via environment variables or the startup registry.
6. Verify both deployments, the migration job, PDB and external secrets in
   ee-authz. Check health, readiness and metrics on authzd port 9003 via an
   administrator port-forward. Verify the collector can scrape, an unrelated
   namespace cannot reach the services and the reader cannot write tuples.
   Capture evidence before attaching any route.

For rollback, revert the workload revision, retain the store and pin the
previous compatible model ID. If a schema migration prevents downgrade,
restore the pre-upgrade backup to an isolated TiDB cluster, verify the store
and tuples, and switch the DSN under the database owner's change procedure.
