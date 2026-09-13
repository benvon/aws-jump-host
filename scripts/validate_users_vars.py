#!/usr/bin/env python3
"""Fail-closed users.yaml schema used before log-transfer IAM is applied.

Ansible user_accounts is the other consumer of this file. Terragrunt applies
downloader ARNs first, so this check must reject records Ansible would later
fail on — including keys that are present with YAML null (Ansible treats those
as defined). Direct Terragrunt runs the same script.
"""
from __future__ import annotations

import sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "Error: PyYAML is required to validate --users-vars (install ansible-core).\n"
    )
    sys.exit(1)

ALLOWED_SUDO = ("none", "ops", "admin")
ALLOWED_STATE = ("present", "absent")


def fail(message: str) -> None:
    sys.stderr.write("Error: %s\n" % message)
    sys.exit(1)


def is_list_of_strings(value: object) -> bool:
    return isinstance(value, list) and all(
        isinstance(item, str) and item.strip() for item in value
    )


def validate(data: object) -> None:
    if data is None:
        data = {}
    if not isinstance(data, dict):
        fail("users vars file must be a YAML mapping.")

    # Missing users means []; a present users: null is defined and must be a list.
    users = data["users"] if "users" in data else []
    if not isinstance(users, list):
        fail("users must be a list.")

    for index, user in enumerate(users):
        if not isinstance(user, dict):
            fail("invalid user schema for users[%d]: must be a mapping." % index)
        username = user.get("username")
        label = username if isinstance(username, str) and username else "users[%d]" % index
        if not isinstance(username, str) or not username:
            fail("invalid user schema for %s: username must be a string." % label)
        if "groups" not in user or not is_list_of_strings(user["groups"]):
            fail("invalid user schema for %s: groups must be a list." % label)
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
        if "iam_role_arns" in user and not is_list_of_strings(user["iam_role_arns"]):
            fail(
                "invalid user schema for %s: iam_role_arns must be a list of strings."
                % label
            )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        fail("Usage: validate_users_vars.py <users-vars-file>")
    path = argv[1]
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except yaml.YAMLError as exc:
        fail("users vars file is not valid YAML: %s" % exc)
    except OSError as exc:
        fail("could not read users vars file: %s" % exc)
    validate(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
