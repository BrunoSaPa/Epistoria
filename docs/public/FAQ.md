# Frequently asked questions

## Is Epistoria available to download?

No. Epistoria is in personal beta development and is not available for public download.

## Is this a commercial product?

No. The project started as a personal notebook for studying different subjects. There is no
current plan to sell it.

## Does the notebook work offline?

Yes. You can create and edit notes, use downloaded PDFs, organize material, and search local
content without a network connection.

Optional synchronization, first-time restored-file downloads, and AI requests require the
applicable service and connection. The optional Compute Node is needed only for work explicitly
routed to it.

## Can I save something from another iPad app?

Yes. Use **Save to Epistoria** in the iPad Share Sheet for a supported image, file, selected text,
or HTTPS link. The extension encrypts the item on the device and Epistoria imports it into
unassigned Source Inbox after the notebook unlocks. It does not require sync, AI, or a Compute
Node.

A shared link is stored as a reference and is not opened automatically. You can later choose
**Capture offline copy** from that Source. Share Sheet capture accepts up to 10 items at a time and
32 MB per item. Use Library import for larger files.

## Does related search use my AI provider?

No. Exact and related search run on the unlocked iPad. They do not create an AI request, use the
paired Mac, or incur provider charges. If related matching is unavailable for the current
language or device, exact text search still works.

## Is synchronization required?

No. Epistoria can operate as a local-only notebook. Private synchronization is optional.

## Can I keep more than one notebook on an iPad?

No. Epistoria intentionally uses one private notebook so subjects, sources, notes, sessions, and
learning history can remain connected. Use Areas, Topics, and Lists to organize it.

If the iPad already has a configured notebook, setup opens or recovers it instead of creating a
second notebook.

## What is the difference between a List and a session?

A List is a reusable cross-Topic group. For example, one List can contain material for an exam
from Algebra and Geometry.

A session is the record of one focused study period. It stores the intention, time, notes, and
Sources used together. Ending the session preserves that study history. The same note can appear
in a List and in multiple sessions without being copied.

## Where does a Quick Note go?

A Quick Note starts unassigned. It remains in **Notebook → Notes** and can be added to a
List or session later from **Notebook actions → Organize note…**.

## Can the synchronization service read my notes?

It is designed to store encrypted content and the operational information required to
synchronize it. It is not intended to receive readable notebook content.

The service can still observe information such as record type, timing, approximate size, and
relationship shape.

## Does Epistoria use AI automatically?

Not by default. AI features require a configured provider. Normal notebook use and Study Next do
not require AI.

You can create a separate recurring permission for selected Topics and supported tasks, with a
minimum interval, expiration, and spending limit. You can pause or revoke it. Automatic results
remain drafts until you review and accept them. Opening the app does not create permission.

## Can I use a local AI model?

Yes, when the model server provides the compatible connection supported by Epistoria. Add its
address and model in **Settings → AI Providers**. The address is reached directly from the iPad,
so use the private-network address of a model hosted on another computer. A loopback address
refers to the iPad. Local model quality and supported features vary. Confirm
text, vision, and transcription support before enabling them.

Epistoria also supports native Anthropic and Google Gemini connections for text and optional
image input. Their native connections do not currently provide Epistoria's timestamped media
transcription output.

## Can Epistoria create flashcards and practice tests?

Yes. The current beta creates durable manual cards and coverage-first tests. Topic Studio can
request cited card and test drafts. Generated output remains a draft until the user reviews it.

Accepted cards and tests will remain available for offline practice. Previous attempts will not be
rewritten when a card or question changes.

## Will cards and tests be saved?

Yes. Cards, revisions, reviews, test outlines, questions, attempts, responses, scores, and review
history are stored as protected notebook data. They do not exist only in an AI conversation.

When private synchronization is enabled, learning records are included with the rest of
the encrypted notebook. They will also be included in recovery and readable export work.

Starting a test will preserve the exact version used for that attempt. Editing or regenerating the
test later will not change the old result.

## Can I create a test for one subject inside a notebook?

Yes. Open the Topic, select **Create test**, list the supported objectives, and add questions. You
can also use Topic Studio to request a cited test draft for the current Topic.

The current interface supports Comprehensive, Quick Check, and Custom test plans and reports
uncovered objectives or provider-reported constraints.

If the notebook or requested duration cannot support full coverage, Epistoria will show what is
missing. It will not silently omit those topics or claim the test is comprehensive.

## Can I review an old test and see what I got wrong?

Yes. Test history preserves the frozen questions, responses, score, incorrect or skipped answers,
confidence, and timing. Use the All, Incorrect, Skipped, or Low Confidence filters.

Use **Retake full test** or **Retake missed objectives** from the test detail. A new attempt keeps a
link to the original result and never replaces it.

## How will Epistoria recommend what to study next?

The **Study Next** queue considers user goals, deadlines, due reviews, test and
flashcard results, confidence, unresolved questions, source coverage, and recent unfinished work.

Each recommendation states its reason. The base queue works on the iPad without a paid AI request.
You can pin it, snooze it for one day, dismiss it, or mark it as irrelevant.

## Can Epistoria plan daily work for an exam or deadline?

Yes. Add a target date to a goal and turn on **Plan daily work**. Choose the study days, preferred
daily minutes, and coverage objectives. Epistoria calculates remaining work, required minutes per
study day, catch-up, and an explained readiness state on the iPad.

This calculation does not use AI. Objective completion is controlled by you. Linked test results
can show incorrect and low-confidence evidence, but they cannot complete an objective
automatically.

## Does the Daily Evidence Review use AI?

No. Open **Learning → Overview → Daily Evidence Review**. Epistoria selects saved Evidence,
difficult Concepts connected to recorded card or test difficulty, and the latest unresolved test
mistakes from encrypted records on the iPad.

Remembered, Difficult, and Later responses set the next local review date. They do not alter the
original material. Supporting Evidence opens at its saved Source Version and location.

## Does the weekly review use AI?

No. Open **Learning → Overview** to calculate the review from durable sessions, card reviews, test
attempts, responses, goals, questions, and schedules stored on the iPad. It shows the previous
seven days, the next seven days, and up to three current Study Next actions.

The optional automated weekly-review draft is a separate AI task. It runs only under an active
recurring permission and remains a reviewable draft.

## Can I import a CSV spreadsheet?

Yes. Import a UTF-8 CSV from Today, Library, or a Topic. Epistoria validates it locally, encrypts
the unchanged original, and displays it as a scrollable table. Quoted fields and CRLF are
supported. XLSX files can also be imported and read as extracted local text.

## What information is sent for an AI question?

The approved request can include the selected note text, bounded images of selected handwriting
or image previews, the question, and additional note text for context. The app shows a disclosure
before it queues the request.

## Can AI change my original notes?

No. Generated results are stored separately. You can review, edit, accept, reject, or insert an
answer as new text. The original selected content remains unchanged.

## Does listening to a recording use AI or upload it?

No. Supported audio files are validated, encrypted, decrypted for local playback, and played on
the iPad. Playback does not create a provider request.

Transcription is separate and optional. For a supported local MP3, M4A, WAV, or MP4 Source up to
25 MB, Epistoria shows the provider, model, destination, and file size before the iPad decrypts
the media and sends its bytes directly to the configured provider. The timestamped result is
encrypted and bound to the current Source Version.

## Does watching an imported video upload it?

No. MP4, M4V, and MOV files are validated and encrypted before Source creation. Playback happens
on the iPad. Epistoria uses a protected, backup-excluded playback file because the system video
player requires a file URL, then removes it after use. Watching a video does not create an AI job.

## Can I add and transcribe a YouTube video?

You can add one YouTube video as a link. Epistoria loads YouTube's privacy-enhanced online player
only after you select **Load video**. It does not download or cache the video, captions,
thumbnail, or metadata.

A YouTube reference cannot be transcribed. Import a local media file that you own or are
permitted to process when a transcript is needed.

## Can I save a webpage for offline study?

Yes. In Library, select **Add Source → Capture webpage** and enter a complete HTTPS
address. Epistoria stores one encrypted HTML response and presents its readable text offline.
Refresh is manual and creates a new immutable version with a readable-text change summary.

Web capture does not sign in, retain cookies, run JavaScript, crawl links, or copy external page
assets. A page that depends on those features may not be complete.

## Can I add a Google Doc, Slides presentation, or Sheet?

Yes. Set the Google file so anyone with the link can view it. In Library, select **Add Source →
Google Docs, Slides, or Sheets** and paste the `docs.google.com` link.

Epistoria does not sign in to Google. It downloads a DOCX, PPTX, or XLSX export, validates it,
encrypts the exact downloaded file, and provides extracted text offline. Manual refresh creates a
new immutable version. Private files, comments, revision history, and the live Google editor layout
are not captured.

## What happens if two devices edit the same content?

Epistoria preserves the alternate version for review. You can keep the synchronized version or
preserve both as separate records.

## What do the 24 recovery words contain?

They reconstruct the account key. They do not contain a copy of your notes or files. Recovery of
synchronized history also requires access to the encrypted account data.

## Can I export my data?

Yes. The current beta can create a readable package with standard data files, original Sources,
local text copies for supported Source types, readable YouTube links, images, Pencil data, and
checksums. Accepted transcript data is included when derived AI records are selected.

Transcript corrections and timestamped Evidence are owner records. They are included in the
readable knowledge file. Generated transcript chunks remain in the derived AI file and are
included only when reviewed AI data is selected.

Version 5, 6, and 7 packages can be imported into an empty notebook. Epistoria validates the
package first, then encrypts its records and original files for the target notebook. Import does
not merge with or replace existing data. Versions 1 through 4 remain readable but must be
recreated with a version 5, 6, or 7 build before import.

## Can revoking a device erase it remotely?

No. Revocation prevents future requests from the device credentials. It cannot erase content or
exports already stored on that device.

## Should I store important information in the beta?

Do not use the beta as the only copy of important information. Keep the recovery information and
independent copies of important sources until the remaining device and recovery testing is
complete.
