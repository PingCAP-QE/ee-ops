#!/usr/bin/env python3
"""Offline assertions for the additive broker/ARC HTTPS rollout preparation."""

import os
from pathlib import Path
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


class BrokerHTTPSRolloutTest(unittest.TestCase):
    def test_tls_secret_uses_existing_restricted_store(self):
        secret = load('apps/gcp/github-token-broker/external-secret-tls.yaml')['spec']
        self.assertEqual(secret['secretStoreRef'], {'name': 'ee-gcp-sm', 'kind': 'ClusterSecretStore'})
        self.assertEqual(secret['target']['template']['type'], 'kubernetes.io/tls')
        self.assertEqual(secret['dataFrom'], [{'extract': {'key': 'github_token_broker_tls_json'}}])
        store = load('infrastructure/gcp/external-secrets/post/css-ee-gcp-sm.yaml')['spec']
        allowed = store['conditions'][0]['namespaceSelector']['matchExpressions'][0]['values']
        self.assertIn('github-token-broker', allowed)
        self.assertNotIn('arc-runners', allowed)

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
        inputs = {'CONTEXT': 'test-gcp', 'CA_FILE': str(Path(__file__).resolve()), 'RUNNER_POD': 'test-runner'}
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
        self.assertIn('external-secret-tls.yaml', resources)
        self.assertIn('networkpolicy-arc-https.yaml', resources)
        values = load('apps/gcp/github-token-broker/release.yaml')['spec']['values']
        self.assertNotIn('tls', values)
        self.assertIs(values['server']['tls']['enabled'], False)
        self.assertNotIn('arc-runners', values.get('networkPolicy', {}).get('ingressNamespaces', []))


if __name__ == '__main__':
    unittest.main()
