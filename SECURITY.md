# Security policy

## Security posture

This repository publishes architecture research, experimental Daml packages,
and interoperability evidence. These artifacts are not production releases and
do not establish the security of a consuming application or participant
topology.

When a vulnerability is identified, OpenZeppelin will investigate the affected
source and package IDs, correct the research artifact where technically
possible, document compatibility or migration implications, and communicate
required actions. Applying a remediation remains the responsibility of
application developers, participant operators, and counterparties. Some Daml
contract or interface defects require explicit contract migration and may not
be recoverable after exploitation.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/OpenZeppelin/canton-specs/security/advisories/new).
Do not disclose a suspected vulnerability through a public issue, discussion,
or pull request before coordinated disclosure.

Include the affected experiment and source commit, reproduction steps, expected
and observed authorization behavior, ledger and topology assumptions, and known
impact. OpenZeppelin will acknowledge and triage the report through the private
advisory.

## Scope

Security review must include the consuming application's canonical-contract
selection, resource binding, party authorization, disclosure, privacy, package
dependencies, participant configuration, vetting policy, and off-ledger
integrations. An experiment cannot establish these application-level assumptions
by itself.
