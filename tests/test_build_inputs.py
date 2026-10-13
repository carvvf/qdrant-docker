"""Regression coverage for shared build resolution without Docker or network access."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
QDRANT_DIGEST = "sha256:" + "a" * 64
UBUNTU_DIGEST = "sha256:" + "b" * 64
SOURCE_COMMIT = "c" * 40
INPUT_NAMES = (
    "QDRANT_UPSTREAM_REF",
    "QDRANT_UPSTREAM_VERSION",
    "QDRANT_UPSTREAM_DIGEST",
    "QDRANT_SOURCE_REF",
    "QDRANT_SOURCE_REVISION",
    "UBUNTU_BASE_IMAGE",
    "UBUNTU_BASE_DIGEST",
    "IMAGE_REF",
)

TOOL_STUB = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state = json.loads(os.environ["BUILD_INPUT_TEST_STATE"])
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["BUILD_INPUT_TEST_CALLS"], "a", encoding="utf-8") as log:
    log.write(json.dumps([tool, *args]) + "\n")
if tool == "git":
    if state.get("missing_tag"):
        sys.exit(2)
    if state["annotated"]:
        print("d" * 40 + "\trefs/tags/v1.19.2")
        print(state["commit"] + "\trefs/tags/v1.19.2^{}")
    else:
        print(state["commit"] + "\trefs/tags/v1.19.2")
elif args[0] == "pull":
    sys.exit(state.get("pull_status", 0))
elif args[:2] == ["image", "inspect"]:
    is_qdrant = args[2].startswith("qdrant/qdrant")
    if "RepoDigests" in args[-1]:
        repo = "qdrant/qdrant" if is_qdrant else "ubuntu"
        digest = state["qdrant_digest"] if is_qdrant else state["ubuntu_digest"]
        print(repo + "@" + digest)
    else:
        print(state["version"] if is_qdrant else state["ubuntu_version"])
elif args[0] != "build":
    sys.exit("Unexpected tool invocation: " + repr(args))
'''


class BuildInputTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir(mode=0o775)
        for name in ("docker", "git"):
            tool = self.bin_dir / name
            tool.write_text(TOOL_STUB, encoding="utf-8")
            tool.chmod(0o775)
        self.calls_path = self.root / "calls.jsonl"
        self.state = {
            "version": "1.19.2",
            "ubuntu_version": "24.04",
            "qdrant_digest": QDRANT_DIGEST,
            "ubuntu_digest": UBUNTU_DIGEST,
            "commit": SOURCE_COMMIT,
            "annotated": True,
        }

    def invoke(self, entrypoint="resolve_build_inputs.sh", **inputs):
        env = {key: value for key, value in os.environ.items() if key not in INPUT_NAMES}
        env.update(inputs)
        env["PATH"] = str(self.bin_dir) + os.pathsep + env["PATH"]
        env["BUILD_INPUT_TEST_STATE"] = json.dumps(self.state)
        env["BUILD_INPUT_TEST_CALLS"] = str(self.calls_path)
        return subprocess.run(
            ["/bin/bash", str(REPO_ROOT / "tools" / entrypoint)],
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        if not self.calls_path.exists():
            return []
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def test_latest_resolves_annotated_tag_and_complete_provenance(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            dict(line.split("=", 1) for line in result.stdout.splitlines()),
            {
                "upstream_ref": "qdrant/qdrant@" + QDRANT_DIGEST,
                "upstream_version": "1.19.2",
                "upstream_digest": QDRANT_DIGEST,
                "source_ref": "v1.19.2",
                "source_revision": SOURCE_COMMIT,
                "ubuntu_base_ref": "ubuntu@" + UBUNTU_DIGEST,
                "ubuntu_base_digest": UBUNTU_DIGEST,
            },
        )
        self.assertIn(["docker", "pull", "--platform", "linux/amd64", "qdrant/qdrant:latest"], self.calls())

    def test_lightweight_tag_resolves_commit(self):
        self.state["annotated"] = False
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("source_revision=" + SOURCE_COMMIT, result.stdout)

    def test_pinned_ci_inputs_keep_immutable_release_signal(self):
        result = self.invoke(
            QDRANT_UPSTREAM_REF="qdrant/qdrant@" + QDRANT_DIGEST,
            QDRANT_UPSTREAM_VERSION="1.19.2",
            QDRANT_UPSTREAM_DIGEST=QDRANT_DIGEST,
            QDRANT_SOURCE_REF="v1.19.2",
            QDRANT_SOURCE_REVISION=SOURCE_COMMIT,
            UBUNTU_BASE_IMAGE="ubuntu@" + UBUNTU_DIGEST,
            UBUNTU_BASE_DIGEST=UBUNTU_DIGEST,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(":latest" in arg for call in self.calls() for arg in call))

    def test_local_build_passes_verified_inputs_and_local_version(self):
        result = self.invoke("build_local_image.sh", QDRANT_SOURCE_REF="v1.19.2")
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in self.calls() if call[:2] == ["docker", "build"])
        for value in (
            "QDRANT_SOURCE_REF=v1.19.2",
            "QDRANT_SOURCE_REVISION=" + SOURCE_COMMIT,
            "QDRANT_UPSTREAM_VERSION=1.19.2",
            "QDRANT_UPSTREAM_DIGEST=" + QDRANT_DIGEST,
            "QDRANT_IMAGE_VERSION=1.19.2-local",
            "UBUNTU_BASE_IMAGE=ubuntu@" + UBUNTU_DIGEST,
            "UBUNTU_BASE_DIGEST=" + UBUNTU_DIGEST,
        ):
            self.assertIn(value, build)
        self.assertIn("--no-cache", build)
        self.assertIn("linux/amd64", build)
        self.assertEqual(build[-3:], ["-t", "qdrant-custom:local", str(REPO_ROOT)])

    def test_mismatched_inputs_abort_before_build(self):
        cases = (
            {"QDRANT_UPSTREAM_VERSION": "1.19.1"},
            {"QDRANT_SOURCE_REVISION": "e" * 40},
            {"QDRANT_UPSTREAM_DIGEST": UBUNTU_DIGEST},
            {"UBUNTU_BASE_DIGEST": QDRANT_DIGEST},
            {"QDRANT_UPSTREAM_VERSION": "1.19.2", "QDRANT_SOURCE_REF": "v1.19.1"},
        )
        for inputs in cases:
            with self.subTest(inputs=inputs):
                # Tagged references let the stub report its configured digest.
                inputs = {"QDRANT_UPSTREAM_REF": "qdrant/qdrant:latest", "UBUNTU_BASE_IMAGE": "ubuntu:24.04", **inputs}
                result = self.invoke("build_local_image.sh", **inputs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Build input error:", result.stderr)
        self.assertFalse(any(call[:2] == ["docker", "build"] for call in self.calls()))

    def test_wrong_ubuntu_release_aborts_before_build(self):
        self.state["ubuntu_version"] = "22.04"
        result = self.invoke("build_local_image.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Ubuntu 24.04 is required", result.stderr)
        self.assertFalse(any(call[:2] == ["docker", "build"] for call in self.calls()))

    def test_missing_tag_aborts_before_build(self):
        self.state["missing_tag"] = True
        result = self.invoke("build_local_image.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ["docker", "build"] for call in self.calls()))

    def test_pull_failure_aborts_before_build(self):
        self.state["pull_status"] = 42
        result = self.invoke("build_local_image.sh")
        self.assertEqual(result.returncode, 42)
        self.assertFalse(any(call[:2] == ["docker", "build"] for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
