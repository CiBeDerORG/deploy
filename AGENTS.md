# Project rules for automated contributors

## Credential handling (mandatory)

- Never invent or add password, token, or secret length, character-set, complexity, or format restrictions. Only enforce a restriction when the official upstream service, API, or protocol explicitly requires it. Document the specific upstream requirement and source alongside any new validation; recommendations are not mandatory requirements.
- Respect the exact nonempty value the user configured. Never silently replace, normalize, truncate, hash, reformat, rotate, or overwrite user credentials. Encoding/escaping for transport or config serialization is permitted only if the consuming service receives the same original value after decoding.
- Generate a random value only when the corresponding setting is explicitly documented as optional and the user leaves it empty; persist it without printing or logging it. Never regenerate a configured nonempty value during install/update.
- Where a config format cannot losslessly represent an input, report the limitation instead of silently changing the credential. Handle special characters safely in YAML, Compose, shell, URLs and other serialization boundaries.
- Distinguish upstream-native options from variables defined by this deploy wrapper in documentation and user-facing error messages.
- Regression tests must include user-chosen passwords with punctuation, quotes, spaces and non-ASCII text, preservation of an existing value, and blank-value generation.
- This rule applies project-wide to future changes, not only Mihomo. Review any new credential validation against it before merging.

## Optional inputs and deployment-time generation (mandatory)

- Mark optional inputs explicitly in the example templates and README. Empty values (`KEY=`, `KEY=""`, `KEY=''`, or an omitted key) MUST NOT fail installation just because they are blank. Do not introduce unconditional nonempty assertions, pairwise required checks, or arbitrary format/length restrictions for optional inputs.
- When a downstream runtime requires a concrete secret (e.g. a database password) but the deploy wrapper promises optional input, resolve blank inputs **before** Compose/runtime validation: either generate and persist a secure value when documented to do so, or pass blank through to the official upstream bootstrap when upstream explicitly generates it. Compose `:?` may validate the resolved runtime value, never demand that the user pre-populate an optional template.
- Respect any nonempty user value byte-for-byte, and do not regenerate it on install or update. The serializer must also support quoted-empty and whitespace around `=` that the project's config reader interprets as empty. In ambiguous configurations such as duplicate definitions, fail safely without overwriting an existing nonempty entry.
- If upstream independently permits optional settings to be omitted, the deploy wrapper must not force them to be provided together; apply upstream-mandated validation only to nonempty values and cite its implementation.
- Add regression coverage for each optional-secret group: raw and quoted empty values, omitted keys, first-install persistence, idempotent re-install, separately omitted admin fields, and preservation of nonempty user credentials. Avoid printing generated or user-supplied credentials in CI logs.

## Deployment guide contract (mandatory)

Whenever a new application/service is added to this repository, its installer or deployment instructions are changed, **or** a user asks how to install or deploy a supported application, the contributor's final answer MUST contain the following, with commands that have been verified against the current repository:
1. **Configuration files**: exact paths (Linux/fnOS and Windows when applicable), required vs optional keys, defaults, a complete usable configuration snippet, and which values belong in `deploy/.env` versus `deploy/.secrets`. Include custom image/port/bind address and first-run credentials where relevant. Do not reveal actual secret values.
2. **Installation commands**: checkout/pull the correct branch, initialize/update shared configuration (`deploy.sh env`), the exact install command, and the resulting URL, port or service verification command.
3. **Uninstallation commands**: the *real, supported and executable* command for the application, including a statement of what it removes and which data/configuration remains. Give a separate, explicit **irreversible data purge** command only when relevant; never silently remove persistent data.
4. **Update commands**: exact update invocation and whether existing configuration, credentials and persistent data are preserved.

New Docker applications MUST ship a documented `<app>/deploy/uninstall.sh` or another verified uninstall entry point, ideally `sudo bash deploy.sh <app> uninstall`. Default uninstall must only stop/remove the app's own resources; never remove unrelated containers, shared networks, images, passwords, project code or user data. If an existing service has no uninstall action, clearly say so and give a verified alternative; **never invent a supported command**.

Every added service's README must include all four sections above; examples in the final answer must match the actual repository implementation. Where Linux/fnOS and Windows command support differ, label the platform and do not imply `deploy.ps1` supports an app until it actually does. A branch-only implementation must be identified as such until merged to the default branch. For source changes, also report the branch, commit/PR links and available CI results without claiming a deployment or build passed before it is verified.
