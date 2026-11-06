# Source origin

Repository: https://github.com/9fans/plan9port

Revision: 1f1396913fb5372408f442ed26933f5ae4b399cd

The inventory records the imported bytes and their licence evidence.
Third-party notices remain in their original files.

The files are plan9port's, unchanged, from `src/cmd/rc/test.rc`,
`src/cmd/rc/checkparse` and the top-level `LICENSE` of the commit above,
the `plan9port` pin of `deps.lock`; `archive_sha256` is the SHA-256 of
that pin's `git archive`. Licence: MIT, under "Copyright (c) 2021 Plan 9
Foundation" with portions by Russ Cox and Google Inc.; `LICENSE` is the
text. Purpose: the start of the command shell's test corpus
([design-shell.md](../../../../docs/design-shell.md#verification-and-testing)).
`test.rc` is a parser corpus, not a program: `checkparse` feeds each file
to rc twice, as `rc -DY` (rc's yacc grammar) and `rc -D` (its
hand-written parser), and requires the two printed trees to agree.
`checkparse` is a bash script and is never run here; erXos's
`test/integration/rc_oracle_test.rb` makes the same comparison through
`Erx::RcOracle::Oracle#parse`.

```json
{
  "version": 1,
  "repository": "https://github.com/9fans/plan9port",
  "revision": "1f1396913fb5372408f442ed26933f5ae4b399cd",
  "archive_sha256": "13a993b331b95ca33e0e441f47a8da51f30d721ea9d8654d4dba12bb04bfe2f9",
  "exclusions": [],
  "files": {
    "LICENSE": {
      "license": "MIT",
      "evidence": "LICENSE",
      "reviewed": true,
      "sha256": "0596b18c65ebc9462dab21e6cded632fe2af56a93ca4c913431a8a45f1b7fa74",
      "kind": "file",
      "non_ascii_lines": []
    },
    "checkparse": {
      "license": "MIT",
      "evidence": "LICENSE",
      "reviewed": true,
      "sha256": "4a0b86198b1e7cd8a97ec0ac1cb7be6b47cd0491ab550d83c12799460b0c00d1",
      "kind": "file",
      "non_ascii_lines": []
    },
    "test.rc": {
      "license": "MIT",
      "evidence": "LICENSE",
      "reviewed": true,
      "sha256": "0b075271990f92ae080808d0f5db63997db96cc9c1ca56b5131ca2a34177c6d0",
      "kind": "file",
      "non_ascii_lines": []
    }
  },
  "changes": {}
}
```
