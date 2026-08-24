#!/usr/bin/env python3
"""One-time migration: finalize hot-copied JENKINS_HOME for GitOps Helm + JCasC.

Removes:
  - <clouds> from config.xml (stale Kubernetes cloud persisted on PVC)
  - init.groovy.d/00-cbg-manual-verify.groovy (manual migration script that
    recreates cloud with wrong jenkins-cbg URLs on every startup)
  - casc_configs/ on PVC (stale jenkins-gitee-era CasC; runtime uses emptyDir)

After this, JCasC configScript kubernetes-cloud is the sole cloud source.
Run once with jenkins-cbg StatefulSet scaled to 0.
"""
from __future__ import annotations

import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HOME = Path("/var/jenkins_home")
CFG = HOME / "config.xml"
LEGACY_GROOVY = HOME / "init.groovy.d" / "00-cbg-manual-verify.groovy"
LEGACY_CASC = HOME / "casc_configs"


def strip_clouds(cfg: Path) -> bool:
    if not cfg.is_file():
        print(f"skip: {cfg} not found")
        return False
    backup = cfg.with_suffix(cfg.suffix + ".bak-finalize-hotcopy")
    shutil.copy2(cfg, backup)
    print(f"backup: {backup}")
    tree = ET.parse(cfg)
    root = tree.getroot()
    clouds = root.find("clouds")
    if clouds is None:
        print("config.xml: no <clouds> element")
        return False
    root.remove(clouds)
    tree.write(cfg, encoding="UTF-8", xml_declaration=True)
    print("config.xml: removed <clouds>")
    return True


def main() -> int:
    changed = False
    changed = strip_clouds(CFG) or changed

    if LEGACY_GROOVY.is_file():
        backup = LEGACY_GROOVY.with_suffix(".groovy.bak-finalize-hotcopy")
        shutil.copy2(LEGACY_GROOVY, backup)
        LEGACY_GROOVY.unlink()
        print(f"removed: {LEGACY_GROOVY}")
        print(f"backup: {backup}")
        changed = True
    else:
        print(f"skip: {LEGACY_GROOVY} not present")

    if LEGACY_CASC.is_dir():
        shutil.rmtree(LEGACY_CASC)
        print(f"removed stale PVC dir: {LEGACY_CASC}")
        changed = True
    else:
        print(f"skip: {LEGACY_CASC} not present")

    if not changed:
        print("nothing changed; already finalized")
    else:
        print("finalize complete; start controller so JCasC creates jenkins-cbg-k8s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
