"""Offline tests for weft.sh workspace guards, flags, setup/test isolation, and exit codes.

All fixtures use invented names and run against temporary copies of weft.sh / lib.sh with a fake
`terraform` on PATH. No cloud call, no real .env, no state, no lock."""
from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
FAKE = """#!/usr/bin/env bash
printf 'TF_WORKSPACE=%s %s\\n' "${TF_WORKSPACE:-}" "$*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
  "workspace show")
    echo "${TF_WORKSPACE:-$(cat "$FAKE_WS_FILE" 2>/dev/null || echo default)}"
    exit 0 ;;
  "workspace select")
    if [ -n "${TF_WORKSPACE:-}" ]; then
      echo "Error: TF_WORKSPACE is set" >&2
      exit 1
    fi
    ws="${@: -1}"
    case "$ws" in
      *" "*|*"!"*) echo "Invalid workspace name: $ws" >&2; exit 1 ;;
    esac
    printf '%s\\n' "$ws" > "$FAKE_WS_FILE"
    exit 0 ;;
  "workspace delete")
    if [ -n "${TF_WORKSPACE:-}" ]; then
      echo "Error: TF_WORKSPACE is set" >&2
      exit 1
    fi
    exit 0 ;;
  "output -raw")
    printf '192.0.2.1'
    exit 0 ;;
  "apply "*)
    if [ "${FAKE_APPLY_FAIL:-0}" = "1" ]; then
      echo "simulated apply failure" >&2
      exit 2
    fi
    exit 0 ;;
esac
exit 0
"""


@pytest.fixture
def weft(tmp_path):
    for name in ("weft.sh", "lib.sh"):
        shutil.copy(HERE / name, tmp_path / name)
    (tmp_path / ".terraform").mkdir()
    (tmp_path / ".env").write_text("TF_VAR_cloud=vultr\n")
    (tmp_path / "terraform.tfvars").write_text('hostname = "default-box.example.invalid"\n')
    (tmp_path / "workspaces").mkdir()
    (tmp_path / "setup.sh").write_text("#!/usr/bin/env bash\necho setup-ran\n")
    (tmp_path / "setup.sh").chmod(0o755)
    (tmp_path / "smoke-test.sh").write_text(
        "#!/usr/bin/env bash\nprintf 'smoke TF_WORKSPACE=%s args=%s\\n' \"${TF_WORKSPACE:-}\" \"$*\"\n"
    )
    (tmp_path / "smoke-test.sh").chmod(0o755)
    bindir = tmp_path / "fakebin"
    bindir.mkdir()
    fake = bindir / "terraform"
    fake.write_text(FAKE)
    fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "terraform.log"
    ws_file = tmp_path / "selected_ws"
    ws_file.write_text("default\n")

    def run(cmd, *args, workspace=None, selected=None, extra_env=None):
        ws_file.write_text((selected or "default") + "\n")
        env = {k: v for k, v in os.environ.items() if k not in ("TF_WORKSPACE", "WEFT_WORKSPACE")}
        env.update(PATH=f"{bindir}:{env.get('PATH', '')}", FAKE_LOG=str(log), FAKE_WS_FILE=str(ws_file))
        if workspace:
            env["WEFT_WORKSPACE"] = workspace
        if extra_env:
            env.update(extra_env)
        p = subprocess.run(
            ["bash", str(tmp_path / "weft.sh"), cmd, *args],
            cwd=tmp_path,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )
        raw_lines = log.read_text().splitlines() if log.exists() else []
        calls = [l.split(" ", 1)[1] for l in raw_lines if l.split(" ", 1)[1].split()[:1] == [cmd]]
        log.unlink(missing_ok=True)
        return p.returncode, p.stdout + p.stderr, calls

    run.root = tmp_path
    run.ws_file = ws_file
    return run


@pytest.mark.parametrize("cmd", ["plan", "apply", "destroy"])
def test_a_workspace_without_its_tfvars_is_refused_before_terraform_runs(weft, cmd):
    code, out, calls = weft(cmd, workspace="ws-alpha")
    assert code != 0 and "Refusing" in out and "workspaces/ws-alpha.tfvars" in out
    assert calls == []
    # a workspace selected in Terraform (not named by WEFT_WORKSPACE) is held the same way
    code, out, calls = weft(cmd, selected="ws-alpha")
    assert code != 0 and "Refusing" in out and calls == []


@pytest.mark.parametrize("cmd", ["plan", "apply", "destroy"])
def test_a_workspace_with_its_tfvars_gets_it_and_default_runs_plain(weft, cmd):
    (weft.root / "workspaces/ws-alpha.tfvars").write_text('hostname = "box-alpha.example.invalid"\n')
    code, out, calls = weft(cmd, workspace="ws-alpha")
    assert code == 0, out
    assert calls == [f"{cmd} -var-file=workspaces/ws-alpha.tfvars"]
    code, out, calls = weft(cmd)
    assert code == 0, out
    assert calls == [cmd]


def test_explicit_var_file_and_two_word_var_hostname_are_accepted(weft):
    code, out, calls = weft("plan", "-var-file=other.tfvars", workspace="ws-alpha")
    assert code == 0, out
    assert calls == ["plan -var-file=other.tfvars"]

    # Two-word `-var hostname=...` form (e.g. `-var "hostname=box-beta"`) must also be accepted
    for cmd in ("plan", "apply", "destroy"):
        code, out, calls = weft(cmd, "-var", "hostname=box-beta.example.invalid", workspace="ws-alpha")
        assert code == 0, out
        assert calls == [f"{cmd} -var hostname=box-beta.example.invalid"]
        # another two-word -var names no server, so the workspace is still refused
        code, out, calls = weft(cmd, "-var", "region=ewr", workspace="ws-alpha")
        assert code != 0 and "Refusing" in out and calls == []


def test_setup_refuses_non_default_workspace_and_test_uses_isolated_smoke_workspace(weft):
    # setup in a non-default workspace, selected or named by WEFT_WORKSPACE, must refuse
    for kw in ({"selected": "ws-alpha"}, {"workspace": "ws-alpha"}):
        code, out, _ = weft("setup", **kw)
        assert code != 0 and "Refusing 'setup'" in out and "setup-ran" not in out

    # setup in default workspace is allowed
    code, out, _ = weft("setup", selected="default")
    assert code == 0 and "setup-ran" in out

    # test from a non-default workspace runs smoke-test.sh under TF_WORKSPACE=weft-smoke
    # and preserves the originally selected workspace
    for kw in ({"selected": "ws-alpha"}, {"workspace": "ws-alpha", "selected": "ws-alpha"}):
        code, out, _ = weft("test", **kw)
        assert code == 0, out
        assert "smoke TF_WORKSPACE=weft-smoke" in out
        assert weft.ws_file.read_text().strip() == "ws-alpha"


def test_workspace_current_ensure_selection_invalid_name_and_apply_exit_code(weft):
    # workspace current honors WEFT_WORKSPACE
    code, out, _ = weft("workspace", "current", workspace="ws-fixture")
    assert code == 0 and out.strip() == "ws-fixture"

    # workspace ensure preserves selected workspace even when WEFT_WORKSPACE is set
    code, out, _ = weft("workspace", "ensure", "ws-beta", workspace="ws-beta", selected="ws-alpha")
    assert code == 0, out
    assert weft.ws_file.read_text().strip() == "ws-alpha"

    # workspace ensure with an invalid name must exit non-zero
    code, out, _ = weft("workspace", "ensure", "bad name", selected="ws-alpha")
    assert code != 0, out
    assert weft.ws_file.read_text().strip() == "ws-alpha"

    # workspace delete preserves selected workspace even when WEFT_WORKSPACE is set
    code, out, _ = weft("workspace", "delete", "ws-beta", workspace="ws-beta", selected="ws-alpha")
    assert code == 0, out
    assert weft.ws_file.read_text().strip() == "ws-alpha"

    # failed apply must return terraform's non-zero exit code instead of masking it with server_ip output
    code, out, _ = weft("apply", extra_env={"FAKE_APPLY_FAIL": "1"})
    assert code == 2, out


def test_noninteractive_unconfigured_refuses_setup(tmp_path):
    fake_weft = tmp_path / "unconfigured"
    fake_weft.mkdir()
    for name in ("weft.sh", "lib.sh"):
        shutil.copy(HERE / name, fake_weft / name)
    p = subprocess.run(
        ["bash", str(fake_weft / "weft.sh"), "ip"],
        cwd=fake_weft,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert p.returncode != 0
    assert "non-interactive" in (p.stdout + p.stderr)
