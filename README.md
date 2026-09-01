# Epistoria

Epistoria is a personal, local-first iPad notebook for study and research. It supports spatial
notes, Apple Pencil input, images, PDFs, annotations, study sessions, local search, encrypted
sync, direct provider processing from the iPad, and an optional Mac Compute Node.

This project started because I needed one notebook that I could use while learning any subject.
It is a personal project. It is not currently intended for sale or multi-user use.

## Problem statement

Study material is usually split across note apps, PDF readers, drawing tools, and AI chat tools.
This separation creates several problems:

- Notes and source documents are hard to review together.
- Cloud-first tools can require a network connection for basic work.
- A service operator can often read synchronized content.
- AI output can lose its connection to the source material.
- Proprietary storage can make it difficult to inspect or move personal data.

The project needs to support normal notebook work first. It must save locally, work without AI,
preserve original files, and expose recovery and export limits directly.

## Solution description

Epistoria provides a native SwiftUI notebook for iPad. A note is a spatial workspace with the
following options:

- A4 or US Letter paper in portrait or landscape orientation.
- An infinite canvas that supports positive and negative coordinates.
- Plain, ruled, grid, or dotted paper.
- Stable fixed pages with page-local PencilKit ink, or one infinite canvas.
- Movable, resizable, rotatable, and layered text and image items.
- Non-destructive image crop, quarter-turn rotation, rounded and oval masks, replacement, and
  restoration of the first encrypted image.

The app also provides:

- One private notebook that connects subjects, sources, notes, sessions, and learning history.
- Immutable PDF import and separate page annotations.
- Areas, Topics, optional Lists, academic Topic details, and study sessions.
- A page manager for insertion, duplication, reordering, paper changes, Trash, and restoration.
- A fixed notebook tool rail with a customizable More panel for optional learning and recognition
  tools.
- Automatic on-device hybrid search. Exact text matches appear first. Related results can find
  different wording and link back to the matching note item or PDF passage when available.
- Find in Note, pinned notes, Archive, and manually emptied encrypted Trash.
- One contextual Learning hub for sessions, review, Tutor, Concepts, goals, questions, and history.
- Optional encrypted synchronization through a private server.
- Explicit conflict review that preserves concurrent versions.
- A readable ZIP export with JSON, original files, PencilKit data, and SHA-256 checksums.
- Version 8 export import into an empty notebook under a new local encryption key. Earlier
  development exports remain readable archives.
- AI provider management for OpenAI, Anthropic, Gemini, and OpenAI-compatible local or hosted
  endpoints, with device-only Keychain storage.
- An Adaptive Tutor that keeps durable encrypted transcripts, cites frozen Source Versions, and
  changes its next activity only from reviewed learning signals.
- A per-Topic Concept and Evidence map with durable encrypted arrangement, exact Source return
  links, note reuse, typed relationships, and Tutor entry.
- Handwritten mathematics tools for equation recognition, worked steps, local graphing, and error
  diagnosis. Results remain separate from the original Pencil strokes until reviewed.

The learning system stores durable source-linked flashcards, practice tests, review history, and a
**Study Next** queue. Accepted cards and tests are notebook records, not temporary chat output. A
completed attempt retains the exact questions, answers, score, feedback, and source versions that
the user saw.

A test request can target a subject inside one notebook. Comprehensive mode will first produce a
coverage outline, then include every relevant learning objective found in that notebook, broader
questions that combine related skills, and a visible report of anything it could not cover. The
queue will use goals, due reviews, unresolved questions, and practice results. It will state why it
recommends each action. Manual learning features and local recommendations work offline. Generated
drafts and written-answer feedback require an approved provider connection. They do not require a
Mac.

The iPad stores data in SQLCipher. Each local record change and its sync outbox entry commit in
one transaction. A successful local save does not wait for the network. The sync service stores
encrypted envelopes and structural metadata. It does not receive readable note text, titles,
filenames, annotations, extracted PDF text, prompts, or AI results.

## Selected challenge theme

The selected challenge is the **Wildcard Challenge: Build Intelligent Systems for the Future of
Work**.

Epistoria helps an individual plan, decide, and execute knowledge work. It combines source
material, notes, learning history, and reviewed AI assistance to decide what to study next and
verify understanding. This is decision support for a real task rather than a general chat
interface.

Epistoria treats AI as an optional processing feature. The notebook remains usable when the AI
provider, Compute Node, or sync server is unavailable.

## AI approach and architecture

For approved AI work, the iPad prepares a bounded request and sends it directly to the selected
provider. The approval identifies the provider, model, destination, source scope, and configured
maximum estimate. The iPad validates the response and its citations before saving an encrypted
artifact. Provider keys stay in device-only Keychain storage.

```text
iPad
  -> SQLCipher database and local outbox
  -> optional AI provider
  -> validated encrypted artifact
  -> owner review

Optional synchronization
  -> opaque encrypted sync API

Optional Compute Node
  -> explicitly selected large local models or document conversion
```

The current system supports these processing jobs:

| Job | Input | Output | AI provider required |
|---|---|---|---|
| Session digest | Evidence linked to a study session | Cited study digest | Yes |
| Note query | A selected note region, a question, and bounded note context | Cited answer and follow-up questions | Yes |
| PDF extraction | An encrypted PDF | Locally extracted text | No |
| Flashcard and test drafts | A reviewed Topic scope and frozen sources | Cited reviewable learning drafts | Yes |
| Written-answer feedback | A frozen response, rubric, and linked Evidence | Cited feedback and proposed score | Yes |
| Media transcription | One approved local media Source | Timestamped transcript segments | Yes |
| Adaptive Tutor turn | Bounded transcript, accepted learning history, and hybrid-search excerpts | Cited response and proposed learning signals | Yes |

Generated material remains a draft until the user reviews it. Accepted cards, tests, attempts,
and review schedules remain available without a network connection.

The planned assistant will support three levels of proactivity:

1. **Off** disables AI processing.
2. **Suggest** identifies useful actions on the iPad but does not send notebook content to a
   provider.
3. **Automatic for selected material** uses a revocable permission that names the Topics,
   provider route, permitted job types, frequency, expiration, and spending limit.

Opening the app will not itself send notebook content to a provider. The local study queue will
continue to work when the network, provider, or optional Compute Node is unavailable.

AI results are derived records. The user can accept, edit, reject, or delete them. They do not
replace original notes, drawings, images, PDFs, annotations, or relationships. Each reviewed
artifact records its source IDs and processing metadata.

The iPad has provider adapters for OpenAI Responses, Anthropic Messages, Gemini `generateContent`,
and OpenAI-compatible services such as Ollama, LM Studio, vLLM, and LocalAI. OpenAI and compatible
connections can also provide timestamped transcription. The optional Compute Node remains
available for explicitly selected large local models and conversion work. Provider keys are
stored in device-only Keychain storage and never enter synchronization. The user sees a
disclosure before content leaves the iPad. Provider processing remains a separate plaintext
disclosure from encrypted sync. See the public
[privacy overview](docs/public/PRIVACY.md) for the user-facing processing boundaries.

## How IBM Bob was used

IBM Bob was a core component of the project-development workflow. It was used for requirements
analysis, implementation planning, code drafts, code review, troubleshooting, tests, and
documentation updates. Its work covered the notebook data model, local-first boundaries, source
grounding, learning workflows, and verification planning.

## Project status

The repository is a personal beta candidate. Automated verification covers Core, iOS, API,
Compute Node, contracts, export, security, and documentation. Current evidence and incomplete
gates are recorded in the internal verification log and the public known-limitations document.

The following release checks are still open:

- Physical iPad durability, Apple Pencil, accessibility, and large-file tests
- Two-device synchronization and conflict tests
- Fresh-device recovery against a real server and object store
- Independent object-mirror and production restore drills
- Code signing, archive validation, and private TestFlight installation
- Physical-device import of a representative readable Epistoria export

Do not use the current build as the only convenient copy of important data. See the public
[known limitations](docs/public/KNOWN_LIMITATIONS.md) before using the beta.

## Local development

### Prerequisites

- macOS with Xcode 16.2 or later
- Node.js 24
- Python 3.13
- Docker with Compose v2
- XcodeGen 2.46.0 when regenerating the Xcode project

### Start the local services

```sh
cp .env.example .env
chmod 600 .env
make bootstrap
make infra-up
npm run prisma:deploy --workspace @epistoria/api
make api-dev
```

Open `apps/ios/Epistoria.xcodeproj`, select the `Epistoria` scheme and an iPad destination, and
run the app. A Simulator can use `http://127.0.0.1:3000/v1`. A physical iPad requires a private
HTTPS address that it can reach.

Run the automated repository gate:

```sh
make verify
```

Internal setup, deployment, backup, and troubleshooting procedures are maintained separately and
are not published in this repository.

## Cost options

| Option | Estimated recurring infrastructure cost | Limitation |
|---|---:|---|
| Personal Mac, Docker, and Tailscale Personal | $0 incremental | Remote sync stops while the personal server is unavailable; local notebook work and direct iPad processing continue |
| Small VM, provider backup, and private object storage | About $15.60 per month at the dated baseline | Requires server maintenance and recovery drills |

AI is optional and billed by the configured provider when used. Pricing assumptions must be
checked against the provider's current rates before deployment.

## Repository layout

| Path | Contents |
|---|---|
| `apps/ios` | SwiftUI iPad app and `EpistoriaCore` Swift package |
| `apps/api` | NestJS API, Prisma schema, sync log, asset broker, devices, conflicts, and encrypted jobs |
| `services/worker` | Optional Compute Node compatibility worker for accelerated local processing |
| `packages/contracts` | Versioned wire, content, AI, and cryptographic test contracts |
| `infra` | Local and personal-production infrastructure templates |
| `scripts` | Build, verification, backup, restore, retention, and worker helpers |
| `docs/public` | Client-facing product information, guides, privacy notes, and roadmap |

Use the [client-facing documentation](docs/public/README.md) for product information. Internal
engineering and operations documentation is intentionally excluded from the public repository.

## Data guarantees

- A local save and its outbox entry commit together.
- Network access is not required to create or edit local content.
- The sync service stores ciphertext and structural metadata only.
- Original files and PencilKit data remain separate from derived previews and AI output.
- Concurrent versions remain available until the user resolves the conflict.
- Version 5 and 6 readable exports can be imported only into an empty notebook. Import does not
  merge with or replace existing records.
- One Epistoria notebook connects the owner's subjects, sources, notes, sessions, and planned
  learning history. Setup does not create a second local notebook when one is configured.
