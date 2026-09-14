#!/usr/bin/env python3
"""Canonical users.yaml policy for jump-host provisioning and log-transfer IAM.

Orchestrate, Terragrunt, and Ansible user_accounts all run this helper so
download grants are never applied for records that would not get a Linux user.
A present key with YAML/JSON null is defined (same as Ansible).
"""
from __future__ import annotations

import argparse
import json
import re
import sys

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]

ALLOWED_SUDO = ("none", "ops", "admin")
ALLOWED_STATE = ("present", "absent")
# shadow-utils / useradd on Amazon Linux 2023 (man useradd recommended form).
LINUX_NAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
IAM_ROLE_ARN_RE = re.compile(r"^arn:[a-z0-9-]+:iam::\d{12}:role/.+")


def fail(message: str) -> None:
    sys.stderr.write("Error: %s\n" % message)
    sys.exit(1)


def is_list_of_strings(value: object) -> bool:
    return isinstance(value, list) and all(
        isinstance(item, str) and item.strip() for item in value
    )


def require_linux_name(value: object, label: str, field: str) -> None:
    if not isinstance(value, str) or not LINUX_NAME_RE.fullmatch(value):
        fail(
            "invalid user schema for %s: %s must be a valid Linux account name."
            % (label, field)
        )


def validate(data: object) -> list[dict]:
    if data is None:
        data = {}
    if not isinstance(data, dict):
        fail("users vars file must be a YAML mapping.")

    # Missing users means []; a present users: null is defined and must be a list.
    users = data["users"] if "users" in data else []
    if not isinstance(users, list):
        fail("users must be a list.")

    seen_usernames: set[str] = set()
    validated: list[dict] = []
    for index, user in enumerate(users):
        if not isinstance(user, dict):
            fail("invalid user schema for users[%d]: must be a mapping." % index)
        username = user.get("username")
        label = username if isinstance(username, str) and username.strip() else "users[%d]" % index
        if not isinstance(username, str) or not username:
            fail("invalid user schema for %s: username must be a string." % label)
        require_linux_name(username, label, "username")
        if username in seen_usernames:
            fail("invalid user schema for %s: duplicate username." % label)
        seen_usernames.add(username)
        if "groups" not in user or not is_list_of_strings(user["groups"]):
            fail("invalid user schema for %s: groups must be a list." % label)
        for group in user["groups"]:
            require_linux_name(group, label, "groups entries")
        if user.get("sudo_profile") not in ALLOWED_SUDO:
            fail(
                "invalid user schema for %s: sudo_profile must be none, ops, or admin."
                % label
            )
        if "state" in user and user["state"] not in ALLOWED_STATE:
            fail(
                "invalid user schema for %s: state must be present or absent."
                % label
            )
        if "iam_role_arns" in user:
            arns = user["iam_role_arns"]
            if not is_list_of_strings(arns):
                fail(
                    "invalid user schema for %s: iam_role_arns must be a list of strings."
                    % label
                )
            for arn in arns:
                if not IAM_ROLE_ARN_RE.fullmatch(arn):
                    fail(
                        "invalid user schema for %s: iam_role_arns must be IAM role ARNs."
                        % label
                    )
        validated.append(user)
    return validated


def downloader_role_arns(users: list[dict]) -> list[str]:
    arns: list[str] = []
    seen: set[str] = set()
    for user in users:
        if user.get("state", "present") == "absent":
            continue
        for arn in user.get("iam_role_arns") or []:
            if arn not in seen:
                seen.add(arn)
                arns.append(arn)
    return arns


def load_data(args: argparse.Namespace) -> object:
    if args.json:
        try:
            return json.load(sys.stdin)
        except json.JSONDecodeError as exc:
            fail("users vars JSON is not valid: %s" % exc)
    if yaml is None:
        fail("PyYAML is required to validate --users-vars (install ansible-core).")
    try:
        with open(args.file, encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        fail("users vars file is not valid YAML: %s" % exc)
    except OSError as exc:
        fail("could not read users vars file: %s" % exc)
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="validate_users_vars.py",
        add_help=True,
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Read a users document as JSON from stdin (Ansible).",
    )
    parser.add_argument(
        "--print-downloader-arns",
        action="store_true",
        help="Print distinct present-user iam_role_arns as JSON after validation.",
    )
    parser.add_argument("file", nargs="?", help="users.yaml / extra-vars file")
    try:
        args = parser.parse_args(argv[1:])
    except SystemExit as exc:
        if exc.code == 0:
            return 0
        fail("Usage: validate_users_vars.py [--print-downloader-arns] <users-vars-file>")

    if args.json == bool(args.file):
        fail("Usage: validate_users_vars.py [--print-downloader-arns] <users-vars-file>")

    users = validate(load_data(args))
    if args.print_downloader_arns:
        sys.stdout.write(json.dumps(downloader_role_arns(users)) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
