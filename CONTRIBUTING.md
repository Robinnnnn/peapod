# Contributing

Peapod is a messenger for exactly one paired connection. Keep the route to the
conversation direct and the language useful to friends, family, and partners.
Groups, feeds, discovery, and relationship gamification are outside its scope.

This repository is a standalone snapshot with occasional updates. There is no
promise that it mirrors another development branch or hosted deployment.

For changes, explain the behavior and affected platforms, keep the diff focused,
and run the relevant Swift-package or backend checks described in the README.
Shared wire, encryption, Keychain, or attachment changes need both iPhone and
Mac consideration. Preserve fail-closed behavior and use synthetic inputs.
Do not add live-account fixtures, private credentials, debug galleries, or UI
click-through test gates. Do not weaken authentication to make a test pass.

Contributions are provided under this repository's MIT license. Please include
provenance and license information for any third-party code or media.
