# Roadmap

This roadmap describes intended product direction. It is not a delivery schedule. Priorities can
change after personal use and beta testing.

## Before broader use

- Complete physical iPad testing for Pencil, large notes, large PDFs, accessibility, orientation,
  multitasking, keyboard, and pointer input.
- Complete two-device synchronization and concurrent-version testing.
- Complete fresh-device recovery and independent backup drills.
- Complete private installation and update testing.
- Test version 7 clean-notebook import on a physical spare iPad with representative data.

## Portability and file access

- Define safe merge behavior before allowing import into a notebook that already contains data.
- Download selected or all restored files for offline use.
- Improve archive and restore support for Sources and Lists.
- Validate permanent Trash deletion, protected dependencies, encrypted asset reclamation, and
  two-device restoration on physical devices.

## Notebook tools

- Add editing for an existing shape's style, connectors, snapping, and alignment guides.
- Evaluate square, angled, and custom eraser footprints after physical Apple Pencil testing.
- Validate handwritten-math recognition, result review, graph interaction, and original-stroke
  preservation on physical Pencil-capable iPads. Validate local handwriting and formula OCR for
  English, Spanish, representative notation, ruled and grid paper, memory, energy, rotation,
  multitasking, and VoiceOver before enabling automatic formula recognition by default. Evaluate
  a full equation-layout editor and direct LaTeX input separately.

## Review and learning

The personal beta now includes Areas, Topics, Sources with versions, reusable Evidence, manual
Concepts, sessions, flashcards, tests, attempt history, local Study Next, reviewed Topic Studio
requests, and lifecycle controls for durable learning records.

Completed:

1. Goals, unresolved questions, decks, cards, Concepts, tests, Sources, and Lists can be edited,
   completed, resolved, suspended, archived, restored, or reorganized as appropriate. Card edits
   create revisions. Archived tests keep their attempts. Legacy Lists upgrade with a recovery
   backup when first edited.
2. Generated flashcards, test questions, and Concepts can be reviewed item by item. Items can be
   edited, included, or excluded before acceptance. Only selected items become durable records.
   The original generated response remains unchanged for provenance.
3. Quick Check, Comprehensive, and Custom test plans are available for manual and generated
   tests. Topic Studio detects proposed objectives from local Topic records before generation.
   The reviewed plan stores question count, optional time limit, coverage dimensions, and
   objective scope. Accepted tests show uncovered objectives and provider-reported gaps.
4. Study Next opens the exact due card, paused session, unfinished attempt, test, goal, or
   unresolved question when available. Pin, snooze, dismiss, not-relevant, open, and restore
   actions remain as durable response history.
5. Submitted written answers can request source-cited feedback. The request disclosure lists the
   frozen question, grading guide, reference answer, submitted response, confidence, and linked
   Evidence. Generated feedback includes strengths, improvements, uncertainty, citations, and a
   proposed score. Review, edit, accept, reject, and owner score override are durable. The saved
   response and original calculated result remain unchanged.
6. Proactive automation is opt-in and limited by selected Topics, supported tasks, per-scope
   cadence, expiration, and a recorded USD spending cap. Permissions can be paused, resumed,
   edited, or revoked. Unchanged inputs keep a deterministic job identity and are not regenerated.
   Automatic results remain reviewable drafts.
7. Study includes a local weekly review for completed work, difficult material, unresolved
   questions, overdue and upcoming work, scheduled reviews, and three suggested next actions.
   The review opens the related durable record and does not require AI.
8. CSV files import as encrypted immutable Sources after defensive local validation and render in
   a scrollable local table. Malformed and oversized files create no partial Source record.
9. EPUB, DOCX, ODT, PPTX, ODP, and XLSX files import after bounded package validation. Their
   readable text is available locally while the original file remains unchanged.
10. AI provider connections can be managed from Settings. The current choices include the
    official supported service and compatible local or hosted services. Keys stay in secure
    device storage and completed results identify the provider connection and model used.
11. MP3, M4A, AAC, WAV, and CAF recordings import after local format and decoder validation and
    play from decrypted memory on the iPad.
12. MP4, M4V, and MOV files import after bounded container and decoder validation. Video uses
    protected local playback files that are excluded from backup and removed after use.
13. HTTPS pages can be captured manually as bounded encrypted HTML snapshots. Readable
    text is available offline. Manual refresh creates an immutable version, reports readable-text
    changes, and keeps earlier versions selectable.
14. Shared Google Docs, Slides, and Sheets can be captured through native share links as bounded
    DOCX, PPTX, or XLSX exports. Originals are encrypted, readable text works offline, and manual
    refresh keeps immutable earlier versions and reports readable-text changes.
15. YouTube videos can be stored as normalized online references and opened through an explicitly
    loaded privacy-enhanced player. Local MP3, M4A, WAV, and MP4 Sources up to 25 MB can request
    timestamped trusted-Mac transcription after provider disclosure. Accepted transcripts remain
    encrypted, Source-Version-bound, and exportable as derived data.
16. Evidence can be opened from a note-side shelf, dragged or inserted onto a page, and reused
    without copying the Evidence record. Inserted cards retain their Source Version and locator,
    return to the original Source, list backlinks, and include a readable citation in note PDF
    export.
17. Any two Sources, or two immutable versions of one Source, can be opened in a full-screen local
    comparison workspace. Concepts support durable typed connections with optional Evidence,
    manual editing and removal, and reviewed source-cited AI proposals.
18. Transcript segments can be corrected through separate encrypted owner records without
    changing generated chunks. One segment or a continuous range can become timestamped Evidence
    with frozen reviewed text, exact Source Version, segment indexes, correction references, and
    direct local-player navigation.
19. PDF Sources can create a cited source guide with summary, translation, key topics, suggested
    questions, and detected figure notes. Source questions return statement-level citations that
    open the supporting page and region in the exact Source Version. Large-source coverage limits
    remain visible.
20. Newly approved AI work keeps an encrypted, non-secret snapshot of the reviewed provider
    connection and model. Later activation of another provider cannot reroute queued work. An
    edited or removed connection stops older work and requires a new approval.
21. Anthropic Messages and Google Gemini `generateContent` can be configured directly. Both use
    fixed official HTTPS destinations, Keychain credentials, native JSON Schema output, optional
    image input, and the same encrypted route and artifact boundaries as other providers.
22. Search automatically combines exact text results with a separate related-results section.
    Both run on the iPad. Exact results remain available when related matching is unavailable.
23. The Adaptive Tutor keeps encrypted session transcripts, uses cited automatic hybrid-search
    excerpts, adapts its next activity from accepted learning signals, and requires bounded
    provider approval. It is available from Learning, Topics, and the notebook.
24. Each Topic has an interactive Concept and Evidence map. Node arrangement is encrypted and
    durable. Evidence can open its exact Source, appear in a note, show its typed Concept
    relationships, or start a grounded Tutor session.
25. A notebook Math tool can recognize selected handwriting, propose worked steps, plot a bounded
   function locally, and diagnose errors. Results require review and never replace original
   Pencil strokes.
26. Local OCR recognizes changed notebook ink and imported images with Apple Vision. Dedicated
   recognition records provide labeled search matches and exact-region return. A downloaded Core
   ML formula runtime is implemented but remains disabled until a permissively licensed model
   passes accuracy and physical-iPad performance gates. A Mac is optional as a Compute Node.
27. Manual Topic Studio generation runs directly from the iPad for synthesis, flashcard drafts,
   test blueprints and questions, Concept suggestions, and weekly-review drafts. Approval shows
   the provider, model, destination, bounded scope, and configured maximum estimate. The iPad
   validates the complete response and every citation before saving an encrypted draft.
28. Tutor turns, note questions, Source guides and questions, session reviews, written-response
   feedback, and provider-backed math help run directly from the iPad. PDF text extraction and
   formula recognition use on-device processing. Approved local-media transcription also starts
   from the iPad. The optional Compute Node remains available only when explicitly selected.
29. Recurring automation permissions freeze the approved provider route and execute due work from
   the iPad under the saved Topic, task, cadence, expiration, and spending limits.
30. Optional deadline-aware learning plans extend dated goals with owner-managed coverage,
   selected study days, preferred daily minutes, missed-work catch-up, linked test evidence, and
   explained local readiness. Simple goals remain unchanged.

Next stages:

1. Validate related-result quality, performance, battery use, VoiceOver, and direct Source
   navigation during representative daily use on a physical iPad.
2. Validate direct-provider retries, background interruption recovery, cancellation, cost
   accounting, local-network endpoints, and provider compatibility on a physical iPad.

## Competitor-informed opportunities

The next product work is ordered by learning value. An item remains here until it is available in
the app.

### Next

- Add a daily Evidence review that can resurface highlights, difficult Concepts, and earlier
  mistakes without AI. Add reusable Studio recipes defined by the notebook owner. This direction
  is informed by Readwise.

### Later

- Add cited audio briefs and optional spoken Tutor sessions. Start with one clear narrator. Do not
  simulate a podcast conversation.
- Add source-grounded slide decks, infographics, and visual explanations. Every revision must
  remain bound to the Source Versions used to create it.

### Explore

- Evaluate sandboxed spreadsheet and dataset analysis on an optional Compute Node. File, network, and code
  execution permissions must be explicit and revocable.

## More subjects

A future subject suggestion control will separate three requests:

1. Find gaps inside the current Topic.
2. Suggest prerequisite or adjacent Topics from accepted Concepts and notebook Evidence.
3. Find external material through reviewed source discovery.

External results will not create Topics or Sources until the user selects them.

Opening the app will not by itself send notebook content for processing. Review scheduling and the
base daily queue will run on the iPad without paid processing.

## Companion experiences

- Add an iPhone quick-capture option.
- Add a simple Mac status view for processing and synchronization health.

## Outside the current scope

The personal project does not currently plan collaboration, public sharing, social features,
subscriptions, billing, or organization administration.
