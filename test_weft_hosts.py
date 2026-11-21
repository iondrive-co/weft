"""Offline tests for weft_hosts.py against invented Terraform states."""
from __future__ import annotations

import json
from pathlib import Path

import weft_hosts as wh


def test_collect_hosts_from_invented_vultr_aws_and_empty_states(tmp_path: Path):
    vultr_state = {
        "format_version": "1.0",
        "values": {
            "outputs": {
                "server_cloud": {"sensitive": False, "value": "vultr"},
                "server_ip": {"sensitive": False, "value": "192.0.2.10"},
                "server_region": {"sensitive": False, "value": "nrt"},
            },
            "root_module": {
                "resources": [
                    {
                        "type": "vultr_instance",
                        "values": {
                            "hostname": "box-vultr.example.invalid",
                            "main_ip": "192.0.2.10",
                            "region": "nrt",
                            "plan": "vhp-1c-2gb-amd",
                        },
                    }
                ]
            },
        },
    }
    aws_state = {
        "format_version": "1.0",
        "values": {
            "outputs": {
                "server_cloud": {"sensitive": False, "value": "aws"},
                "server_ip": {"sensitive": False, "value": "198.51.100.20"},
                "server_region": {"sensitive": False, "value": "ap-northeast-1"},
            },
            "root_module": {
                "resources": [
                    {
                        "type": "aws_instance",
                        "values": {
                            "public_ip": "198.51.100.20",
                            "instance_type": "t3.small",
                            "tags": None,
                            "tags_all": {"Name": "box-aws.example.invalid"},
                        },
                    }
                ]
            },
        },
    }
    empty_state = {"format_version": "1.0", "values": {}}

    (tmp_path / "ws-vultr.json").write_text(json.dumps(vultr_state), encoding="utf-8")
    (tmp_path / "ws-aws.json").write_text(json.dumps(aws_state), encoding="utf-8")
    (tmp_path / "ws-empty.json").write_text(json.dumps(empty_state), encoding="utf-8")

    hosts = wh.collect_hosts(tmp_path, from_json_dir=tmp_path)
    assert hosts == [
        {
            "workspace": "ws-aws",
            "hostname": "box-aws.example.invalid",
            "ip": "198.51.100.20",
            "region": "ap-northeast-1",
            "plan": "t3.small",
            "cloud": "aws",
        },
        {
            "workspace": "ws-vultr",
            "hostname": "box-vultr.example.invalid",
            "ip": "192.0.2.10",
            "region": "nrt",
            "plan": "vhp-1c-2gb-amd",
            "cloud": "vultr",
        },
    ]


def test_collect_local_tfstates_fast_path_without_terraform(tmp_path: Path):
    wdir = tmp_path / "weft"
    (wdir / "terraform.tfstate.d" / "ws-vultr").mkdir(parents=True)
    (wdir / "terraform.tfstate.d" / "ws-aws").mkdir(parents=True)
    (wdir / "terraform.tfstate.d" / "ws-empty").mkdir(parents=True)

    (wdir / "terraform.tfstate").write_text(json.dumps({"version": 4, "outputs": {}, "resources": []}), encoding="utf-8")
    (wdir / "terraform.tfstate.d" / "ws-vultr" / "terraform.tfstate").write_text(
        json.dumps(
            {
                "version": 4,
                "outputs": {
                    "server_cloud": {"value": "vultr", "type": "string"},
                    "server_ip": {"value": "192.0.2.10", "type": "string"},
                    "server_region": {"value": "nrt", "type": "string"},
                },
                "resources": [
                    {"mode": "data", "type": "vultr_instance", "instances": [{"attributes": {"hostname": "ignore-data"}}]},
                    {
                        "mode": "managed",
                        "type": "vultr_instance",
                        "instances": [
                            {
                                "attributes": {
                                    "hostname": "box-vultr.example.invalid",
                                    "main_ip": "192.0.2.10",
                                    "region": "nrt",
                                    "plan": "vhp-1c-2gb-amd",
                                }
                            }
                        ],
                    },
                ],
            }
        ),
        encoding="utf-8",
    )
    (wdir / "terraform.tfstate.d" / "ws-aws" / "terraform.tfstate").write_text(
        json.dumps(
            {
                "version": 4,
                "outputs": {
                    "server_cloud": {"value": "aws", "type": "string"},
                    "server_ip": {"value": "198.51.100.20", "type": "string"},
                    "server_region": {"value": "ap-northeast-1", "type": "string"},
                },
                "resources": [
                    {
                        "mode": "managed",
                        "type": "aws_instance",
                        "instances": [
                            {
                                "attributes": {
                                    "public_ip": "198.51.100.20",
                                    "instance_type": "t3.small",
                                    "tags": None,
                                    "tags_all": {"Name": "box-aws.example.invalid"},
                                }
                            }
                        ],
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    (wdir / "terraform.tfstate.d" / "ws-empty" / "terraform.tfstate").write_text(
        json.dumps({"version": 4, "outputs": {}, "resources": []}),
        encoding="utf-8",
    )

    hosts = wh.collect_hosts(wdir)
    assert hosts == [
        {
            "workspace": "ws-aws",
            "hostname": "box-aws.example.invalid",
            "ip": "198.51.100.20",
            "region": "ap-northeast-1",
            "plan": "t3.small",
            "cloud": "aws",
        },
        {
            "workspace": "ws-vultr",
            "hostname": "box-vultr.example.invalid",
            "ip": "192.0.2.10",
            "region": "nrt",
            "plan": "vhp-1c-2gb-amd",
            "cloud": "vultr",
        },
    ]

    # Remote backend disables local fast path
    (wdir / ".terraform").mkdir()
    (wdir / ".terraform" / "terraform.tfstate").write_text(json.dumps({"backend": {"type": "s3"}}), encoding="utf-8")
    assert wh.collect_local_tfstates(wdir) is None
