# Agent Guidelines for `phrases`

This document defines core principles, architectural invariants, and non-negotiable safety rules for AI agents working on the `phrases` repository.

______________________________________________________________________

## 1. Project Overview & Architecture

`phrases` is a minimal score structure library in Zig. It describes *when* a note sounds and *for how long*; it does not know what a note is, and it does not synthesize, mix, or write audio.

- **Pure Zig, `std` Only**: `build.zig.zon` has no dependencies, and it must stay that way. Do not add `lightmix` or any other package; audio belongs to the downstream libraries.
- **Library Package**: The public module is registered as `phrases` via `b.addModule` in `build.zig`, so downstream projects consume it with `b.dependency("phrases", .{})`.
- **Downstream Consumers**: [`resonator`](https://github.com/haruki7049/resonator), [`sequencer`](https://github.com/haruki7049/sequencer) and [`pulse`](https://github.com/haruki7049/pulse) depend on `phrases` and pin it to a commit hash in their `build.zig.zon`. A change here reaches them only when they bump that pin, and they test that `phrases.Position` and `phrases.TimeSignature` resolve to one shared type. Treat a change to a public type's fields, a function signature, or a numeric result (such as the frame `Position.toSampleOffset` returns) as a breaking change, and state it in the PR description.
- **Target Language Version**: Zig `0.16.0`, matching the toolchain pinned in `flake.nix`.
- **Development Environment**: Managed with Nix, `direnv`, and `nix-direnv`. Formatting across all languages is handled via `treefmt` (nixfmt, zig fmt, actionlint, mdformat, shellcheck, shfmt).
- **Source Layout** (`src/`):
  - `root.zig`: Re-exports every public symbol.
  - `position.zig`: `Position` (0-indexed `bar`, `beat` offset) and `toSampleOffset`.
  - `time-signature.zig`: `TimeSignature` (`numerator` / `denominator`, defaults to 4/4).
  - `tempo.zig`: `samplesPerBeat` (a beat of a time signature) and `framesFromBeats`, the only beat-to-frame conversion, with `tempo.Error`.
  - `event.zig`: `Event(N)`, a time-placed event with `position`, `length` (sample frames) and a `note: N` payload.
  - `phrase.zig`: `Phrase(N)`, a declarative phrase of raw notes placed in time by `toEvents`.
- **Domain Conventions**:
  - BPM always counts quarter notes; `TimeSignature.denominator` scales the beat length (an 8th-note beat is half a quarter).
  - Bars are 0-indexed. `beat` is an `f64` offset within the bar.
  - Timing conversions compute in `f64` and convert to an integer frame once, at the end, with `@round`. Do not truncate, and do not round an intermediate value such as samples per beat before multiplying it.
  - Positions and lengths use one beat, the beat of the time signature: every beat-to-frame conversion goes through `tempo.samplesPerBeat` and `tempo.framesFromBeats`. Do not compute a beat length or a frame count anywhere else, and do not change the order of operations in `samplesPerBeat`, which decides how offsets round.
  - The note payload `N` is opaque: `phrases` passes it through from `RawNote` to `Event` and never inspects it. Do not add pitch, frequency, volume, instrument or other note semantics to `phrases`, and do not depend on a pitch library such as `pitches`; those belong in `N` and in the consumer.
  - Functions that allocate return memory the caller owns (e.g. `Phrase.toEvents`); document that in the doc comment.

______________________________________________________________________

## 2. Strict Safety & Operational Rules (Always Enforced)

- **A change request implies commit, push and PR**: When the user instructs a change, carry it through to a pull request without asking for confirmation: work on a topic branch created from the latest `origin/main` (or the existing topic branch for that work; never commit on `main`, since it cannot be pushed), pass the verification commands, then `git commit`, `git push` the topic branch, and open a PR with `gh pr create` if none exists. If the branch already has an open PR, push to it and update the PR description when it has become stale.
- **`main` is protected on GitHub (ruleset active)**: A GitHub ruleset on the default branch requires a pull request (0 required approvals, squash merge only), signed commits, linear history and these status checks: `test` (ubuntu, macos, windows), `run-nix-check` and `run-nix-build` (ubuntu, macos), and `validate-pr-title`. It also blocks deletion and non-fast-forward pushes. `git push origin main` will therefore be rejected. AI agents **MUST NEVER** merge PRs (including enabling auto-merge with `gh pr merge --auto`) or execute `git merge` autonomously.
- **NEVER PROPOSE COMMITS OR PUSHES UNPROMPTED**: AI agents **MUST NEVER** prompt the user to commit or push, nor propose commit messages unprompted (e.g. do NOT ask "Would you like me to commit and push?"). When instructed by the user or when creating/updating pull requests on topic branches, agents may execute `git commit` and `git push` directly without seeking confirmation.
- **Mandatory Human Approval**: AI agents may create branches, create commits, push topic branches, propose PRs, format code, and run test suites, but the final action of merging changes into `main` rests strictly with the human maintainer.
- **Verification Before Submitting**: All changes must pass the commands in [Section 3](#3-verification-commands).
- **Conventional Commits**: Use conventional commit prefixes (`feat:`, `fix:`, `refactor:`, `docs:`, `build:`, `ci:`, `test:`). The PR title must follow the same format; `validate-pr-title` checks it.
- **No Issue Numbers in Commit Messages**: Do not include issue numbers (e.g. `(#5)` or `#5`) anywhere in a commit message, summary or body, or in a PR title. Squash merges copy every commit message into `main`, so a `Closes #5` in a commit body can close an issue the PR was never meant to close. Link issues only from the PR description with a closing keyword (e.g. `Closes #5`). The ` (#N)` suffix GitHub appends to a squash-merge summary is the one exception.
- **Explicit Milestone Assignment Only**: AI agents **MUST NEVER** attach or set GitHub Milestones on Pull Requests or Issues unless explicitly requested by the user.
- **Evidence First**: Base all answers and actions on actual file contents and command output. Never speculate or assume.
- **Non-Destructive**: Never perform irreversible actions (file deletions, hard resets, rewriting pushed history such as amending or rebasing pushed commits and force-pushing, pushing to `main`) without explicit user approval. Ordinary pushes of new commits to a topic branch don't need approval (see above).
- **Targeted Edits**: Make minimal, logical changes strictly necessary for the request. Do not modify unrelated files.
- **English-Only Documentation**: All repository documentation, code comments, commit messages, and PR descriptions must be written strictly in English. Never include Japanese or any non-English language in repository documentation.
- **No Session Links**: Do not include AI session URLs or other internal session identifiers (e.g. a `Claude-Session:` trailer) in commit messages, PR descriptions, issues, or comments. Such links are not accessible from outside the private session, so publishing them in this public repository serves no purpose and only confuses readers. A `Co-Authored-By:` trailer is fine. Exception: if the user explicitly states the session is public and instructs the agent to include its URL, doing so is allowed.

______________________________________________________________________

## 3. Verification Commands

Run these inside the Nix development shell (`nix develop` or `direnv allow`). CI runs the same set.

| Task | Command | Description |
| :--- | :--- | :--- |
| **Check formatting** | `treefmt --fail-on-change` | Checks every language treefmt covers; `zig fmt --check .` checks Zig files only |
| **Build** | `zig build` | Builds the static library |
| **Run tests** | `zig build test` | Runs every unit test in `src/` |
| **Check the flake** | `nix flake check` | Runs the flake checks, including the treefmt check and the package build |

______________________________________________________________________

## 4. Coding Conventions

- **Comments**: Every public declaration has a `///` doc comment, and every file starts with a `//!` comment that says what it contains. Comments are in English.
- **Naming**:
  - `PascalCase` for types and for files imported as a struct (`Position`, `TimeSignature`).
  - `camelCase` for functions and methods (`toSampleOffset`, `toEvents`).
  - `snake_case` for variables, parameters, struct fields and enum tags (`sample_rate`, `duration_beats`, `.cs`).
  - Comptime type parameters are always a single uppercase character (`N` for the note payload type). Multi-character names such as `comptime SampleType: type` are prohibited.
  - Error tags are `PascalCase` (`error.InvalidPosition`, `error.InvalidBpm`, `error.InvalidSampleRate`).
- **Generic Factories**: A type parameterized by comptime types is defined as `pub fn inner(...) type` in its own file and re-exported under its `PascalCase` name in `root.zig` (`pub const Event = @import("./event.zig").inner;`).
- **Tests**: Keep tests next to the code they cover, in the same file. Every file ends with `test { std.testing.refAllDecls(@This()); }`. A test that checks a numeric result states the expected value and how it was derived in a comment (e.g. `// 60 BPM, 44100 Hz => spb = 44100`).
- **Validation**: Reject invalid input with an error instead of reaching undefined or panicking behavior: zero parameters, NaN, negative or infinite beats, and frame counts beyond a `usize`. Name each error after the input that is wrong (`InvalidBpm`, `InvalidTimeSignature`, `InvalidSampleRate`, `InvalidPosition`, `InvalidDuration`), and declare the error set of every public function that can fail (`tempo.Error`, `Position.ToSampleOffsetError`, `Phrase(N).ToEventsError`) instead of leaving it inferred.

______________________________________________________________________

## 5. Status Assessment Workflow

When asked to check status, assess the situation, or understand workspace context:

1. **Local Git State**: Inspect working tree (`git status -s -b`) and recent commits (`git log -n 5 --oneline`).
1. **GitHub PRs**: Check PR status (`gh pr status`) and current PR details (`gh pr view`).
1. **GitHub Issues**: Check relevant open issues (`gh issue list --limit 5`).
1. **Environment Health**: Run the commands in [Section 3](#3-verification-commands).
1. **Synthesis**: Report a concise, structured status covering local state, remote GitHub state, and environment health.
