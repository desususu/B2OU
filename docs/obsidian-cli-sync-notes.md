# Obsidian CLI integration notes

Obsidian CLI and Bear CLI solve different parts of the safety story.

Bear CLI can read and write Bear notes directly, including an optimistic
concurrency guard for writes (`--base <hash>`). Obsidian CLI controls a running
Obsidian desktop app and exposes vault commands, history, diff, link-aware
move/rename, and Sync controls.

## Recommended use in B2OU

- Keep bulk Bear to Obsidian export on the filesystem. It is faster, can use
  atomic temporary files, and does not require one Obsidian IPC command per note.
- Use Obsidian CLI as an optional safety layer, not as the primary writer:
  - pause/resume Obsidian Sync around a large managed export;
  - verify Sync status before and after export;
  - use Obsidian history/diff for conflict review;
  - use Obsidian move/rename for managed note path changes so internal links can
    be updated by Obsidian.
- Use Obsidian Headless Sync only on devices that are not also running desktop
  Obsidian Sync for the same vault.

## Bidirectional sync requirements

Fully automatic bidirectional sync is not safe unless both sides support
optimistic concurrency and conflict quarantine.

B2OU keeps Bear identity and concurrency metadata in a sidecar state file:

```text
.b2ou/state.json
```

The sidecar maps an exported relative file path to the Bear note ID, Bear note
hash when available, Bear modified timestamp, and exported file fingerprint.
B2OU does not write Bear IDs or Bear hashes into Markdown front matter or note
bodies.

Existing one-way export folders can be transitioned with:

```bash
b2ou rebuild-state --out ~/Notes
```

The command previews matches by default and only writes `.b2ou/state.json` when
`--write` is passed. It does not modify note content.

A future Obsidian to Bear import should:

1. Only operate on files with a valid sidecar binding and exported file
   fingerprint.
2. Read the current Bear note hash with Bear CLI before any write.
3. Refuse to write if the current Bear hash differs from the exported
   sidecar `bear_hash`; write a conflict copy instead.
4. Convert attachment references explicitly. Bear CLI warns that missing
   attachment references in `write` remove attachments from the note.
5. Write through `bearcli write <id> --base <hash>`, never through Bear's SQLite
   database.
6. Re-export from Bear after a successful write, making Bear the convergence
   source.

The safe near-term model is therefore reviewable two-way sync: detect and stage
Obsidian edits, then apply them to Bear only when the Bear hash still matches.
