# AGENTS.md - canton-specs

## Repository role

This repository is the research, reference-architecture, and incubation
workspace for OpenZeppelin's Canton work. Keep experiments bounded,
reproducible, and clearly separated from released packages and complete
applications.

Reusable production components belong in `canton-contracts` after their
promotion boundary, package identity, compatibility model, tests, and release
path are accepted. Complete reference implementations belong in their
application repositories.

## Read order

Before changing the repository, read:

1. `README.md`
2. `docs/README.md`
3. `experiments/README.md`
4. The affected domain `README.md`
5. `CONTRIBUTING.md`

All instructions are self-contained in this checkout. Do not assume parent
workspace files exist.

## Boundaries

This repository contains:

- reference architectures and threat models;
- durable architecture and dependency decisions;
- experimental Daml packages that answer a specific research question;
- Smart Contract Upgrade and migration evidence;
- interoperability harnesses and reproducible evidence;
- promotion evidence for reusable `canton-contracts` candidates.

This repository does not contain:

- a second copy of production packages maintained in `canton-contracts`;
- local lookalikes presented as canonical Canton or Splice standards;
- released DARs published under the `canton-specs` name;
- complete application products, frontends, or production deployment stacks;
- grant administration, milestone evidence packets, or reviewer instructions in
  user-facing documentation.

Consume reusable OpenZeppelin components and upstream standards as pinned DAR
artifacts. Record their package identity, checksum, source, and license in
`dars/manifest.yaml`. A fixture may model only the surface needed by an
experiment, but its name and documentation must state that it is a fixture and
must not claim conformance.

## Experiment organization

- Group experiments by research area under `experiments/`.
- Keep one Daml package per independently buildable experiment or fixture.
- Put Daml Script tests in a separate `-test` package with version `0.0.0`.
- Name live-ledger SCU helpers as explicit `-driver-*` packages; their versions
  may mirror the implementation version they load.
- Keep intentional multi-package scenarios in an explicit integration or
  executable exemplar package.
- Place experiment-specific harnesses and evidence with the experiment.
- Keep top-level `scripts/` for repository-wide checks and integration gates.
- Do not create empty placeholder directories.
- Do not give an experimental package a production release path.

Changes that restructure files should remain separate from changes to contract
authority, privacy, lifecycle, or settlement behavior.

## Daml toolchain

The repository is DPM-native. `multi-package.yaml` declares the workspace SDK,
and every package manifest mirrors that version. Package manifests target
Daml-LF `2.1`.

Use `dpm build`, `dpm damlc lint`, `dpm test`, `dpm script`, and
`dpm upgrade-check`. Do not introduce Daml Assistant commands unless a
documented toolchain decision changes this. For package-scoped commands run
from the repository root, set `DAML_PACKAGE` to the repository-relative package
path.

## Documentation

The root `README.md` is a user landing page. It presents the reference
architectures, experiment areas, repository boundaries, security posture, and
navigation. Contributor testing, coverage, maintenance, and CI instructions
belong in `CONTRIBUTING.md` or the workflow itself.

All `README.md` files use present-tense, user-facing language that describes the
current repository contents and their supported use. Do not describe removed
content, previous layouts, internal milestones, review chronology, empty
scaffolding, or planned file operations. Research documents may distinguish
implemented evidence from design proposals when that distinction is part of the
technical result.

Use repository-relative paths in documentation and configuration. Never include
a developer username, home directory, temporary directory, or another
machine-specific absolute path. Refer to repository files by their exact
filenames, including extensions, and format literal filenames and paths with
backticks. Use normal ASCII hyphens instead of typographic dash characters.

## Markdown formatting

Every Markdown file follows one format. Do not introduce a second style, and
never leave a file carrying two. When a file you edit already breaks a rule
below, reflow the paragraphs, lists, and sections your change touches and leave
the rest of the file alone.

Wrap prose at 80 columns, breaking at spaces. A line may exceed 80 columns only
when one unbreakable token makes it longer: a URL, a badge, a long repository
path, or a table row. Length is not a reason to leave a paragraph unwrapped.

Headings:

- Open every file with a single `# ` heading on line 1 naming the document
  subject.
- Use sentence case, capitalizing the first word and proper nouns only. Write
  `## Security and auditability`, not `## Security & Auditability`.
- Do not number headings. Numbers break every existing anchor when a section
  moves and duplicate the outline GitHub already renders.
- Use `##` and `###` only. Do not skip a level and do not add `####`.
- Leave one blank line before and after a heading, with no trailing punctuation
  and no closing `#` characters.

Lists:

- Use `-` for unordered items and `1.` for ordered ones.
- Indent nested items and continuation lines by two spaces, aligning them with
  the parent item text.
- Keep terminal punctuation uniform within a list. Full sentences each end with
  a period. Clauses of one sentence introduced by a colon each end with a
  semicolon, and the final clause ends with a period. Short noun phrases take
  none. Do not mix the three in a single list.

Tables:

- Write the delimiter row as `|---|---|`, without padding or alignment colons,
  and pad each cell's contents with one space on either side.
- Use a table only for uniform records where every row fills every column. Two
  columns of prose belong in paragraphs.

Code, links, and emphasis:

- Tag every fenced block with its language: `daml`, `sh`, `text`, or `mermaid`.
- Write line anchors as `#L<number>`. GitHub silently ignores a bare
  `#<number>` and lands the reader at the top of the file.
- Reserve `**bold**` for a term the reader must not miss. Prose that bolds a
  phrase in most sentences is harder to scan, not easier. Mark up code with
  backticks and carry emphasis in the sentence itself.

End every file with exactly one newline. Leave no trailing whitespace and no
consecutive blank lines.

`scripts/check-docs.sh` validates link targets and machine-specific paths. It
does not check the rules in this section, so verify those yourself.

## Validation

Run from the repository root:

```sh
dpm build --all
scripts/check.sh
scripts/check-lint.sh
scripts/check-tests.sh
scripts/check-docs.sh
```

Run `scripts/identity-hook-upgrade-smoke.sh` when changing the SCU experiment.
Run the LocalNet and Wallet Gateway integration gates when changing their Daml
surface, harness, or participant assumptions.

The CI-only discovery scripts validate all declared packages. Public and
contributor documentation shows native DPM commands instead of presenting those
scripts as the development interface.
