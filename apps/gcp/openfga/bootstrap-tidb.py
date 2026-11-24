#!/usr/bin/env python3
"""Provision the dedicated OpenFGA database on the existing GCP TiDB primary."""
import argparse
import getpass
import json
import os
import re
import secrets
import shutil
import subprocess
import sys

PROJECT = "pingcap-testing-account"
SECRET = "ee-openfga-backend"
DATABASE = "ee_openfga"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="primary SQL hostname")
    parser.add_argument("--port", type=int, default=4000)
    parser.add_argument("--admin", required=True, help="SQL administrator login")
    parser.add_argument("--prefix", default="", help="TiDB Cloud username prefix, without the dot")
    parser.add_argument("--ca", help="CA bundle for the SQL endpoint")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9.-]+", args.host) or not 1 <= args.port <= 65535:
        parser.error("invalid SQL hostname or port")
    if args.prefix and not re.fullmatch(r"[a-zA-Z0-9_-]+", args.prefix):
        parser.error("invalid TiDB Cloud username prefix")
    if not all(shutil.which(cmd) for cmd in ("mysql", "gcloud")):
        parser.error("mysql and gcloud must be on PATH")
    mysql = ["mysql", "--no-defaults", "--protocol=TCP", "--ssl-mode=VERIFY_IDENTITY",
             "--host", args.host, "--port", str(args.port), "--batch", "--skip-column-names"]
    if args.ca:
        mysql += ["--ssl-ca", args.ca]

    def sql(user, password, statement, check=True):
        return subprocess.run(mysql + ["--user", user], input=statement, text=True,
                              env={**os.environ, "MYSQL_PWD": password},
                              stdout=subprocess.DEVNULL, check=check)

    admin_password = getpass.getpass("TiDB admin password: ")
    sql(args.admin, admin_password, "SELECT 1;")
    prefix = args.prefix + "." if args.prefix else ""
    users = {"uri": prefix + "fga_migrate", "runtime_uri": prefix + "fga_runtime"}
    suffix = f"@tcp({args.host}:{args.port})/{DATABASE}?parseTime=true&tls=true"
    gsm = ["gcloud", "--project", PROJECT, "secrets"]
    names = subprocess.check_output(gsm + ["list", "--filter", f"name:{SECRET}",
                                          "--format=value(name)"], text=True).splitlines()
    if SECRET not in [name.rsplit("/", 1)[-1] for name in names]:
        credentials = {key: user + ":" + secrets.token_hex(32) + suffix for key, user in users.items()}
        credentials["keys"] = secrets.token_hex(32)
        subprocess.run(gsm + ["create", SECRET, "--replication-policy=automatic", "--data-file=-"],
                       input=json.dumps(credentials), text=True, check=True)
    else:
        credentials = json.loads(subprocess.check_output(
            gsm + ["versions", "access", "latest", "--secret", SECRET], text=True))

    passwords = {}
    for key, user in users.items():
        match = re.fullmatch(re.escape(user + ":") + r"([0-9a-f]{64})" + re.escape(suffix),
                             credentials.get(key, ""))
        if not match:
            sys.exit("Existing secret differs from the expected bootstrap configuration. Check host and prefix.")
        passwords[key] = match[1]

    sql(args.admin, admin_password,
        f"CREATE DATABASE IF NOT EXISTS {DATABASE} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;")
    for key, user in users.items():
        password = passwords[key]
        account = f"'{user}'@'%'"
        sql(args.admin, admin_password, f"CREATE USER IF NOT EXISTS {account} IDENTIFIED BY '{password}';")
        # Confirm ownership of an existing account before granting it access.
        sql(user, password, "SELECT 1;")
        privileges = "ALL PRIVILEGES" if key == "uri" else "SELECT, INSERT, UPDATE, DELETE"
        sql(args.admin, admin_password, f"GRANT {privileges} ON {DATABASE}.* TO {account};")
        sql(user, password, f"USE {DATABASE}; SELECT 1;")
    print("ee_openfga and both SQL logins are ready. Secret Manager contains ee-openfga-backend.")


if __name__ == "__main__":
    main()
