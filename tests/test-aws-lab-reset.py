#!/usr/bin/env python3
"""Lokale Prüfungen des AWS-Lab-Restarts. Keine echten Cloud-Zugriffe."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "aws-lab-reset.sh"
SOURCE = SCRIPT.read_text()


class AWSLabResetTests(unittest.TestCase):

    def test_01_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(SCRIPT)],
            capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_02_required_modes(self):
        for mode in ("--check", "--restore", "--deploy"):
            with self.subTest(mode=mode):
                self.assertIn(mode, SOURCE)

    def test_03_dynamic_account_discovery(self):
        self.assertRegex(
            SOURCE,
            r"get-caller-identity"
        )
        self.assertRegex(
            SOURCE,
            r"ACCOUNT"
        )

    def test_04_account_specific_backend(self):
        self.assertIn("cicd-terraform-state-", SOURCE)
        self.assertIn("init", SOURCE)
        self.assertIn("-reconfigure", SOURCE)

    def test_05_terraform_safety(self):
        self.assertIn("terraform.tfstate", SOURCE)
        self.assertRegex(SOURCE, r"(?i)destroy|delete")
        self.assertRegex(SOURCE, r"(?i)confirm|read -r")

    def test_06_github_integration(self):
        self.assertRegex(SOURCE, r"gh (workflow|run)")
        self.assertIn("aws-cicd.yml", SOURCE)
        self.assertIn("GitHubActions-CICD-Role", SOURCE)

    def test_07_deployment(self):
        self.assertIn("ssm", SOURCE)
        self.assertIn("docker", SOURCE)
        self.assertRegex(SOURCE, r"(?i)curl|http")

    def test_08_no_fixed_old_account(self):
        self.assertNotIn("468677424228", SOURCE)

    def test_09_check_uses_mocked_aws(self):
        """Führt --check aus, AWS/Git werden vollständig simuliert."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            fakebin = base / "bin"
            fakebin.mkdir()

            aws_mock = fakebin / "aws"
            aws_mock.write_text("""#!/usr/bin/env bash
case " $* " in
  *" sts get-caller-identity "*)
    echo "123456789012" ;;
  *" s3api head-bucket "*)
    exit 0 ;;
  *" ecr describe-repositories "*)
    exit 0 ;;
  *" ecr describe-images "*)
    echo '{"imageDetails":[]}' ;;
  *" iam get-role "*|*" iam get-open-id-connect-provider "*)
    exit 0 ;;
  *)
    echo "UNERWARTETER AWS-AUFRUF: $*" >&2
    exit 91 ;;
esac
""")
            aws_mock.chmod(0o755)

            git_mock = fakebin / "git"
            git_mock.write_text("""#!/usr/bin/env bash
case " $* " in
  *" remote get-url "*)
    echo "git@github.com:paololaspina/project.git" ;;
  *" status "*)
    exit 0 ;;
  *)
    echo "UNERWARTETER GIT-AUFRUF: $*" >&2
    exit 92 ;;
esac
""")
            git_mock.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = str(fakebin) + os.pathsep + env["PATH"]
            env["AWS_PROFILE"] = "lab"
            env["AWS_REGION"] = "us-east-1"

            result = subprocess.run(
                ["bash", str(SCRIPT), "--check"],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                timeout=30
            )

            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("123456789012", output)
            self.assertNotIn("UNERWARTETER", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
