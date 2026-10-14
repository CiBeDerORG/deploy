# Project rules for automated contributors

## Credential handling (mandatory)

- Never invent or add password, token, or secret length, character-set, complexity, or format restrictions. Only enforce a restriction when the official upstream service, API, or protocol explicitly requires it. Document the specific upstream requirement and source alongside any new validation; recommendations are not mandatory requirements.
- Respect the exact nonempty value the user configured. Never silently replace, normalize, truncate, hash, reformat, rotate, or overwrite user credentials. Encoding/escaping for transport or config serialization is permitted only if the consuming service receives the same original value after decoding.
- Generate a random value only when the corresponding setting is explicitly documented as optional and the user leaves it empty; persist it without printing or logging it. Never regenerate a configured nonempty value during install/update.
- Where a config format cannot losslessly represent an input, report the limitation instead of silently changing the credential. Handle special characters safely in YAML, Compose, shell, URLs and other serialization boundaries.
- Distinguish upstream-native options from variables defined by this deploy wrapper in documentation and user-facing error messages.
- Regression tests must include user-chosen passwords with punctuation, quotes, spaces and non-ASCII text, preservation of an existing value, and blank-value generation.
- This rule applies project-wide to future changes, not only Mihomo. Review any new credential validation against it before merging.
