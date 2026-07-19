# Security policy

## Supported version

Security fixes are made on the default branch. This project does not currently
maintain separate supported release lines.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. If that
surface is unavailable, contact the maintainer privately through the contact method
on their GitHub profile. Do not include credentials, private hostnames, addresses,
backup object names, or personal data in a public issue.

Include the affected path, impact, prerequisites, a minimal reproduction, and a
suggested remediation when possible. Reports are acknowledged on a best-effort basis;
this is a small, independently maintained project with no guaranteed response SLA.

## Operational warning

Brokkr contains privileged deployment and backup automation. Review all target hosts,
paths, environment files, and rendered service units before running it. Examples use
reserved domains and TEST-NET addresses and are not deployable without local values.
Never commit tunnel credentials, rclone configuration, notification tokens, or live
operator status.
