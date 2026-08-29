# Release notes

## Non-destructive image editing

- Added direct image cropping with draggable corners and common aspect-ratio presets.
- Added 90-degree rotation, rounded masks, oval masks, and live previews.
- Added replacement from Photos or Files while retaining the first encrypted image for
  restoration.
- Applied the same presentation settings to the notebook, selections, and readable PDF output.
- Updated readable export to version 7 so the displayed image and first image reference remain
  portable.

## Direct iPad AI workflows

- Moved Tutor turns, note questions, provider-backed math help, session reviews,
  written-response feedback, PDF Source guides, PDF questions, and supported media transcription
  from the Compute Node queue to direct iPad execution.
- Moved PDF text extraction and formula recognition to on-device processing.
- Added bounded image inputs for vision-capable Responses, compatible, Anthropic, and Gemini
  connections. Added direct timestamped transcription for Responses and compatible connections.
- Added strict local response and citation validation before an encrypted artifact can be saved.
- Attached the reviewed provider route to every new generated artifact and recurring automation
  permission.
- Kept the Compute Node as an optional, explicitly selected route for larger local models and
  conversion work.

## Direct Topic Studio processing

- Moved manual Topic Studio synthesis, flashcard, test, Concept, and weekly-review generation from
  the Compute Node queue to direct iPad provider execution.
- Added provider, model, destination, scope-size, and configured maximum-cost details to the final
  approval screen.
- Added strict local response validation. Unknown fields, malformed JSON, duplicate identifiers,
  unsupported Concept references, and citations outside the approved excerpts create no draft.
- Kept the provider response separate from accepted cards, tests, Concepts, and other learning
  records. Review and acceptance are still required.

## iPad-first processing and search

- Made the iPad authoritative for notebook storage, recognition, search, local processing jobs,
  and provider credentials.
- Added resumable encrypted local processing state and explicit on-device, direct-provider, and
  optional Compute Node routes.
- Replaced generic OCR indexing with dedicated recognition records and typed search segments.
- Grouped recognition matches under the owning note or Source with exact-region navigation.
- Added complete local search-index reconstruction after restore, import, or synchronization.
- Renamed the Mac worker product role to optional Compute Node and added safe removal behavior.
- Added an encrypted development backup option before confirmed local reset.
- Added a verified downloaded Core ML formula runtime. Release enablement remains gated on a real
  permissively licensed model and physical-iPad validation.

## Local OCR and formula recognition

- Added automatic local handwriting recognition after drawing becomes idle, when a page closes,
  and when the app backgrounds.
- Added local OCR for imported images and scanned PDF pages without enough embedded text.
- Added exact-region local search labels and an original-crop review screen.
- Added append-only corrections and review requirements before OCR can affect learning features.
- Added optional PP-FormulaNet_plus-S formula-to-LaTeX recognition on the trusted Mac.
- Added pinned, verified, pausable model installation under Local Processing settings.
- Added accepted handwriting to searchable note PDF text layers without changing Pencil strokes.

## Handwritten mathematics beta

- Added a Math selection tool for handwritten equations and attempted solutions.
- Added separate recognition, worked-step, graph, and error-diagnosis tasks.
- Added review and editing before an expression or explanation can be inserted into a note.
- Added local graph evaluation with a limited mathematics grammar.
- Kept original Pencil strokes unchanged and kept generated results encrypted and removable.
- Marked physical Apple Pencil quality and interaction validation as open.

## Concept and Evidence map

- Added one interactive knowledge map for each Topic.
- Added direct node arrangement, pinch and button zoom, typed connection labels, and a linear List
  view.
- Added frozen Source navigation, note insertion and backlinks, Concept relationship review, and
  grounded Tutor entry from Evidence.
- Stored only the encrypted node arrangement. Concepts, Evidence, and typed relationships remain
  independent durable records.

## Adaptive Tutor

- Added durable encrypted Tutor sessions, transcripts, cited responses, confidence, bounded
  provider approval, and reviewed learning signals.
- Added Tutor entry points in Study, Topic dashboards, and the notebook tool rail.
- Added the final standalone logo as the canonical app icon and runtime mark.
- Added Tutor records to readable notebook export.

## Automatic related search

- Kept exact text matches first.
- Added a separate Related section for material that uses different wording.
- Kept both search paths on the unlocked iPad without a paired Mac or AI provider request.
- Applied Notes, Resources, and Sessions filters before ranking results.
- Preserved exact search when related matching is unavailable for a language or device.

## Native Anthropic and Gemini connections

- Added direct Anthropic Messages and Google Gemini `generateContent` connections.
- Added native structured-output validation and optional image input for both connections.
- Fixed each native connection to its official HTTPS destination.
- Kept keys in secure device storage and provider error bodies out of saved errors and logs.
- Limited these native connections to text and optional vision. Timestamped transcription still
  requires the official Responses or a compatible connection.

## Stable provider routing

- Attached the reviewed provider connection and model to each newly approved AI request.
- Prevented an active-provider change from redirecting work that was already queued.
- Added a clear failure when the approved connection was edited or removed before processing.
- Kept API keys out of queued route details and readable exports.

## PDF source understanding

- Added PDF Source guides with cited summaries, translated summaries, key topics, suggested
  questions, and detected figure notes.
- Added grounded PDF questions with statement-level citations.
- Added citation links that open and highlight the supporting region in the exact Source Version.
- Added explicit approval before selected text or figure input reaches the configured provider.
- Added visible page and passage coverage limits for large or partially readable PDFs.

## AI provider choice

- Added provider management in Settings.
- Added the official Responses service and a compatible connection for local or hosted model
  servers.
- Added active-provider selection, model and capability settings, optional price estimates, and
  visible queue or failure state.
- Stored provider keys in secure device storage on the iPad and trusted Mac.
- Required HTTPS for remote services and limited plain HTTP to local or private-network services.
- Kept provider keys and connections out of readable notebook exports.
- Recorded the actual provider connection and model on completed generated results.

## Portable import

- Added readable export version 5 with one complete sanitized record manifest.
- Added ZIP and unpacked-directory validation before import.
- Added clean-notebook import that preserves stable records and re-encrypts original files for the
  target notebook.
- Added a review screen with source, size, and content counts before activation.
- Kept import separate from account recovery. Import does not merge with or replace existing data.

## Note organization

- Added confirmed **Remove from List** and **Remove from Session** actions.
- Kept the note, its other memberships, and Session activity history unchanged.
- Added compatibility for older notes that were created inside a Session.

## Timestamped Evidence and transcript corrections

- Added continuous transcript-range selection and timestamped Evidence creation.
- Added exact Source Version, start and end time, segment index, and correction provenance to
  transcript Evidence.
- Added durable owner corrections that preserve generated text and prior correction history.
- Added correction supersession and retraction without deleting correction content.
- Added explicit correction conflict review. The owner can keep either synced candidate or restore
  generated text; no correction is selected automatically.
- Added direct navigation from a transcript segment, Evidence, or local search result to the saved
  media position.
- Added readable export version 4 with transcript corrections in `knowledge.json` while generated
  transcript chunks remain in the optional AI artifact file.
- Verified 77 Core tests, the complete unsigned iPad Simulator build, and 43 app and UI tests.

## Source comparison and Concept connections

- Added a full-screen workspace for comparing two Sources or two immutable versions of one Source.
- Added independent Source and version selection, PDF navigation, scrolling, and local media
  controls for each comparison pane.
- Kept comparison local. It does not refresh Sources or load the YouTube player automatically.
- Added durable typed Concept connections with manual creation, optional Evidence, editing,
  explicit removal, direction, and provenance.
- Added reviewed AI proposals for Concept connections. Proposed endpoints, relationship, reason,
  and citations remain editable or excludable before acceptance.
- Added deterministic worker and encrypted-store coverage for allowed Concept IDs, citations,
  idempotent manual links, reviewed acceptance, Evidence, and generator attribution.

## Evidence cards and backlinks

- Added a note-side Evidence shelf filtered to the note's Topic.
- Added drag and Insert actions that place a non-editable Evidence card on a notebook page.
- Reused the existing Evidence record. The card retains its exact Source Version and locator.
- Added an action that opens the saved Source Version, page, and excerpt from a selected card.
- Added local backlinks for notes, Concepts, flashcards, and test questions.
- Added readable Evidence citations to note PDF export.
- Added durability, reuse, backlink, Source Version, and PDF-output tests.

## YouTube references and local media transcription

- Added normalized YouTube video references with optional start times and no downloaded media,
  captions, thumbnails, or metadata.
- Added an explicitly loaded privacy-enhanced YouTube player backed by a nonpersistent web view.
- Added trusted-Mac transcription for local MP3, M4A, WAV, and MP4 Sources up to 25 MB after a
  provider disclosure.
- Added timestamped encrypted transcript chunks and a durable manifest bound to the exact Source
  Version.
- Added transcript search, accept and reject review states, and accepted-transcript export as
  optional derived data.
- Added readable YouTube URL files to the portable export.
- Added URL, unsafe-link, no-media-asset, no-partial-record, transcript contract, worker identity,
  size, dedupe, legacy compatibility, durable retrieval, and export coverage.

## Shared Google file Sources

- Added direct capture for native Google Docs, Slides, and Sheets share links that allow anyone
  with the link to view.
- Added credential-free export requests through an ephemeral session without cookies, stored
  credentials, or a Google SDK.
- Added bounded streaming and DOCX, PPTX, or XLSX package validation before Source creation.
- Preserved the exact Google export as an encrypted original and immutable Source Version.
- Added offline readable text, manual refresh, readable-text change summaries, and earlier-version
  selection.
- Added exact-byte, URL, endpoint, privacy-header, access-denied, malformed, oversized, offline,
  persistence, refresh, no-partial-record, and readable-export tests.

## Webpage Sources

- Added manual HTTPS webpage capture from Library.
- Added bounded streaming, response-status and content-type checks, URL validation, and HTML
  validation before any Source record is created.
- Added local readable-text extraction that excludes scripts, styles, and inactive page content.
- Preserved the exact HTML response as an encrypted original with canonical and captured URLs.
- Added manual refresh with immutable versions, readable paragraph changes, and earlier-version
  selection.
- Added malformed, binary, empty, unsupported, oversized, offline, exact-byte, refresh, and
  no-partial-record tests.

## Local video Sources

- Added MP4, M4V, and MOV import from every Source entry point.
- Added bounded ISO media-container validation and required system video decoding before any
  Source record is created.
- Added local playback with the standard iPad video controls.
- Added protected, backup-excluded playback files with cleanup on reader close, notebook lock,
  and interrupted-session recovery.
- Preserved exact video bytes as encrypted originals and immutable Source Versions.
- Added decoder, spoof, truncation, exact-byte, protected-file isolation, encrypted import, and
  no-partial-record tests.

## Local audio Sources

- Added MP3, M4A, AAC, WAV, and CAF import from every Source entry point.
- Added bounded format validation and system decoding before any Source record is created.
- Added local playback with play, pause, seeking, 15-second skip, elapsed time, remaining time,
  VoiceOver labels, and no decorative playback animation.
- Preserved exact recordings as encrypted originals and immutable Source Versions.
- Kept transcription separate from playback. Import and listening do not require a provider or a
  paired Mac.

## Packaged document Sources

- Added local import for EPUB, DOCX, ODT, PPTX, ODP, and XLSX files.
- Added bounded archive validation before Source creation. Imports reject unsafe paths, links,
  duplicate entries, invalid checksums, excessive expansion, missing package parts, and incorrect
  document identities.
- Added local readable-text views for books, word-processing documents, presentations, and
  spreadsheets. Large parsing work runs outside the interface rendering path.
- Preserved the exact original file as an encrypted Source and immutable Source Version.
- Added readable text derivatives for supported Sources to the full notebook export.

## CSV Sources

- Added CSV import from Today, Library, and Topic dashboards.
- Added validation for UTF-8, quoted fields, embedded commas and newlines, escaped quotes, row and
  column limits, and a 32 MB file limit before any Source record is created.
- Added a local scrollable table with a pinned header, row numbers, text selection, and
  accessibility row labels.
- Preserved the exact CSV file as an encrypted original and created an immutable Source Version.
- Added CSV refresh with the same type and validation checks used during import.

## Local weekly review

- Added a weekly review in Study that is calculated on the iPad without AI.
- Added totals for focused time, completed sessions, card reviews, submitted tests, and average
  test score from the last seven days.
- Added Topic-level difficult-material signals from Hard or Again card ratings, incorrect test
  answers, and low-confidence test answers.
- Added open questions, overdue and upcoming goals, card reviews due within seven days, and three
  suggested next actions.
- Added direct links from each review row to its Topic, goal, unresolved question, or recommended
  work item.

## Scoped proactive automation

- Added explicit recurring permissions for selected Topics and supported AI tasks.
- Added per-Topic/task cadence, expiration, and recorded USD spending limits.
- Added pause, resume, edit, permanent revocation, queue history, and cost status.
- Added automatic checks after local changes and during normal periodic synchronization.
- Added deterministic job identities and unchanged-input suppression.
- Added trusted-Mac validation for Topic, task, cadence, expiration, and spending limits before
  provider processing.
- Kept every automatic result in the existing cited draft review flow.

## Cited written-response feedback

- Added an optional feedback request for submitted written test responses.
- Added a preflight disclosure for the frozen question, grading guide, reference answer,
  submitted response, confidence, linked Evidence, and approximate token count.
- Added source-cited feedback with strengths, improvements, uncertainty, and a proposed score.
- Added local editing, acceptance, rejection, repeated requests, and durable citation storage.
- Added a separate per-question owner score override with a required reason.
- Preserved the submitted response, deterministic correctness result, original attempt score, and
  immutable provider response.

## Study Next destinations and history

- Added direct destinations for due cards, paused sessions, unfinished attempts, tests, goals,
  unresolved questions, and Topic fallback.
- Added durable open events and a visible append-only response history.
- Added Restore for pinned, snoozed, dismissed, and not-relevant responses without deleting the
  earlier action.
- Added response snapshots for title, kind, Topic, and target while retaining v1 response reads.
- Prevented persisted local response anchors from returning as stale duplicate recommendations.
- Fixed non-local recommendations to use their declared target instead of their recommendation
  record ID.

## Test planning and coverage

- Added Comprehensive, Quick Check, and Custom modes for manual and generated tests.
- Added local objective detection from Topic Concepts, Sources, notes, and unresolved questions.
- Added pre-generation review for objectives, question count, time limit, coverage dimensions,
  excerpt count, and approximate token count.
- Added a versioned encrypted test plan that survives worker processing and accepted-test
  materialization.
- Added planned-versus-generated question counts, objective-level coverage state, and retained
  provider coverage notes in saved test details.
- Added case-insensitive objective matching so capitalization changes during review do not create
  duplicate objective keys or crash acceptance.

## Item-level AI draft review

- Added item-by-item selection and exclusion for generated cards, test questions, and Concepts.
- Added editing for prompts, answers, rubrics, objectives, choices, names, and descriptions before
  acceptance.
- Preserved the original provider response while storing the reviewed working copy as encrypted
  artifact data.
- Materialized only selected items and retained idempotent acceptance.

## Learning record lifecycle update

- Added Manage Learning for goals, unresolved questions, decks, cards, Concepts, and tests.
- Added card revisions, suspension, archive, restore, and deck assignment without erasing review
  history.
- Added Source title, Topic, related Topic, List, archive, and restore controls.
- Added List rename, move, archive, and restore controls with backward-compatible encrypted data.

## Personal beta candidate

Release date: Not published.

### Notebook

- Added A4, US Letter, and infinite note formats.
- Added portrait and landscape fixed pages.
- Added a continuous vertically scrolling document for numbered fixed pages.
- Added a persistent custom tool rail with Pen, Marker, Eraser, stroke size, Text, Image, page,
  and ink history controls.
- Added a pixel eraser with an adjustable circular width and a whole-stroke eraser.
- Added repeated-tap options for the selected Pen, Marker, Eraser, Shape, and Symbol tools.
- Added live rectangular previews for ink width and color, eraser footprint or behavior, shape
  style, and the selected math symbol.
- Added neutral page colors, adjustable pattern spacing, and isometric paper.
- Added durable vector shapes with outline, fill, and line-width options.
- Added an editable math-symbol palette for algebra, calculus, Greek, sets, logic, and comparisons.
- Stored Pencil writing separately per fixed page to limit the data rewritten during editing.
- Added plain, ruled, grid, and dotted paper.
- Added editable Apple Pencil writing above text and images.
- Added movable, resizable, rotatable, and layered text and images.
- Added immersive note presentation in the iPad detail area.
- Fixed a crash that could occur while opening or creating a note.
- Stabilized the note tools while the immersive editor opens.
- Refit fixed pages when the editor first appears or changes size so page one uses the available
  width consistently.
- Added readable note PDF export with fixed-page dimensions, text, math symbols, vector shapes,
  images, paper appearance, and Pencil ink.

### Study and organization

- Added Today actions and recent work.
- Added Areas, Topics, and reusable cross-Topic Lists.
- Added existing notes to sessions through durable references instead of copies.
- Kept Quick Notes unassigned until the user organizes them.
- Added note page miniatures and content excerpts to review lists.
- Added Planned, Active, Paused, Ended, and Abandoned session states with one active timer.
- Added removable session activity history for notes and Sources.
- Added note and Topic archive and restore.
- Added local search with direct note and PDF destinations.

### Sources

- Added encrypted PDF, image, plain-text, Markdown, HTML, CSV, XLSX, DOCX, PPTX, EPUB, ODT, and
  ODP import.
- Added Library Inbox, type filters, Topic filters, and immutable Source refresh versions.
- Added page navigation and separate annotations.
- Added reusable Evidence linked to the exact Source Version.
- Added optional local text extraction on a paired Mac.

### Optional assistance

- Added cited study-session digests.
- Added selected-region questions for text, images, and handwriting.
- Added disclosure before a question is queued.
- Added review, edit, accept, reject, and insert actions for generated answers.
- Added Topic Studio for reviewed Topic synthesis, card drafts, test work, Concept suggestions,
  and weekly review requests.

### Learning

- Added durable manual flashcards, card revisions, append-only reviews, and an offline scheduler.
- Added coverage-first tests, frozen attempts, autosaved responses, confidence, scoring, and
  attempt review filters.
- Added local Study Next recommendations with explanations.
- Added manual Concepts, goals, unresolved-question records, recommendation records, and scoped
  automation grants.

### Privacy and portability

- Added optional encrypted synchronization.
- Added concurrent-version review and device revocation.
- Added account recovery with 24 words and setup verification.
- Added readable export version 3 with taxonomy, Source Versions, Evidence, Concepts, learning
  records, original files, and checksums.

### Setup and recovery

- Prevented new setup from trying to open an older local notebook with a newly generated recovery
  kit.
- Kept one notebook account for all subjects on an iPad.
- Prevented new setup from replacing a valid or unreadable local account configuration.
- Replaced internal setup error codes with readable, non-destructive guidance.

### Interface

- Added a monochrome interface.
- Replaced the app icon with a white background and one centered dark circle.
- Improved onboarding, Today, status language, and accessibility behavior.

### Current limits

See [Known limitations](KNOWN_LIMITATIONS.md).
