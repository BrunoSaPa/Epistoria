# Features

Epistoria combines notebook and study workflows in one iPad app. The following features describe
the current personal beta.

## Spatial notebooks

- Choose A4 or US Letter paper in portrait or landscape orientation.
- Use an infinite canvas when a fixed page is not appropriate.
- Select plain, ruled, grid, dotted, or isometric paper.
- Choose compact, standard, or wide pattern spacing and a neutral page color.
- Scroll through fixed-paper pages as one continuous vertical document.
- Jump directly to a numbered page or append a blank page from the persistent tool rail.
- Switch between Select, Pen, Marker, Eraser, Text, Image, Shape, Symbol, and undo controls without
  opening the system Pencil palette.
- Choose a pixel eraser with an adjustable circular width or a stroke eraser that removes a
  complete Pencil stroke.
- Tap a selected Pen or Marker again to change its width and color.
- See a live sample of Pen, Marker, Eraser, Shape, and Symbol settings before using them.
- Place rectangles, rounded rectangles, ellipses, triangles, diamonds, lines, and arrows. Choose
  outline color, fill, and line width before placement.
- Place editable algebra, calculus, Greek, set, logic, and comparison symbols.
- Write anywhere with Apple Pencil.
- Add typed text and images.
- Move, resize, rotate, and reorder text, images, shapes, and symbols.
- Write over text and images without flattening the underlying material.
- Open a note in an immersive workspace that uses the full iPad detail area.
- Keep Pencil data separate by page so editing one page does not rewrite the complete note.
- Export one note as a readable PDF that includes its paper, typed text, math symbols, vector
  shapes, images, and Pencil ink.

## Sources

- Keep an Inbox for Sources that have not been assigned to a Topic.
- Import PDFs, images, plain text, Markdown, HTML, CSV, XLSX, DOCX, PPTX, EPUB, ODT, and ODP
  files.
- Read CSV files in a local table with a pinned first row, row numbers, selectable text, and
  horizontal and vertical scrolling. The original CSV bytes remain unchanged.
- Read EPUB, word-processing, presentation, and spreadsheet text locally without uploading the
  Source. The original package remains unchanged.
- Import MP3, M4A, AAC, WAV, and CAF recordings after local format and system-decoder validation.
- Play a recording locally with seek, 15-second skip, elapsed time, and remaining time controls.
- Import MP4, M4V, and MOV video after bounded container checks and system-decoder validation.
- Play video locally with the standard iPad controls. Playback files use complete file protection
  and are removed when the reader closes or the notebook locks.
- Capture an HTTPS webpage as a bounded, encrypted HTML snapshot without cookies or a
  persistent browser session.
- Read extracted webpage text offline. Scripts, styles, and inactive page content are not shown.
- Refresh a webpage only when requested. Each refresh creates an immutable Source Version and
  shows added and removed readable paragraphs. Earlier versions remain selectable.
- Add a Google Doc, Slides presentation, or Sheet from a `docs.google.com` share link when the
  file allows anyone with the link to view it.
- Store the Google-provided DOCX, PPTX, or XLSX export as the encrypted original and read its
  extracted text offline.
- Refresh a Google file only when requested. Each refresh creates an immutable version, reports
  readable-text changes, and leaves earlier versions selectable.
- Add one YouTube video as a normalized link without downloading its video, captions, or metadata.
- Load the privacy-enhanced YouTube player only after an explicit action. Unloading the player
  clears the temporary nonpersistent web view.
- Request an optional timestamped transcript for a local MP3, M4A, WAV, or MP4 Source up to 25 MB.
  The approval explains that the trusted Mac decrypts the Source and sends its media bytes to the
  configured AI provider.
- Store transcript segments as encrypted derived records bound to the exact Source Version.
  Search, accept, reject, or correct the transcript without changing the original media or
  provider-generated text.
- Select one segment or a continuous range and create reusable Evidence with the exact start and
  end time. The Evidence keeps the frozen reviewed excerpt, Source Version, segment indexes, and
  correction references.
- Open a transcript segment or timestamped Evidence at its saved position in the local media
  player.
- Keep every transcript correction as an encrypted owner record. New corrections supersede the
  active correction and retain prior history. Retraction restores generated text without deleting
  the correction.
- Filter the Library by Source type and Topic.
- Keep the original PDF unchanged.
- Refresh a Source by creating a new version. Older citations continue to use the earlier version.
- Add separate page annotations.
- Keep annotations as reusable Evidence linked to the exact Source Version.
- Open the Evidence shelf in a note. Drag Evidence to a page or select **Insert**. The note stores
  a reference to the existing Evidence record instead of copying it.
- Open an Evidence card's original Source at the saved Source Version and locator.
- Review note, Concept, flashcard, and test-question backlinks from the Evidence shelf.
- Compare two Sources or two immutable versions of one Source in a full-screen local workspace.
  Each side keeps its own Source, version, PDF page, scroll position, and media controls.
- Edit a Source title, primary Topic, related Topics, and Lists. Archive and restore a Source
  without changing its immutable versions or citations.
- Navigate directly to an annotated or searched page.
- Optional: extract PDF text on a paired Mac without using an AI provider.
- Optional: create a PDF Source guide with a cited summary, translated summary, key topics,
  suggested questions, and notes about detected images or figures.
- Ask a question about one PDF. Each answer statement links to the supporting page and highlighted
  region in the exact Source Version used for the answer.
- See a coverage notice when a large PDF cannot fit in one analysis pass.
- Turn figure input off for a text-only provider or a lower-cost text-only request.

## AI providers

- Choose the official Responses service, Anthropic, Gemini, or a compatible local or hosted AI
  provider from Settings.
- Review the provider destination and model before approving generated work.
- Keep the approved provider connection and model attached to the queued request. Changing the
  active provider later does not reroute it.
- Stop an older queued request if its approved provider connection was edited or removed. Submit
  it again after reviewing the new settings.
- Keep provider keys in secure device storage and out of notebook exports.

## Organization

- Keep subjects in one connected private notebook.
- Use Areas to group Topics such as Mathematics, Politics, or Design.
- Use Topics for any subject, whether or not it belongs to a school.
- Add optional institution, term, official class name, code, professor, and dates to a Topic.
- Use Lists as reusable cross-Topic groups. A note can appear in more than one List without
  being copied.
- Rename, move, archive, and restore Lists while preserving linked records.
- Create a Quick Note without assigning it, then add it to Lists or sessions later.
- Remove a note from one List or Session without deleting the note, its other links, or Session
  activity history.
- Review notes with a page miniature, content excerpt, page count, and save state.
- Link notes, Sources, Concepts, cards, tests, and study sessions to a Topic.
- Archive and restore notes and Topics.
- Return to recent notes and resources from Today.

## Study sessions

- Plan, start, pause, resume, end, or abandon a Topic study period.
- Keep only one active timer.
- Add new or existing notes and resources to the session. A session references the original note
  and preserves which material was used together.
- Review a removable activity timeline without deleting the underlying notes or Sources.
- Optional: request a cited session digest after the session.
- Review, edit, accept, or reject a generated digest.

## Search

- Search notes, resources, PDF text, annotations, and sessions on the iPad.
- Filter results by content type.
- See exact text matches first and related results in a separate section.
- Find related material when the query uses different wording from the note or Source.
- Open the matching note item or PDF page when a precise location is available.
- Use related search without a network connection, paired Mac, or configured AI provider.

## Selected-region questions

- Draw a boundary around text, handwriting, or images in a note.
- Ask a question about the selected area.
- Review what will be processed before approving the request.
- Receive an answer with references to the selected notebook material.
- Accept, edit, reject, or insert the answer as new note text.

This feature requires a paired Mac and a configured AI provider. It is optional.

## AI provider choice

- Add, edit, activate, and remove provider connections from Settings.
- Use the official Responses service, Anthropic, Gemini, or a compatible local or hosted service.
- Keep provider keys in secure device storage on the iPad and trusted Mac.
- See the destination host and model before choosing the active provider.
- Use unencrypted HTTP only for a local or private-network service. Remote services require HTTPS.
- Declare vision and transcription support only when the selected service provides them.
- Use Anthropic and Gemini native connections for text and optional vision. Timestamped media
  transcription currently requires the official Responses or a compatible connection.
- Keep provider connections and keys out of readable notebook exports.
- Record the actual provider connection and model on each completed generated result.

## Learning

- Create and manage flashcard decks.
- Edit cards by creating durable revisions. Suspend or archive cards without deleting reviews.
- Edit goals and unresolved questions. Mark goals completed and questions resolved or reopen them.
- Edit and archive Concepts and tests. Archived tests retain attempts and frozen questions.
- Connect two Concepts with a typed relationship, an explanation, and optional reusable Evidence.
  Edit or remove the connection without changing either Concept or its Evidence.

- Create durable manual flashcards in eight card formats.
- Review due cards with a deterministic offline schedule and append-only history.
- Create coverage-first tests from an explicit objective list.
- Choose Comprehensive, Quick Check, or Custom for manual and generated tests.
- Detect proposed test objectives from local Topic Concepts, Sources, notes, and unresolved
  questions before generation. Review the list before approving provider processing.
- Set a question count and optional time limit. Custom tests can select prerequisite, conceptual,
  method-selection, procedural, verification, error-analysis, and integrated coverage.
- Keep the requested test plan on the encrypted artifact and durable test blueprint.
- Compare generated questions with the requested count and objective list. Review uncovered
  objectives and provider-reported source, dimension, count, or time constraints.
- Store test questions, frozen attempts, autosaved responses, confidence, timing, scores, and
  score overrides.
- Review all, incorrect, skipped, or low-confidence responses after a test.
- Request optional source-cited feedback for a submitted written response. Review the exact data
  included before paid processing.
- Edit, accept, or reject generated feedback. Accepted feedback stores strengths, improvements,
  uncertainty, citations, and a proposed question score without changing the submitted answer or
  original calculated result.
- Store a separate owner override and required reason for an individual question. The AI proposal
  remains in history.
- Use Study Next offline to rank due cards, goals, unresolved questions, paused sessions, and
  unfinished tests with a visible reason.
- Pin, snooze, dismiss, or mark a Study Next recommendation as irrelevant.
- Open a recommendation at its due card, paused session, unfinished attempt, test, goal, or
  unresolved question when that record remains available.
- Review append-only Study Next response history. Restoring a suppressed recommendation adds a new
  response without deleting the earlier action.
- Open **Study → Week** for an offline summary of the previous seven days and the next seven days.
- Review focused time, completed sessions, card reviews, submitted tests, average test score,
  difficult Topics, unresolved questions, dated goals, scheduled card reviews, and three suggested
  next actions.
- Open each weekly review row at the related Topic, goal, unresolved question, or recommended work
  item. Difficult-material signals remain separate counts for card ratings, incorrect answers,
  and low-confidence answers.
- Use Topic Studio to review the exact Topic scope before requesting cited synthesis, flashcard
  drafts, test work, Concept suggestions, or a weekly review.
- Review generated flashcards, test questions, Concepts, and proposed Concept connections one item
  at a time. Edit their
  content, include supported items, and exclude unsupported items before acceptance.
- Accept selected items to create first-class encrypted learning records in one transaction while
  retaining the unchanged provider response and reviewed working copy.
- Keep the current Topic as the default AI scope. Include connected Topics only when selected.
- Keep Study Next in local Suggest mode without provider processing.
- Create an optional recurring automation permission for selected Topics and supported tasks.
- Set a minimum interval for each Topic/task pair, an expiration date, and a USD spending limit.
- Pause, resume, edit, or permanently revoke a permission. Nonterminal jobs are cancelled when the
  private service is reachable. Completed drafts remain available for review.
- Avoid another automatic request when the allowed input has not changed. Automatic results use
  the same cited draft review and acceptance flow as manual requests.

## Offline use and synchronization

- Create and edit local content without a network connection.
- See separate status for local save and private synchronization.
- Optional: synchronize encrypted content through a private server.
- Review concurrent versions instead of allowing the app to discard one automatically.
- Review and revoke paired devices.

## Recovery and portability

- Recover the account key with the account ID and 24 recovery words.
- Prevent new setup from replacing the configured notebook.
- Verify selected recovery words during initial setup.
- Create a readable export with standard files and checksums.
- Preserve original Sources, images, rich text, and Pencil data in the export.
- Include local readable text copies for supported text and packaged-document Sources.
- Include a readable URL file for each YouTube reference. Include accepted transcript manifests
  and chunks when derived AI records are selected for export.
- Include transcript corrections and timestamped Evidence in `knowledge.json`. Generated
  transcript chunks remain separate in `ai-artifacts.json`.
- Import a validated version 5 export into an empty notebook. Stable records and original files
  are encrypted for the target notebook before activation.

Import does not merge with or replace existing notebook data. See
[Known limitations](KNOWN_LIMITATIONS.md).

## Accessibility and input

- Supports Light and Dark Mode.
- Uses Dynamic Type and VoiceOver labels in the main interfaces.
- Supports keyboard shortcuts and pointer input where applicable.
- Honors Reduce Motion for custom interface movement.
- Uses text and symbols, not color alone, for status.

Physical-device accessibility review remains part of the beta work.
