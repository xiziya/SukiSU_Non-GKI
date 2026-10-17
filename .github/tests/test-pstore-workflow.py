#!/usr/bin/env python3
"""Behavioral coverage for pstore helpers and both Actions entrypoints."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
HELPER = REPO / '.github/scripts/configure-pstore.sh'


class PstoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sukisu-pstore-test-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.root = self.work / 'kernel'
        self.config = self.root / 'out/.config'
        self.config.parent.mkdir(parents=True)
        self.envfile = self.work / 'github.env'
        self.envfile.touch()
        self.artifact = self.work / 'artifacts'
        self.env = dict(os.environ, KERNEL_ROOT=str(self.root), OUT_DIR='out',
                        ENABLE_PSTORE_DEBUG='true', ARCH='arm64',
                        GITHUB_ENV=str(self.envfile), ARTIFACT_DIR=str(self.artifact))
        self.env.pop('PSTORE_DEBUG_STATUS', None)
        self.config.write_text('CONFIG_PSTORE=m\nCONFIG_PSTORE_RAM=m\n'
                               'CONFIG_PSTORE_FTRACE=y\nCONFIG_PANIC_TIMEOUT=7\n'
                               'CONFIG_SECURITY_SELINUX=y\nCONFIG_QCA_CLD_WLAN=y\n')

    def fixture(self, backend='PSTORE_RAM', pmsg=True):
        folder = self.root / 'fs/pstore'
        folder.mkdir(parents=True, exist_ok=True)
        keys = ['PRINTK', 'PSTORE', 'PSTORE_CONSOLE']
        if backend:
            keys.append(backend)
        if pmsg:
            keys.append('PSTORE_PMSG')
        (folder / 'Kconfig').write_text('\n'.join('config ' + key for key in keys) + '\n')

    def run_helper(self, mode, success=True):
        result = subprocess.run(['bash', str(HELPER), mode], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        # Emulate propagation to a following Actions step, including repeated keys.
        for line in self.envfile.read_text().splitlines():
            key, value = line.split('=', 1)
            self.env[key] = value
        return result

    def test_disabled_is_noop(self):
        original = self.config.read_bytes()
        self.env['ENABLE_PSTORE_DEBUG'] = 'false'
        for mode in ('prepare', 'verify', 'report'):
            self.run_helper(mode)
        self.assertEqual(original, self.config.read_bytes())
        self.assertEqual('', self.envfile.read_text())
        self.assertFalse(self.artifact.exists())

    def test_modern_builtin_idempotent_and_report(self):
        self.fixture()
        self.run_helper('prepare')
        first = self.config.read_bytes()
        self.run_helper('prepare')
        self.assertEqual(first, self.config.read_bytes())
        for key in ('PRINTK', 'PSTORE', 'PSTORE_RAM', 'PSTORE_CONSOLE', 'PSTORE_PMSG'):
            self.assertIn('CONFIG_' + key + '=y\n', self.config.read_text())
        for preserved in ('CONFIG_PSTORE_FTRACE=y', 'CONFIG_PANIC_TIMEOUT=7',
                          'CONFIG_SECURITY_SELINUX=y', 'CONFIG_QCA_CLD_WLAN=y'):
            self.assertIn(preserved, self.config.read_text())
        self.run_helper('verify')
        self.assertEqual('config-verified', self.env['PSTORE_DEBUG_STATUS'])
        dts = self.root / 'arch/arm64/boot/dts/vendor'
        dts.mkdir(parents=True)
        (dts / 'valid.dtsi').write_text('ramoops { compatible =\n "ramoops"; status = "disabled"; };')
        (dts / 'comment.dts').write_text('/* compatible = "ramoops"; */\n// compatible = "ramoops";\n')
        self.run_helper('report')
        diag = self.artifact / 'pstore-debug'
        self.assertEqual('source-candidates-only', self.env['PSTORE_DTS_STATUS'])
        self.assertEqual('enabled-by-existing-config', self.env['PSTORE_FTRACE_STATUS'])
        self.assertEqual('arch/arm64/boot/dts/vendor/valid.dtsi\n',
                         (diag / 'ramoops-dts-candidates.txt').read_text())
        self.assertEqual(self.config.read_bytes(), (diag / 'kernel.config').read_bytes())
        self.assertTrue((diag / 'collect-pstore.sh').is_file())
        self.assertIn('UNVERIFIED', (diag / 'status.txt').read_text())
        subprocess.run(['bash', str(REPO / '.github/scripts/generate-build-report.sh')],
                       env=self.env, check=True, capture_output=True)
        report = (self.artifact / 'build-report.md').read_text()
        self.assertIn('请求=true; 配置=config-verified', report)
        self.assertIn('PSTORE_RAM=builtin', report)
        self.assertIn('pstore-debug/kernel.config', report)
        self.assertIn('pstore 平台预留内存来源', report)

    def test_legacy_no_pmsg(self):
        self.fixture(backend='RAMOOPS', pmsg=False)
        result = self.run_helper('prepare')
        self.assertIn('lacks PSTORE_PMSG', result.stderr)
        self.assertIn('CONFIG_RAMOOPS=y', self.config.read_text())
        self.assertNotIn('CONFIG_PSTORE_PMSG=y', self.config.read_text())
        self.run_helper('verify')
        self.run_helper('report')
        self.assertEqual('RAMOOPS=builtin', self.env['PSTORE_BACKEND_STATUS'])
        self.assertEqual('no-source-node-found-check-device-dt', self.env['PSTORE_DTS_STATUS'])

    def test_polaris_platform_cmdline_is_added_and_verified(self):
        self.fixture()
        self.env['CODENAME'] = 'polaris'
        self.config.write_text(self.config.read_text() +
                               'CONFIG_MACH_XIAOMI_D5X=n\n'
                               'CONFIG_MACH_XIAOMI_SDM845=n\n'
                               'CONFIG_CMDLINE="console=ttyMSM0,115200n8"\n')
        (self.root / 'fs/pstore/ram.c').write_text(
            'early_param("ramoops_memreserve", ramoops_memreserve);\n'
            'ramoops_data.mem_address = 0xB0000000;\n'
            'core_initcall(msm_register_ramoops_device);\n')
        arm64 = self.root / 'arch/arm64'
        arm64.mkdir(parents=True)
        (arm64 / 'Kconfig').write_text('config CMDLINE\nconfig CMDLINE_EXTEND\n'
                                       'config MACH_XIAOMI_D5X\n'
                                       'config MACH_XIAOMI_SDM845\n')

        self.run_helper('prepare')
        configured = self.config.read_text()
        self.assertIn('CONFIG_CMDLINE="console=ttyMSM0,115200n8 ramoops_memreserve=4M"',
                      configured)
        self.assertIn('CONFIG_CMDLINE_EXTEND=y\n', configured)
        self.assertIn('CONFIG_MACH_XIAOMI_D5X=y\n', configured)
        self.assertIn('CONFIG_MACH_XIAOMI_SDM845=y\n', configured)
        self.assertEqual('polaris-source-platform-driver',
                         self.env['PSTORE_PLATFORM_PROVISIONING_STATUS'])
        self.assertEqual('added-4M-platform-default', self.env['PSTORE_RAMOOPS_CMDLINE_STATUS'])

        self.run_helper('prepare')
        self.assertEqual(1, self.config.read_text().count('ramoops_memreserve=4M'))
        self.run_helper('verify')
        self.assertEqual('verified', self.env['PSTORE_RAMOOPS_CMDLINE_STATUS'])

    def test_other_codename_does_not_receive_polaris_parameter(self):
        self.fixture()
        self.env['CODENAME'] = 'dipper'
        self.config.write_text(self.config.read_text() + 'CONFIG_MACH_XIAOMI_SDM845=y\n')
        (self.root / 'fs/pstore/ram.c').write_text(
            'early_param("ramoops_memreserve", ramoops_memreserve);\n'
            'ramoops_data.mem_address = 0xB0000000;\n'
            'core_initcall(msm_register_ramoops_device);\n')
        self.run_helper('prepare')
        self.assertNotIn('ramoops_memreserve=', self.config.read_text())
        self.assertEqual('not-injected', self.env['PSTORE_RAMOOPS_CMDLINE_STATUS'])

    def test_polaris_rejects_shared_sdm845_without_d5x_board_selector(self):
        self.fixture()
        self.env['CODENAME'] = 'polaris'
        self.config.write_text(self.config.read_text() +
                               'CONFIG_MACH_XIAOMI_SDM845=y\n'
                               'CONFIG_CMDLINE="console=ttyMSM0"\n')
        (self.root / 'fs/pstore/ram.c').write_text(
            'early_param("ramoops_memreserve", ramoops_memreserve);\n'
            'ramoops_data.mem_address = 0xB0000000;\n'
            'core_initcall(msm_register_ramoops_device);\n')
        arm64 = self.root / 'arch/arm64'
        arm64.mkdir(parents=True)
        (arm64 / 'Kconfig').write_text('config CMDLINE\nconfig CMDLINE_EXTEND\n'
                                       'config MACH_XIAOMI_SDM845\n')

        result = self.run_helper('prepare', success=False)
        self.assertIn('no MACH_XIAOMI_D5X board selector', result.stderr)

    def test_missing_backend_does_not_mutate_config(self):
        self.fixture(backend=None)
        before = self.config.read_bytes()
        self.run_helper('prepare', success=False)
        self.assertEqual(before, self.config.read_bytes())
        self.run_helper('report')
        self.assertEqual('backend-unavailable', self.env['PSTORE_DEBUG_STATUS'])

    def test_missing_console_fails_before_mutation(self):
        self.fixture()
        kconfig = self.root / 'fs/pstore/Kconfig'
        kconfig.write_text(kconfig.read_text().replace('config PSTORE_CONSOLE\n', ''))
        before = self.config.read_bytes()
        self.run_helper('prepare', success=False)
        self.assertEqual(before, self.config.read_bytes())
        self.assertEqual('symbol-unavailable', self.env['PSTORE_DEBUG_STATUS'])

    def test_rejected_config_and_failure_diagnostics(self):
        self.fixture()
        self.run_helper('prepare')
        self.config.write_text(self.config.read_text().replace('CONFIG_PSTORE_RAM=y',
                                                               '# CONFIG_PSTORE_RAM is not set'))
        self.run_helper('verify', success=False)
        self.run_helper('report')
        self.assertEqual('config-rejected', self.env['PSTORE_DEBUG_STATUS'])
        self.assertEqual('PSTORE_RAM=not-builtin', self.env['PSTORE_BACKEND_STATUS'])

    def test_early_failure_report_without_kernel(self):
        self.env.pop('KERNEL_ROOT')
        self.run_helper('report')
        self.assertTrue((self.artifact / 'pstore-debug/README.md').is_file())
        self.assertIn('No generated', (self.artifact / 'pstore-debug/pstore-config.txt').read_text())

    def test_kconfig_unavailable_in_tree(self):
        self.run_helper('prepare', success=False)
        self.assertEqual('backend-unavailable', self.env['PSTORE_DEBUG_STATUS'])

    def test_final_verification_after_all_olddefconfig_passes(self):
        text = (REPO / '.github/scripts/configure-kernel.sh').read_text()
        self.assertLess(text.index('configure-pstore.sh" prepare'), text.index('olddefconfig\n'))
        self.assertGreater(text.index('configure-pstore.sh" verify'), text.rindex('olddefconfig\n'))

    def test_workflow_contract(self):
        import yaml  # Ubuntu python3-yaml; required for workflow schema checks.
        configs = []
        for language in ('Eng', 'Zh_CN'):
            path = REPO / f'.github/workflows/build-custom-kernel-{language}.yml'
            data = yaml.safe_load(path.read_text())
            trigger = data.get('on', data.get(True))  # PyYAML YAML 1.1 "on".
            inputs = trigger['workflow_dispatch']['inputs']
            self.assertEqual(25, len(inputs))
            self.assertFalse(inputs['enable_pstore_debug']['default'])
            env = data['jobs']['build']['env']
            self.assertEqual('arm64', env['ARCH'])
            self.assertEqual('${{ inputs.enable_pstore_debug }}', env['ENABLE_PSTORE_DEBUG'])
            steps = data['jobs']['build']['steps']
            step = next(s for s in steps if s.get('run') == 'bash .github/scripts/configure-pstore.sh report')
            self.assertEqual('always() && inputs.enable_pstore_debug', step['if'])
            report = next(s for s in steps if s.get('run') == 'bash .github/scripts/generate-build-report.sh')
            self.assertLess(steps.index(step), steps.index(report))
            configs.append({key: {k: v for k, v in value.items() if k != 'description'}
                            for key, value in inputs.items()})
        self.assertEqual(*configs)
        template = yaml.safe_load((REPO / '.github/workflows/temple/build-custom-kernel-example.yml').read_text())
        trigger = template.get('on', template.get(True))
        self.assertIn('enable_pstore_debug', trigger['workflow_dispatch']['inputs'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
