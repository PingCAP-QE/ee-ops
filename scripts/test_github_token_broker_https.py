#!/usr/bin/env python3
"""Offline assertions for the additive broker/ARC HTTPS rollout preparation."""

import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]

BROKER_HOST = 'github-token-broker.github-token-broker.svc.cluster.local'


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def load_all(path):
    return [doc for doc in yaml.safe_load_all((ROOT / path).read_text()) if doc]


def by_kind(documents, kind):
    matches = [doc for doc in documents if doc['kind'] == kind]
    assert len(matches) == 1, (kind, matches)
    return matches[0]


class BrokerHTTPSRolloutTest(unittest.TestCase):
    def test_leaf_certificate_is_issued_from_the_internal_ca(self):
        cert = load('apps/gcp/github-token-broker/tls.yaml')
        self.assertEqual(cert['kind'], 'Certificate')
        spec = cert['spec']
        self.assertEqual(spec['secretName'], 'github-token-broker-tls')
        self.assertEqual(spec['issuerRef'], {
            'name': 'internal-ca',
            'kind': 'ClusterIssuer',
            'group': 'cert-manager.io',
        })
        # The client verifies this exact origin, so it must stay the first SAN.
        self.assertEqual(spec['dnsNames'][0], BROKER_HOST)
        self.assertEqual(spec['commonName'], BROKER_HOST)
        hours = lambda value: int(str(value).rstrip('h'))
        self.assertLess(hours(spec['renewBefore']), hours(spec['duration']))
        # Re-keying on renewal is safe: the projected volume is swapped atomically.
        self.assertEqual(spec['privateKey']['rotationPolicy'], 'Always')

    def test_internal_ca_and_bundle_are_declarative(self):
        documents = load_all('infrastructure/gcp/cert-manager/post/internal-ca.yaml')
        ca = by_kind(documents, 'Certificate')
        self.assertTrue(ca['spec']['isCA'])
        self.assertEqual(ca['spec']['secretName'], 'internal-ca')
        # The CA Secret must live in the trust namespace trust-manager reads from.
        self.assertEqual(ca['metadata']['namespace'], 'cert-manager')
        # A CA key rotation changes every trust anchor, so it must never be implicit.
        self.assertEqual(ca['spec']['privateKey']['rotationPolicy'], 'Never')

        issuers = {issuer['metadata']['name']: issuer['spec']
                   for issuer in load_all('infrastructure/gcp/cert-manager/post/cluster-issuers.yaml')}
        self.assertEqual(issuers['internal-ca-selfsigned'], {'selfSigned': {}})
        self.assertEqual(issuers['internal-ca'], {'ca': {'secretName': 'internal-ca'}})

        bundle = by_kind(documents, 'Bundle')
        self.assertEqual(bundle['metadata']['namespace'], 'cert-manager')
        self.assertEqual(bundle['spec']['sources'], [
            {'secret': {'name': 'internal-ca', 'key': 'ca.crt'}},
        ])
        self.assertEqual(bundle['spec']['target']['configMap'], {'key': 'ca.crt'})
        self.assertEqual(bundle['spec']['target']['namespaceSelector'], {
            'matchLabels': {'kubernetes.io/metadata.name': 'arc-runners'},
        })

    def test_trust_manager_is_scoped_to_the_runner_bundle(self):
        values = load('infrastructure/gcp/cert-manager/release/trust-manager-release.yaml')['spec']['values']
        self.assertEqual(values['app']['targetNamespaces'], ['arc-runners'])
        self.assertEqual(values['app']['trust']['namespace'], 'cert-manager')
        self.assertTrue(values['secretTargets']['enabled'])
        self.assertEqual(values['secretTargets']['authorizedSecrets'], ['internal-ca'])
        # The system trust package is unrelated to this private CA.
        self.assertFalse(values['defaultPackage']['enabled'])

    def test_cert_manager_addons_are_pinned_and_ordered(self):
        cert_manager = load('infrastructure/gcp/cert-manager/release/release.yaml')['spec']
        trust_manager = load('infrastructure/gcp/cert-manager/release/trust-manager-release.yaml')['spec']
        for release in (cert_manager, trust_manager):
            self.assertEqual(release['chart']['spec']['sourceRef'], {
                'kind': 'HelmRepository',
                'name': 'jetstack',
                'namespace': 'flux-system',
            })
        self.assertTrue(cert_manager['chart']['spec']['version'].startswith('v1.'))
        self.assertTrue(trust_manager['chart']['spec']['version'].startswith('v0.'))
        self.assertEqual(trust_manager['dependsOn'], [{'name': 'cert-manager'}])
        # trust-manager only works once cert-manager's CRDs exist.
        self.assertNotIn('dependsOn', cert_manager)
        self.assertTrue(cert_manager['values']['crds']['enabled'])

    def test_tencent_cloud_deploys_the_same_internal_ca(self):
        release = load('infrastructure/tencentcloud/cert-manager/release/release.yaml')['spec']
        self.assertEqual(release['chart']['spec']['version'],
                         load('infrastructure/gcp/cert-manager/release/release.yaml')['spec']['chart']['spec']['version'])
        self.assertEqual(release['chart']['spec']['sourceRef']['name'], 'jetstack')
        self.assertTrue(release['values']['crds']['enabled'])

        ca = load('infrastructure/tencentcloud/cert-manager/post/internal-ca.yaml')
        self.assertEqual(ca['kind'], 'Certificate')
        self.assertTrue(ca['spec']['isCA'])
        self.assertEqual(ca['spec']['secretName'], 'internal-ca')
        self.assertEqual(ca['metadata']['namespace'], 'cert-manager')
        self.assertEqual(ca['spec']['privateKey']['rotationPolicy'], 'Never')

        issuers = {issuer['metadata']['name'] for issuer
                   in load_all('infrastructure/tencentcloud/cert-manager/post/cluster-issuers.yaml')}
        self.assertEqual(issuers, {'internal-ca', 'internal-ca-selfsigned'})

        # Same Secret name as the GCP cluster so one activation recipe covers both.
        leaf = load('apps/tencentcloud/github-token-broker/tls.yaml')['spec']
        gcp_leaf = load('apps/gcp/github-token-broker/tls.yaml')['spec']
        self.assertEqual(leaf['secretName'], gcp_leaf['secretName'])
        self.assertEqual(leaf['dnsNames'], gcp_leaf['dnsNames'])
        self.assertEqual(leaf['issuerRef'], gcp_leaf['issuerRef'])

        # No consumer there yet, so no trust distributor is installed.
        self.assertFalse((ROOT / 'infrastructure/tencentcloud/cert-manager/release/trust-manager-release.yaml').exists())
        resources = load('apps/tencentcloud/github-token-broker/kustomization.yaml')['resources']
        self.assertIn('tls.yaml', resources)

    def test_helm_release_custom_resources_are_applied_after_the_crds(self):
        """The CRs a chart owns must not share a kustomization with its HelmRelease.

        kustomize-controller server-side dry-runs the whole set before applying
        anything, so a Certificate in the same set as the HelmRelease that
        installs cert-manager's CRDs deadlocks with
        `no matches for kind "Certificate" in version "cert-manager.io/v1"`.
        """
        for cloud in ('gcp', 'tencentcloud'):
            base = f'infrastructure/{cloud}/cert-manager'
            parent = load(f'{base}/kustomization.yaml')
            self.assertEqual(parent['resources'], ['namespace.yaml', 'release.yaml', 'post.yaml'])
            # A kustomize namespace would rename Namespace/cert-manager and stamp
            # cluster-scoped custom resources.
            self.assertNotIn('namespace', parent)

            release = load(f'{base}/release.yaml')
            post = load(f'{base}/post.yaml')
            self.assertEqual(release['kind'], 'Kustomization')
            self.assertEqual(release['metadata']['name'], 'cert-manager-release')
            self.assertEqual(post['spec']['dependsOn'], [{'name': 'cert-manager-release'}])
            checked = {check['name'] for check in release['spec']['healthChecks']}
            self.assertIn('cert-manager', checked)

            release_kinds = set()
            for name in load(f'{base}/release/kustomization.yaml')['resources']:
                release_kinds |= {doc['kind'] for doc in load_all(f'{base}/release/{name}')}
            self.assertEqual(release_kinds, {'HelmRelease'})

            post_kinds = set()
            for name in load(f'{base}/post/kustomization.yaml')['resources']:
                post_kinds |= {doc['kind'] for doc in load_all(f'{base}/post/{name}')}
            self.assertLessEqual(post_kinds, {'Certificate', 'ClusterIssuer', 'Bundle'})

    def test_arc_network_grants_only_https(self):
        policy = load('apps/gcp/github-token-broker/networkpolicy-arc-https.yaml')['spec']
        self.assertEqual(policy['podSelector']['matchLabels'], {
            'app.kubernetes.io/name': 'github-token-broker',
            'app.kubernetes.io/instance': 'github-token-broker',
        })
        release = load('apps/gcp/github-token-broker/release.yaml')['spec']
        self.assertEqual(release['releaseName'], policy['podSelector']['matchLabels']['app.kubernetes.io/instance'])
        for override in ('nameOverride', 'fullnameOverride'):
            self.assertFalse(release['values'].get(override))
        self.assertEqual(policy['ingress'], [{
            'from': [{'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'arc-runners'}}}],
            'ports': [{'protocol': 'TCP', 'port': 8443}],
        }])

    def test_arc_network_port_matches_activation_template(self):
        runbook = (ROOT / 'docs/github-token-broker-https.md').read_text()
        activation = yaml.safe_load(runbook.split('```yaml\n', 1)[1].split('```', 1)[0])
        tls_port = activation['spec']['values']['server']['tls']['port']
        policy = load('apps/gcp/github-token-broker/networkpolicy-arc-https.yaml')['spec']
        self.assertEqual(policy['ingress'][0]['ports'][0]['port'], tls_port)

    def test_runner_mount_is_public_ca_only_and_readonly(self):
        pod = load('apps/gcp/acr-runners/release-2-runners-pingcap-qe.yaml')['spec']['values']['template']['spec']
        volume = next(v for v in pod['volumes'] if v['name'] == 'github-token-broker-ca')
        self.assertNotIn('secret', volume)
        self.assertEqual(volume['configMap'], {
            'name': 'github-token-broker-ca', 'optional': True,
        })
        # The mounted ConfigMap must be the one the Bundle distributes.
        bundle = by_kind(load_all('infrastructure/gcp/cert-manager/post/internal-ca.yaml'), 'Bundle')
        self.assertEqual(bundle['metadata']['name'], volume['configMap']['name'])
        self.assertEqual(
            bundle['spec']['target']['namespaceSelector']['matchLabels']['kubernetes.io/metadata.name'],
            'arc-runners',
        )
        runner = next(c for c in pod['containers'] if c['name'] == 'runner')
        mount = next(v for v in runner['volumeMounts'] if v['name'] == volume['name'])
        self.assertTrue(mount['readOnly'])
        self.assertNotIn('subPath', mount)
        env = {e['name']: e['value'] for e in runner['env']}
        self.assertEqual(env['GITINSIGHT_BROKER_CA_FILE'], mount['mountPath'] + '/ca.crt')
        self.assertNotIn('SSL_CERT_FILE', env)
        self.assertNotIn('REQUESTS_CA_BUNDLE', env)

    def test_operator_commands_reject_missing_or_empty_inputs(self):
        runbook = (ROOT / 'docs/github-token-broker-https.md').read_text()
        blocks = [part.split('```', 1)[0] for part in runbook.split('```bash\n')[1:]]
        commands = [block for block in blocks if 'kubectl --context' in block]
        self.assertEqual(len(commands), 3)
        inputs = {'CONTEXT': 'test-gcp', 'RUNNER_POD': 'test-runner'}
        for index, command in enumerate(commands):
            for variable in inputs:
                if variable not in command:
                    continue
                for value in (None, ''):
                    with self.subTest(block=index, variable=variable, value=value):
                        env = {**os.environ, **inputs}
                        if value is None:
                            env.pop(variable)
                        else:
                            env[variable] = value
                        result = subprocess.run(
                            ['bash', '-c', 'kubectl() { echo unexpected-kubectl >&2; return 99; }\n' + command],
                            env=env, capture_output=True, text=True,
                        )
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(variable, result.stderr)
                        self.assertNotIn('unexpected-kubectl', result.stderr)

    def test_http_stage_pins_published_tls_capable_release(self):
        release = load('apps/gcp/github-token-broker/release.yaml')['spec']
        self.assertEqual(release['chart']['spec']['version'], '0.2.0')
        self.assertEqual(release['values']['image'], {
            'repository': 'ghcr.io/pingcap-qe/ee-apps/github-token-broker',
            'tag': 'v2026.11.8-19-g04ea8c8',
        })
        self.assertIs(release['values']['server']['tls']['enabled'], False)

    def test_resources_are_wired_without_premature_tls_activation(self):
        resources = load('apps/gcp/github-token-broker/kustomization.yaml')['resources']
        self.assertIn('tls.yaml', resources)
        self.assertNotIn('external-secret-tls.yaml', resources)
        self.assertIn('networkpolicy-arc-https.yaml', resources)
        values = load('apps/gcp/github-token-broker/release.yaml')['spec']['values']
        self.assertNotIn('tls', values)
        self.assertIs(values['server']['tls']['enabled'], False)
        self.assertNotIn('arc-runners', values.get('networkPolicy', {}).get('ingressNamespaces', []))

    def test_no_manual_secret_manager_provisioning_remains(self):
        """The TLS leaf must not depend on a hand-created Secret Manager object."""
        self.assertFalse((ROOT / 'apps/gcp/github-token-broker/external-secret-tls.yaml').exists())
        for directory in ('apps/gcp', 'apps/tencentcloud', 'infrastructure/gcp', 'infrastructure/tencentcloud'):
            for manifest in (ROOT / directory).rglob('*.yaml'):
                self.assertNotIn('github_token_broker_tls_json', manifest.read_text(), manifest)
        for cluster in ('gcp', 'tencentcloud'):
            cluster_sources = load(f'clusters/{cluster}/sources/kustomization.yaml')['resources']
            self.assertIn('helm-repo-jetstack.yaml', cluster_sources)
            repository = load(f'clusters/{cluster}/sources/helm-repo-jetstack.yaml')
            self.assertEqual(repository['spec']['url'], 'https://charts.jetstack.io')


if __name__ == '__main__':
    unittest.main()
