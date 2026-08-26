# Known limitations

Epistoria remains in personal beta. The following limits apply to the current product direction.

## Availability

- The app is not available for public download.
- Private installation and update testing is not complete.

## Recovery and export

- The app imports only version 5 readable exports and only into an empty notebook. It does not
  merge with or replace existing data. Versions 1 through 4 must be recreated before import.
- An export with an unresolved binary file conflict cannot be imported until that conflict is
  resolved in the source notebook.
- A note can be exported as a readable PDF. The PDF cannot be imported as an editable note.
- An infinite note exports its used area as one custom-size PDF page. Very large infinite notes
  are scaled to the PDF page-dimension limit.
- Restored files download when first opened. There is no bulk offline-download action.
- Full fresh-device and independent-backup recovery tests remain in progress.
- Epistoria supports one private notebook account per installation. Different subjects belong in
  that connected notebook.

## Notebook

- Fixed notes scroll continuously and support page jump and append. They do not yet have
  thumbnails, insertion, duplication, deletion, or reordering.
- Very large Pencil documents have a current per-page ink limit.
- The pixel eraser has a round adjustable footprint. Square, angled, and custom eraser tips are
  not available. Whole-stroke erasing remains a separate mode.
- Image crop, masks, general handwriting recognition, and direct printing are not available.
- Shapes support placement, movement, resizing, rotation, outline, optional fill, and PDF output.
  Existing shape style cannot yet be changed after placement.
- Math symbols and accepted recognized expressions are editable text items. The app does not yet
  provide a full equation-layout editor or direct LaTeX input.
- Handwritten mathematics recognition, worked steps, graphing, and error diagnosis are in personal
  beta. They require a vision-capable configured provider for image selections. Recognition and
  solution quality vary by handwriting, notation, crop, and model. Physical Pencil validation is
  still open.
- Local graphs use a limited explicit function grammar. They do not support implicit equations,
  parametric curves, inequalities, symbolic algebra, or arbitrary code.
- Evidence cards can be moved, resized, removed, and opened at their saved Source Version. Their
  quoted content is intentionally not editable on the canvas. Create a new Source annotation and
  Evidence record when the quoted content must change.

## Organization and removal

- Notes, Topics, Sources, Lists, goals, decks, cards, Concepts, and tests support lifecycle
  controls appropriate to each record.
- Institutions and academic terms do not yet have complete lifecycle controls.
- Archiving a List preserves its links and does not archive linked items.
- Archiving a deck does not archive its cards. Cards must be suspended or archived separately.
- There is no persistent cross-record Trash.
- Some undo actions remain available only while the current screen is open.

## Device validation

- Physical iPad Pencil, large-file, accessibility, rotation, multitasking, keyboard, and pointer
  testing is not complete.
- Two-device interruption and concurrent-version testing is not complete.
- Device revocation and recovery still require live-environment validation.

## Search

- Exact text search remains available for indexed notebook content.
- Related results depend on language support available on the iPad. Unsupported content falls
  back to exact matches without sending the query to an external service.
- Related matching is approximate. A related result can be useful without containing every query
  word. Confirm important claims against the opened note or Source.
- Related PDF results use the matched excerpt to find a supporting passage. A result can open at
  the first indexed page when an exact page cannot be recovered from that excerpt.

## Optional processing

- PDF extraction and AI features require a paired Mac.
- AI features require a separately configured provider account and can incur provider charges.
- One provider is active for newly approved work. Each new request keeps the provider and model
  reviewed at approval. Editing or removing that connection before processing stops the request;
  it must be reviewed and submitted again.
- The official Responses service, Anthropic, Gemini, and compatible local or hosted services are
  supported. Other native provider protocols still require a compatible gateway.
- Provider connections do not transfer to a fresh iPad. Enter the key again after recovery.
- A local provider can keep approved content off a hosted service, but quality, speed, context,
  vision, transcription, and reliable structured output depend on the selected model and server.
- Anthropic and Gemini native connections support text and optional vision only. Timestamped
  transcription requires the official Responses or a compatible connection.
- A live paid AI evaluation is not part of the current release evidence.
- Source guides and exact question citations currently apply to PDFs. Other Source types do not
  yet use this source-analysis screen.
- Scanned pages can require OCR. Vector-only diagrams and PDFs with incomplete image metadata can
  produce incomplete figure notes. The app shows reported coverage limits.
- Large PDFs use a bounded analysis pass. A result can cover selected passages instead of every
  passage and must state that limit.
- Manual cards, tests, and typed Concept connections are available. Generated card, test, Concept,
  and Concept-connection drafts can be edited or excluded before acceptance.
- Study Next supports pin, snooze, dismiss, irrelevant, open, and restore history.
- The local weekly review uses a rolling seven-day history and seven-day look-ahead. It does not
  yet provide custom date ranges, long-term charts, or a standalone weekly-review export.
- CSV, XLSX, DOCX, PPTX, EPUB, ODT, ODP, MP3, M4A, AAC, WAV, CAF, MP4, M4V, MOV, webpage,
  shared Google Docs, Slides, and Sheets, and YouTube reference Sources are available.
- Google capture supports native `docs.google.com` share links only when anyone with the link can
  view the file. Epistoria does not sign in to Google or access private files. It stores the
  Google-provided Office export, not comments, revision history, sharing settings, or the live
  editor layout.
- Web capture stores one bounded HTML response and extracted text. It does not run JavaScript,
  sign in to websites, retain cookies, crawl linked pages, or copy linked images, stylesheets,
  downloads, or embedded media. Pages that require those features may be incomplete.
- Local MP3, M4A, WAV, and MP4 Sources up to 25 MB can request a timestamped transcript through
  the trusted Mac and configured AI provider. AAC, CAF, M4V, MOV, larger files, word-level timing,
  speaker labels, automatic correction suggestions, waveform editing, playback speed, bookmarks,
  and background lock-screen controls are not supported in this stage.
- Video Sources support local playback. Transcript segments and timestamped Evidence can open the
  player at their saved start time. Playback history, automatic range looping, and a validated
  picture-in-picture policy are not available. Physical-device testing for large files,
  interruption, background locking, and cleanup remains open.
- YouTube Sources are online references. Epistoria does not download or cache YouTube video,
  audio, captions, thumbnails, or metadata. Playback requires YouTube and a network connection.
  YouTube references cannot be transcribed by the trusted Mac.
- Source comparison shows the exact local content in two independent panes. It does not yet add
  automatic text-difference highlighting, synchronized scrolling, or a saved comparison record.
  It never refreshes online material in the background.
- Packaged-document readers provide extracted text. They do not reproduce the original page,
  slide, font, chart, formula, animation, or interactive-book layout. Open the exported original
  in a compatible app when exact layout is required.
- Proactive AI is limited to Topic synthesis, flashcard drafts, Concept suggestions, reviewed
  source discovery, and weekly-review drafts. Tests and written-response feedback still require a
  manual reviewed request because they need an explicit blueprint or submitted response.
- The spending limit stops new automatic work when recorded provider estimates reach the cap. It
  is not a prepaid provider balance. Provider billing remains external.

## Product scope

- The current project supports one owner.
- Collaboration, public sharing, subscriptions, billing, and organization administration are not
  available.
