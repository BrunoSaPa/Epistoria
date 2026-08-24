# Roadmap

This roadmap describes intended product direction. It is not a delivery schedule. Priorities can
change after personal use and beta testing.

## Before broader use

- Complete physical iPad testing for Pencil, large notes, large PDFs, accessibility, orientation,
  multitasking, keyboard, and pointer input.
- Complete two-device synchronization and concurrent-version testing.
- Complete fresh-device recovery and independent backup drills.
- Complete private installation and update testing.
- Test version 5 clean-notebook import on a physical spare iPad with representative data.

## Portability and file access

- Define safe merge behavior before allowing import into a notebook that already contains data.
- Download selected or all restored files for offline use.
- Improve archive and restore support for Sources and Lists.
- Add a persistent Trash with a clear retention policy.

## Notebook tools

- Add page thumbnails, insertion, duplication, deletion with recovery, and ordering to the
  continuous fixed-page document.
- Add direct printing and PDF page-range and layout options.
- Add image crop and mask tools.
- Add editing for an existing shape's style, connectors, snapping, and alignment guides.
- Evaluate square, angled, and custom eraser footprints after physical Apple Pencil testing.
- Evaluate handwriting recognition, handwritten-math recognition, equation layout, LaTeX input,
  and graphing after Pencil testing.

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
10. MP3, M4A, AAC, WAV, and CAF recordings import after local format and decoder validation and
    play from decrypted memory on the iPad.
11. MP4, M4V, and MOV files import after bounded container and decoder validation. Video uses
    protected local playback files that are excluded from backup and removed after use.
12. HTTPS pages can be captured manually as bounded encrypted HTML snapshots. Readable
    text is available offline. Manual refresh creates an immutable version, reports readable-text
    changes, and keeps earlier versions selectable.
13. Shared Google Docs, Slides, and Sheets can be captured through native share links as bounded
    DOCX, PPTX, or XLSX exports. Originals are encrypted, readable text works offline, and manual
    refresh keeps immutable earlier versions and reports readable-text changes.
14. YouTube videos can be stored as normalized online references and opened through an explicitly
    loaded privacy-enhanced player. Local MP3, M4A, WAV, and MP4 Sources up to 25 MB can request
    timestamped trusted-Mac transcription after provider disclosure. Accepted transcripts remain
    encrypted, Source-Version-bound, and exportable as derived data.
15. Evidence can be opened from a note-side shelf, dragged or inserted onto a page, and reused
    without copying the Evidence record. Inserted cards retain their Source Version and locator,
    return to the original Source, list backlinks, and include a readable citation in note PDF
    export.
16. Any two Sources, or two immutable versions of one Source, can be opened in a full-screen local
    comparison workspace. Concepts support durable typed connections with optional Evidence,
    manual editing and removal, and reviewed source-cited AI proposals.
17. Transcript segments can be corrected through separate encrypted owner records without
    changing generated chunks. One segment or a continuous range can become timestamped Evidence
    with frozen reviewed text, exact Source Version, segment indexes, correction references, and
    direct local-player navigation.

Next stages:

1. Evaluate optional local semantic search after daily use shows a retrieval gap.

Opening the app will not by itself send notebook content for processing. Review scheduling and the
base daily queue will run on the iPad without paid processing.

## Companion experiences

- Add an iPhone quick-capture option.
- Add a simple Mac status view for processing and synchronization health.

## Outside the current scope

The personal project does not currently plan collaboration, public sharing, social features,
subscriptions, billing, or organization administration.
