# Security policy

This repository is documentation, shell scripts and configuration samples for running a
DGX Spark cluster. It is not a service; there is nothing to log into.

## Reporting a problem

Open a private report through GitHub's **Report a vulnerability** button on the Security
tab of this repository, or open an issue if the problem is not sensitive. Please include
the file and the line, what you expected, and what happened.

## What we care about

- A script that would delete or overwrite data when the documented arguments are used.
- A script that escalates privileges beyond what its description says.
- Anything that would leak a credential or a host identifier into the repository.
- Instructions that are unsafe to follow as written (for example, a command that stops
  fan control on a live node and does not say so).

## What is out of scope

- Vulnerabilities in the upstream projects this repository configures. Report those to
  [`christopherowen/dgx-spark-fan-control`](https://github.com/christopherowen/dgx-spark-fan-control)
  and [`christopherowen/spark-ds41f`](https://github.com/christopherowen/spark-ds41f).
- Vulnerabilities in NVIDIA firmware, the driver or DGX OS. Those go to NVIDIA.
- Misconfiguration on your own cluster. Open an issue and we will help, but it is not a
  security report.

## How the repository protects itself

Every push runs [`scripts/checks.sh`](scripts/checks.sh) through
[`.github/workflows/checks.yml`](.github/workflows/checks.yml):

- a scan for credentials and tokens,
- a scan for personal or internal identifiers (private addresses, tailnet names, home
  directories),
- `bash -n` on every script,
- a check that every relative link resolves.

The action is pinned to a commit. The workflow has `contents: read` only and does not
persist credentials, so a compromised step cannot push to the repository.
