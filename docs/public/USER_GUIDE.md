# User guide

This guide describes the product workflow in the current personal beta.

## Use one connected notebook

Epistoria keeps Areas, Topics, Sources, notes, and study history in one private notebook. An Area
contains broad knowledge such as Mathematics. A Topic contains a subject such as Factorization.
Use Lists for optional groups that cross Topic boundaries.

If the iPad already has a configured notebook, Epistoria opens or recovers that notebook instead
of creating another one. Save its account ID and 24 recovery words offline.

## Use Today

Today provides the main actions and recent work:

- **Quick note** creates and opens an unassigned note. You can organize it later.
- **Start a session** asks for a Topic and starts a focused study session.
- **Continue session** returns to an active session.
- **Add Source** imports supported files, captures a webpage, or adds a shared Google file or
  YouTube reference.
- **Learn** opens the learning hub. Learning status appears on Today only when there is active or
  due work.
- **Recent** opens recently used notes and Sources.

The status row reports whether work is saved on the iPad, waiting to sync, syncing, synced, or in
conflict.

## Choose note paper

Open the page menu beside the note title. Choose one format:

- A4 portrait or landscape.
- US Letter portrait or landscape.
- Infinite canvas.

Then choose Plain, Ruled, Grid, Dotted, or Isometric paper. For patterned paper, choose Compact,
Standard, or Wide spacing. Choose White, Ivory, Fog, or Stone as the page color.

Changing the format does not delete or resize content. Material outside a fixed page remains
available around the page.

For A4 or US Letter notes, scroll vertically through the pages. The page closest to the center of
the screen becomes the current page for new content and notebook commands.

Select **Pages** in the persistent tool rail to open the page manager. It shows each stable page
with a thumbnail. From there, insert a page before or after the current page, append, duplicate,
drag to reorder, change the page template, or move a page to Trash. Selecting a thumbnail opens
that page. Use Command-Shift-N with a keyboard to append a page.

An empty page uses only a small metadata entry. Epistoria creates page content records when you
add text, an image, a shape, a symbol, or Pencil writing. Infinite canvases do not show
numbered-page controls.

## Write and arrange content

- Select **Pen** or **Marker** to write with Apple Pencil. Tap the selected tool again to change
  width and color. The preview updates as you change either setting.
- Select **Eraser** once to activate it. Tap the selected Eraser again to open its options. Use
  **Pixel eraser** to remove only the area under the adjustable circle. Use **Stroke eraser** to
  remove the complete Pencil stroke you touch. The preview shows the current round footprint or
  whole-stroke behavior.
- Select **Text** to add typed text at the current view center.
- Select **Image** to add an image from Photos or Files. Images can also be pasted or dropped onto
  the note.
- Select **Shape**, then tap the page to place the current shape. Tap the selected Shape tool
  again to choose rectangle, rounded rectangle, ellipse, triangle, diamond, line, or arrow and
  set its outline, fill, and line width. The preview updates before placement.
- Select **More → Symbol**, then tap the page to place the current math symbol. Tap the selected Symbol
  tool again to choose from algebra, calculus, Greek, set, logic, and comparison symbols. The
  selected symbol appears in the preview.
- Select **Select** to move, resize, rotate, or reorder text, images, shapes, and symbols.
- Use the notebook actions to bring an item forward or send it backward.
- Select **Undo** or **Redo** in the rail for current-page ink changes.
- Select **More** to reach Evidence, recognition review, Learn, Ask, Math, and Symbol. Optional
  tools can be pinned to the fixed rail in **Settings → Interface and Controls**.

Pencil writing stays separate from the text or image below it. Removing an item requires
confirmation and provides temporary undo while the note remains open.

Shapes and symbols are stored as notebook items. Switch to **Select** to move, resize, rotate, or
remove them. Select a symbol again in Select mode to edit it as text.

### Edit an image

1. Select **Select**, then select an image.
2. Open the selected-item menu and select **Edit image**.
3. Drag the crop frame or a corner. You can also choose Full, Square, 4:3, 16:9, or Inset.
4. Rotate left or right in 90-degree steps.
5. Choose no mask, a rounded mask, or an oval mask. Adjust the rounded corner size when needed.
6. Select **Done** to save the presentation settings, or **Cancel** to discard the draft.

Use **Replace from Photos** or **Replace from Files** to select another image. Replacement keeps
the canvas frame and mask, resets crop and rotation for the new file, and retains the first
encrypted image. Select **Restore First Image** to return to that file. Crop, mask, rotation, and
replacement do not rewrite the original image bytes.

## Adjust the workspace

Open **Settings → Interface and Controls** to reorder the core sidebar destinations, hide or pin
Learning, reorder notebook rail tools, and pin optional tools. These choices stay on this iPad.
Use the separate **Restore Defaults** action for the sidebar or the notebook rail when needed.

Open **Settings → Notebook Defaults** to choose the format, orientation, paper style, spacing, and
paper color for new notes. Existing notes do not change.

Pin a note from its Notebook row to keep it above unpinned recent notes.

## Use Trash

Deleting a note, page, Source, List, or canvas item moves it to encrypted Trash. Open
**Settings → Trash** to review item counts and storage estimates, restore an item, or empty
unprotected items permanently. Trash does not expire automatically.

Epistoria blocks permanent removal of a Source that still has Evidence and a List that still has
child Lists. Review those dependencies first. Empty Trash creates synchronized deletion records.
This action cannot be undone, so make an encrypted notebook export before permanently removing
important material.

## Find, export, and print a note

Select **More → Find in Note** to search typed text, equations, accepted recognition, and labeled
unreviewed recognition in the open note. Results are grouped by page. Selecting a result opens
and highlights its saved region.

A note PDF is readable and contains decrypted personal information. Save it only to a trusted
location.

1. Open the note.
2. Open **Notebook actions**.
3. Select **Export note as PDF…**.
4. Choose all pages, the current page, or a page range.
5. Keep each page's original size or choose A4 or US Letter and an orientation.
6. Select **Create PDF**.
7. Select **Save or share PDF**, or select **Print** for the standard iPad print controls.
8. Select **Done** after saving or printing.

Fixed-paper notes keep their A4 or US Letter page size and orientation. Each notebook sheet
becomes one PDF page. An infinite note becomes one custom-size PDF page that contains the used
area. The PDF includes paper appearance, typed text, math symbols, vector shapes, images, Pencil
ink, and a searchable text layer for accepted handwriting recognition. It is for reading,
printing, or sharing. It is not an Epistoria backup and cannot be imported into the app.

## Use local recognition

1. Open **Settings → Search and Recognition**.
2. Keep automatic notebook or Source recognition on as needed.
3. Add optional language tags such as `en-US` and `es-MX`, or leave the field empty to use device
   language detection.
4. To recognize formulas, open **Local Math OCR**. The on-device model can be installed only when
   the build contains a manifest that passed license, accuracy, performance, and device checks.
5. Write normally. Notebook recognition starts after drawing has been idle for three seconds. It
   also checks saved ink when a page closes or the app backgrounds.
6. Open the note or Source recognition status, then compare the original crop and result.
7. Edit, accept, reject, copy, or create an equation from the result.

Unreviewed recognition appears only in local search and is labeled by its source. Selecting a
match opens the saved page and region. Recognition does not replace Pencil strokes, images, or
Source files. A result without engine confidence is labeled **Unverified**.

## Work with handwritten mathematics

1. Open a note and select **Math** in the left tool rail.
2. Draw around the handwritten equation, calculation, graph, or attempted solution.
3. Select **Analyze**.
4. Choose **Recognize equation**. This uses the verified on-device model when it is available. It
   does not silently call an AI provider or require a Compute Node.
5. Open the OCR review and confirm or correct the expression.
6. Select the Math region again and choose **Worked steps**, **Graph**, or **Diagnose error**.
7. Add an optional instruction when the intended task or notation is unclear.
8. Select the processing preview. Check the route, selected items, nearby text items, visual
   crops, and approximate tokens.
9. Select **Approve and queue**. Continue writing while the approved route processes the request.
10. Open the notebook actions menu and select **Math results**.
11. Check the recognized expression, confidence, uncertainties, every worked step, and every
   correction. For a graph, confirm the function and domain.
12. Accept, edit, or reject the result. Only accepted or edited results can be inserted.
13. Select **Insert expression** or **Insert worked explanation** to create a new note object.

The selected Pencil strokes remain unchanged. Epistoria plots supported graph expressions on the
iPad and does not execute provider-supplied code. Recognition is not a proof of correctness.

## Organize notes

Notebook contains:

- **Notes** for active notes. Each row includes a page preview and the first available text or a
  content label for handwriting and images.
- **Lists** for reusable cross-Topic groups, such as Exam Material or Research Methods.
- **Archived** for notes that can be restored.

A session is different from a List. A session records the notes and Sources used during
one focused study period. It has a start time, an optional end time, goals, and optional digest.
A List has no timer and can group material from several Topics.

To organize an active note:

1. Open the note.
2. Open **Notebook actions**.
3. Select **Organize note…**.
4. Add the note to one or more Lists or sessions.

To add an existing note from a session, open the session and select **Add existing notes**. Links
do not duplicate the note. Edits appear everywhere that references it.

To remove one link, open the List or Session, swipe the note or touch and hold it, then select
**Remove from List** or **Remove from Session**. Confirm the action. The note stays in Notebook and
in every other List or Session. Removing a Session link does not remove the Session activity
history. Use the separate activity-row action when an activity entry was recorded by mistake.

Archiving a note does not erase it. A note linked to a List can remain visible in that List after
archive.

Topics organizes subjects under Areas. A Topic can contain notes, Sources, Concepts, sessions,
cards, and tests. Academic details are optional. Archiving a Topic preserves linked material.

## Use Topics

1. Open **Topics**.
2. Create an Area or open an existing Area.
3. Create a Topic and add optional academic details when they apply.
4. Open the Topic dashboard.
5. Continue a note or session, add a Source, create a Concept, create cards, create a test, or open
   Topic Studio.

Topic Studio uses the current Topic by default. Turn on **Include connected knowledge** only when
the request should also use Topics connected through the same Areas. Review the excerpt and token
estimate before approving a paid request. The final review also shows the active provider, model,
destination, and maximum estimate when price metadata is configured. The request goes directly
from the iPad to that provider. A Compute Node is not required for Topic Studio.

For a generated test:

1. Choose **Practice test** or **Test blueprint**.
2. Choose **Comprehensive**, **Quick Check**, or **Custom**.
3. Select **Detect objectives from Topic**.
4. Review the proposed objectives. Detection reads local Concept, Source, note, and unresolved
   question titles. It does not guarantee a complete curriculum.
5. Add or remove objectives. Comprehensive keeps every detected objective. Quick Check starts with
   three objectives. Custom allows an exact selection.
6. Set the question count and optional time limit. Custom also allows exact coverage dimensions.
7. Select **Review request**. Check the final mode, question count, objective count, dimensions,
   time limit, excerpts, and approximate token count.
8. Select **Approve and generate** only when the plan and provider disclosure are correct.

Epistoria saves a Topic Studio result only after the iPad validates the response format and every
citation. A malformed response or a citation outside the reviewed excerpts produces an error and
does not create a draft.

Comprehensive generation can use a broader or multi-part question for related objectives. The
accepted test still lists objectives without a reviewed question and keeps provider-reported
source, dimension, question-count, and time-limit constraints.

When generated cards, questions, Concepts, or Concept connections return:

1. Review every item and its citation count.
2. Clear an item to exclude it, or select **Edit** to change its prompt, answer, rubric,
   objectives, or description.
3. Keep citations fixed during review. Exclude an item when its evidence does not support it.
4. For Concept work, review each proposed typed connection and its cited reason. You can edit the
   Concept names, relationship, or reason. Citations remain fixed during review.
5. Select **Accept selected**. Only selected items and connections become durable records.

The original generated response remains available for provenance. The reviewed selection is
encrypted and remains available after relaunch. Acceptance cannot be repeated to create duplicates.

## Use the Concept and Evidence map

1. Open **Topics**, select a Topic, then select **Knowledge map**.
2. Select **Add connection** to connect two Concepts or connect Evidence to a Concept.
3. Choose a typed relationship. Concept-to-Evidence choices include supporting, contradicting,
   example, prerequisite, and application.
4. Drag a node to arrange the map. The position saves when the drag ends. Moving a node does not
   edit or duplicate its Concept or Evidence record.
5. Pan with one finger or pointer scrolling. Pinch to zoom, or use **Map options → Zoom in** and
   **Zoom out**.
6. Turn **Evidence** off to review only Concept relationships. Turn it on to restore the Evidence
   nodes.
7. Select a node to open the inspector. Select a connected item to move the inspector to that
   item.
8. For Evidence, review the displayed locator and select **Open exact Source** to open its frozen
   Source Version. PDF pages and media times open at the saved position.
9. Select **Add to note** to insert a reference to the same Evidence record in a Topic note. Select
   an existing note backlink to open that Evidence object in its note.
10. Select **Ask Tutor** to start a Topic-scoped Tutor with that Evidence prioritized for grounding.
11. Use a connection menu to remove only the relationship. The Concepts and Evidence remain.
12. Select **List** for a linear representation with the same nodes, relationships, and actions.
13. Use **Map options → Reset arrangement** to restore the deterministic layout without deleting
    knowledge records.

Map arrangement is encrypted and included in readable export. The map works offline and does not
require an AI provider. Tutor requests still use the Tutor approval and provider boundaries.

## Use Learning

Learning keeps optional study tools in one master-detail hub. Its sections are Overview,
Sessions, Review, Tutor, Knowledge, and History. Select **Learn** from Today, a Topic, or a note to
open the hub with the current Topic or note context. Learning can be pinned in the sidebar from
**Settings → Interface and Controls**.

### Plan a dated goal

1. Open **Learning → Knowledge → Learning records** and select a goal. You can also create a goal
   from a Topic.
2. Set a target date, then turn on **Plan daily work**.
3. Set the preferred minutes per study day and choose the days when study can occur.
4. Add each objective the goal must cover. If the Topic already has a test blueprint, select
   **Import test objectives** to reuse the most recent blueprint's objective list.
5. Set an estimated number of minutes for each objective. The estimate controls workload only. It
   is not a mastery score.
6. Mark an objective complete when you have reviewed the work and consider it covered.
7. Review the current state, remaining minutes, available study days, daily workload, and catch-up
   estimate at the top of the plan.
8. Open **Learning → Knowledge** or Today to see the same plan in local Study Next.

Submitted tests can add incorrect and low-confidence evidence to imported objectives. Epistoria
shows those counts separately and may recommend review. A test, Tutor, provider, session, or card
review never marks an objective complete automatically. Plans work offline and do not require a
Compute Node.

### Complete the Daily Evidence Review

1. Open **Learning → Overview → Daily Evidence Review**. Today also shows a direct action when an
   item is due.
2. Read the saved Evidence, Concept prompt, or earlier test question.
3. For a Concept or test mistake, select **Reveal saved answer** after recalling the material.
4. Select **Show exact Source** when supporting Evidence is available. Epistoria opens the frozen
   Source Version at the saved page, timestamp, or region.
5. Select **Remembered** when recall was comfortable, **Difficult** when the item needs an earlier
   return, or **Later** to defer it until the next day.
6. Continue until the current queue is empty.

The queue contains up to five items at a time and is rebuilt from encrypted notebook records.
Only the response is stored as a new record. Epistoria does not copy or modify the original
Evidence, Concept, test question, answer, or attempt. This review works offline and does not use a
provider or Compute Node.

### Use the Adaptive Tutor

1. Open **Learning → Tutor → Start or resume Tutor**, or select **Learn → Tutor** from a Topic or
   note.
2. Select a Topic. When you start from a Topic or assigned note, it is selected automatically.
3. Enter an objective or leave it empty to use the Topic name.
4. Set a time target.
5. Select the Source Versions the Tutor may use. A cited session cannot start without one. The
   selected versions must contain reviewed Evidence or an analyzed Source guide so the Tutor can
   cite exact material.
6. Leave **Include connected knowledge** off unless the request should use related Topics.
7. Review the maximum turns and spending limit. The approval expires after four hours.
8. Select **Start Learning Guide**, then select **Begin** for the first diagnostic.
9. Enter an answer and set confidence from 1 to 5. Select **Send**. The answer is saved locally
   before the iPad contacts the approved provider.
10. Use **Hint**, **Explain directly**, **Another example**, or **Why this next?** when needed.
11. Wait for the response in the open Tutor panel. You can cancel the request without removing the
    saved learner message. Each Source button opens the exact frozen Source Version and locator.
12. Review each proposed learning signal. Select **Accept** only when the assessment is accurate.
    A proposed or rejected signal does not affect the mastery explanation.
13. Pause, end, or abandon the session from its menu. The transcript remains available in
    **Previous sessions** and in notebook export.

The notebook Tutor appears over the right edge. It does not resize the page, block Pencil input on
the visible canvas, or add a blocking background. Close it from the same edge. Reduce Motion uses
a cross-fade instead of a slide.

If no provider or network connection is available, Epistoria still saves the session and messages
locally. Manual cards, tests, notes, and local Study Next continue to work.

- Study Next runs on the iPad and explains why an item is recommended.
- Select a Study Next row to open the recommended due card, paused session, unfinished attempt,
  test, goal, or unresolved question. If the target is no longer available, Epistoria opens its
  Topic.
- Use the recommendation menu to pin, snooze for one day, dismiss, or mark an item not relevant.
  Opening and menu actions are stored as response history.
- Review **Response history** below the current recommendation. Select **Restore** to append a new
  active response for a pinned, snoozed, dismissed, or irrelevant item. Earlier responses remain
  in history.
- Select **Week** to review the previous seven days. The summary uses completed sessions, card
  reviews, submitted tests, test responses, goals, unresolved questions, and current card due
  dates stored on this iPad.
- Use **Completed work** to compare activity by Topic. Use **Difficult material** to find Topics
  with Hard or Again card ratings, incorrect test answers, or low-confidence test answers.
- Use **Open questions** and **Next seven days** to open the exact question, goal, or Topic. Overdue
  goals and cards are labeled separately from later work.
- Use **Suggested next actions** to open up to three current Study Next items. Opening an action
  records the same append-only response as opening it from Study Next.
- The weekly review is calculated locally. It does not queue the optional AI weekly-review draft
  task or incur a provider charge.
- Flashcard reviews remain available offline. Each rating adds a history event and updates the
  versioned schedule.
- Tests start from an objective list. Enter manual questions as `question | correct answer`.
- A manual test can use Comprehensive, Quick Check, or Custom mode. Custom mode allows exact
  coverage dimensions. A test can have an optional time limit.
- Open a saved test to compare planned and available questions, review objective coverage, and
  read coverage notes before starting an attempt.
- Starting a test freezes the question, correct answer, rubric, and scope for that attempt.
- Responses autosave. Add a confidence level before moving to the next question.
- After submission, filter the review by All, Incorrect, Skipped, or Low Confidence.
- To request feedback for a written response, open that question and select **Request cited
  feedback**. Select **Review what leaves your Mac**. The disclosure lists the frozen question,
  grading guide, reference answer, submitted response, confidence, and linked readable Evidence.
  Select **Approve and queue** only after checking that scope.
- When feedback returns, select **Refresh**, edit the feedback, strengths, improvements, proposed
  score, or uncertainty, then accept or reject it. Citations cannot be replaced during review.
  Accepted feedback is stored with the response. The submitted answer and original calculated
  result do not change.
- Select **Question score** to store a separate owner score and required reason, or clear an
  existing owner override. The generated proposal remains in history.
- Use **Retake full test** or **Retake missed objectives** from the test detail. The new attempt
  keeps a link to the earlier result.
- Use **Override score** after submission to store a separate corrected score and required reason.

Only one session can have an active timer. Other sessions can remain Planned or Paused. Ending or
abandoning a session preserves its notes, Sources, and activity history. Removing an activity row
does not delete the underlying item.

## Capture from another app

Use the iPad Share Sheet to send supported content to Source Inbox.

1. Open an image, supported file, webpage link, or selected text in another app.
2. Open the Share Sheet.
3. Select **Save to Epistoria**. Use **More** to enable the action if it is not visible.
4. Wait for **Saved to Source Inbox**, then select **Done**.
5. Open Epistoria. Unlock the notebook if required.
6. Open **Library** and select **Inbox**.

The Share extension accepts up to 10 items at a time. Each item must be 32 MB or smaller. Use
**Import files** in Library for larger content.

The extension encrypts the capture before saving it in the device-local inbox. Epistoria validates
the content after the notebook opens. A successful import creates an unassigned Source. If an item
fails validation, Library shows **Retry** and **Discard** controls. Discarding a failed capture does
not remove existing Sources.

A shared HTTPS link is saved without opening the website. Open the Source and select **Capture
offline copy** when you want an encrypted snapshot. This action requires a network connection and
creates a new immutable Source Version.

## Read and annotate Sources

Library contains Inbox, All Sources, Recent, type filters, and Topic filters. Inbox contains
Sources that do not yet have a Topic.

Use **Add Source → Import files** in Library, or an import action from Today or a Topic, to select PDFs, images, plain text, Markdown,
HTML, CSV, XLSX, DOCX, PPTX, EPUB, ODT, ODP, MP3, M4A, AAC, WAV, CAF, MP4, M4V, or MOV files. CSV
files must use UTF-8 and can be up to 32 MB. Quoted commas, quoted line breaks, escaped quotes,
CRLF, and a UTF-8 byte-order mark are supported. Packaged documents are checked for valid
document identity, required parts, checksums, safe paths, and bounded expanded size. Invalid
input fails before Epistoria creates a partial Source.

Open a CSV Source to use the scrollable local table. The first row stays available as the table
header. Row numbers are display aids and do not change the file. Select **Refresh Source** to
choose another CSV. Refresh creates a new immutable Source Version and retains the old file for
existing citations.

Open an EPUB, word-processing document, presentation, or spreadsheet to read extracted text on
the iPad. This view does not reproduce the original layout. The encrypted original remains in the
readable notebook export and can be opened with a compatible app.

Open an audio Source to play it on the iPad. Use the center button to play or pause, drag the
position control to seek, or use the 15-second buttons. Playback uses the local decrypted copy.
Importing or listening does not send the recording to a provider.

Open a video Source to use the standard iPad playback controls. Epistoria decrypts the video into
an app-owned file protected by iOS complete file protection. The file is excluded from backup and
removed when you close the reader, lock the notebook, or reopen after an interrupted session.
Importing or watching does not send the video to a provider.

To transcribe a supported local recording or video:

1. Open an MP3, M4A, WAV, or MP4 Source no larger than 25 MB.
2. Open **Source details** and select **Transcribe…**.
3. Review the filename, size, optional language, provider, model, and destination.
4. Select **Approve and transcribe**. The iPad sends the media directly to that provider.
5. Open **Read timestamped transcript**. Compare it with the original media.
6. Select the play button on a segment to return to the local player at that timestamp.
7. Select the pencil button to correct a segment. Enter the corrected text and an optional reason,
   then select **Save**. The generated text remains visible and unchanged.
8. Select one segment. Select a second segment to extend the selection to a continuous range.
9. Select **Create timestamped Evidence**, review the frozen excerpt, add an optional note, and
    select **Create**.
10. Accept or reject the transcript if you did not already correct it.

The iPad decrypts the selected Source in memory for the approved request. The disclosed provider
receives the media bytes. Transcript segments are encrypted, searchable in the
transcript reader, and bound to the exact Source Version. Accepting a transcript allows it to
appear when derived AI records are included in a readable export. Rejecting it keeps it out of
that export. Neither action changes the original media.

A correction is a separate encrypted owner record. It does not replace the provider transcript
chunk. Saving another correction supersedes the active correction and keeps the earlier entry in
history. Select **Use generated text** to retract the active correction without deleting it.

If two devices save different corrections before synchronization, the transcript reader shows a
**Correction conflicts** section. Select **Keep this correction** for one candidate or **Use
generated text**. Epistoria keeps the other correction records in history. You cannot create
Evidence from the affected transcript until the conflict is resolved.

Timestamped Evidence requires an accepted or corrected transcript. The Evidence stores the
reviewed excerpt, exact Source Version, start and end time, selected segment indexes, and applied
correction IDs. Later correction changes do not alter an existing Evidence excerpt.

To capture a webpage:

1. Open Library and select **Add Source → Capture webpage**.
2. Enter a complete HTTPS address. Addresses with embedded usernames or passwords are
   rejected.
3. Choose a Topic or leave the Source in Inbox.
4. Select **Capture**.

Epistoria downloads one bounded HTML response without keeping cookies or a browsing session. It
stores the exact captured response as an encrypted original and shows extracted readable text.
Scripts and styles are excluded from the reader. Linked images, stylesheets, embedded media, and
content that requires JavaScript are not copied.

Select **Refresh webpage** to request a new snapshot. Refresh is never automatic. Epistoria adds
a new immutable version and shows counts and examples for added and removed readable paragraphs.
Use **Source details** to select and read an earlier version.

To add a Google file:

1. In Google Docs, Slides, or Sheets, set General access to **Anyone with the link** and Viewer.
2. In Epistoria, open Library and select **Add Source → Google Docs, Slides, or Sheets**.
3. Paste the complete `docs.google.com` share link.
4. Choose a Topic or leave the Source in Inbox.
5. Select **Add**.

Epistoria does not sign in to Google. It requests the file's DOCX, PPTX, or XLSX export through an
ephemeral connection without cookies or stored credentials. It validates the downloaded package
before creating the Source. The downloaded bytes become the encrypted original. The local reader
shows extracted text and does not reproduce the original Google layout.

Select **Refresh Google file** to request a new export. Refresh is never automatic. It creates a
new immutable version and shows readable-text changes. Open **Source details** to read an earlier
version. Changing or removing Google sharing access can prevent later refresh without changing
versions already stored in Epistoria.

To add a YouTube video:

1. In Library, select **Add Source → YouTube video**.
2. Paste one complete YouTube video link. Optional start times are supported.
3. Add an optional title and Topic.
4. Select **Add**.
5. Open the Source and select **Load video** when you want to connect to YouTube.

Epistoria stores a normalized link and does not download the YouTube video, captions, thumbnail,
or metadata. Playback uses YouTube's privacy-enhanced online player in a nonpersistent web view.
It requires a network connection and follows YouTube's terms and privacy controls. Select
**Unload video** to stop the player and clear that web view. YouTube references are not eligible
for trusted-Mac transcription. Import a local media file that you own or are permitted to process
when a transcript is needed.

Use **Archived** to review and restore archived Sources. Open a Source and select **Edit Source**
to change its title, primary Topic, related Topics, Lists, or archive state. These changes do not
rewrite Source Versions or existing citations.

To compare Sources:

1. Open a Source and select **Compare Sources**.
2. Choose the Source for each side from the two menus in the toolbar.
3. Choose an immutable version inside each pane. If the starting Source has an earlier version,
   Epistoria selects the current and previous versions first.
4. Read, scroll, change PDF pages, or use local media controls independently on each side.
5. Select **Done** to return to the Source.

Comparison decrypts available files on this iPad. It does not refresh a Source or load a YouTube
player. A version that is not stored on this device remains unavailable until its encrypted asset
has been restored through the normal Source workflow.

To create a PDF Source guide:

1. Open a PDF Source and show its inspector.
2. Select **Analyze this Source…**.
3. Enter the output language. Leave rendered page input on, or turn it off for a text-only provider
   or lower input cost. Review the page count, reference count, provider, model, destination, and
   maximum estimated cost.
4. Select **Approve and analyze**.
5. Read the summary, translation, key topics, image notes, and coverage limits under
   **Source guide**.
6. Select a numbered citation to open and highlight the supporting PDF region.

To ask about one PDF, select **Ask this Source…**, enter the question and output language, review
the same disclosure, and select **Approve and ask**. The saved answer appears under **Source
answers**. Each answer statement has its own citation. The answer remains bound to the Source
Version used for that request. Refreshing the Source does not rewrite an earlier answer.

Source analysis sends bounded PDF text and up to eight approved rendered pages to the provider
shown in the approval. The iPad calls that provider directly. The provider and model stay attached
to the saved result. Analysis does not run when the approval sheet is cancelled. A provider profile
must support image input
when detected figures are included. Large, scanned, or unusually structured PDFs can show
coverage limits.

- Use the page controls to navigate.
- Open the inspector for extraction and annotation details.
- Add or edit an annotation without changing the original PDF.
- A saved annotation also creates reusable Evidence linked to the current Source Version.
- To reuse the excerpt in a note, open the note and select **Evidence** in the tool rail. Drag an
  Evidence item to a page or select **Insert**. The inserted card cannot be edited as ordinary
  text. Moving, resizing, or removing the card does not change the original Evidence.
- Select an Evidence card, then open **Notebook actions** and select **Open Evidence source** to
  return to the saved Source Version, page, and excerpt.
- In the Evidence shelf, select **Backlinks** to list notes, Concepts, flashcards, and test
  questions that use the same Evidence record.
- Select **Refresh Source**, **Refresh webpage**, or **Refresh Google file** to create a new
  immutable version. Existing citations, cards, tests, and attempts continue to use the earlier
  version.
- Use temporary undo before leaving the PDF.

If a restored PDF is not yet on the iPad, the app needs a connection the first time you open it.
After a successful download, the encrypted local copy opens offline.

## Manage learning records

Open **Learning → Knowledge**, then select **Manage learning records**.

- Edit goals and set them to Active, Completed, or Archived.
- Edit unresolved questions, record a resolution, or reopen them.
- Create, rename, archive, and restore flashcard decks.
- Edit card content, type, and deck. Each content edit creates a new revision. Earlier reviews
  remain linked to the revision used during that review.
- Suspend a card to remove it from due reviews without deleting it. Archive it to remove it from
  active card lists.
- Edit and archive Concepts and tests. Test attempts remain available after a test is archived.
- Open a Concept to review incoming and outgoing connections. Select **Add connection**, choose the
  other Concept and relationship, explain the connection, and optionally select supporting
  Evidence. Open an existing connection to change its relationship, explanation, or Evidence.
  Removing a connection does not remove either Concept or the Evidence.

In Notebook, use **Archived Lists** to restore a List. Open a List and select **Edit List** to
rename it, move it under another List, or archive it. Linked notes and Sources are not deleted.

## Manage proactive automation

Study Next suggestions run locally and do not need AI. Recurring provider work is off until you
create a separate permission.

1. Open **Learning → Knowledge → Manage learning records → Proactive automation**.
2. Select **New permission**.
3. Select the exact Topics and tasks that may run automatically.
4. Set the minimum interval for each Topic/task pair, expiration, and USD spending limit.
5. Read the recurring-processing statement and enable the approval toggle.
6. Select **Save**.

Epistoria checks active permissions after local changes, during normal periodic synchronization,
and when **Run due automations** is selected. An unchanged input is not regenerated. A queued
result returns to Topic Studio as a cited draft and is never accepted automatically.

Open a permission to view its state, recorded cost estimate, queue count, and last queue time for
each Topic/task pair. Use **Pause** to stop new work temporarily. Use **Resume** after reviewing
the scope again. Use **Revoke permission** to stop it permanently. Pausing or revoking records the
local state immediately and requests cancellation for nonterminal server jobs when reachable.
Already completed drafts remain available for review.

## Choose an AI provider

1. Open **Settings → AI Providers**.
2. Select **Add provider**.
3. Choose the official Responses service, Anthropic, Google Gemini, or a compatible local or
   hosted service.
4. Enter the exact model name. Enter a service address only for a compatible service.
5. Enable only the capabilities supported by that service.
6. Enter the provider key. A local service that does not require a key can leave it empty.
7. Review the destination statement and select **Save**.
8. Confirm that the provider shows **Ready**.

Only one provider is active. Swipe a ready inactive provider and select **Use** to activate it.
Open a provider to update its model, capabilities, price estimates, or key. Swipe from the other
side to remove it.

Every new AI approval keeps the active provider connection and model shown at that time. Later
activation of another provider does not change queued work. If you edit or remove the approved
connection before the approved route processes a request, that request stops. Open the task again and review
the new provider settings before submitting it.

Changing the provider connection type clears the previous key unless a replacement is entered.
This prevents a key for one service from being sent to another service.

Anthropic and Gemini use fixed official HTTPS addresses. Their native connections support text
and optional image input. They require structured output and cannot be selected for timestamped
media transcription. The chosen model must support the capabilities that you enable.

Direct provider addresses are reached from the iPad. A loopback address refers to the iPad.
Remote addresses require HTTPS. A separately selected Compute Node route uses that node's
network. Provider keys stay in device-only Keychain storage, do not synchronize, and do not
appear in readable notebook exports. A fresh iPad requires the key to be entered again.

## Search

1. Open **Search**.
2. Choose All, Notes, Sources, or Sessions.
3. Enter the search text.
4. Open a result.

**Exact matches** lists direct text matches first. **Related** lists material with similar meaning
when the wording differs. Both searches happen on the unlocked iPad. They do not use the paired
Mac or configured AI provider.

A precise result opens the matching note item or PDF page. A related result opens the record and
uses its matched excerpt to locate a supporting passage when one is available. Some languages or
devices may show exact matches only.

## Ask about part of a note

This optional feature requires a configured provider or an explicitly selected Compute Node
route.

1. Open a note.
2. Select **Select region**.
3. Draw around the relevant text, handwriting, or images.
4. Select **Ask**.
5. Enter the question.
6. Select the processing preview.
7. Review the disclosure.
8. Select **Approve and queue**.

When the answer is ready, open the note's answer list. You can accept, edit, reject, or insert the
answer as new note text. The operation does not replace the selected content.

## Review conflicts

Open **Settings → Data Health → Review preserved versions**.

- **Keep synced version** retains the current synchronized version.
- **Preserve both** creates a separate copy from the other version.

Conflict resolution requires a connection. If resolution fails, the alternate version remains
available for later review.

## Review devices

Open **Settings → Data Health → Trusted devices** to review paired iPads and Macs. You can revoke a device
other than the current iPad.

Revocation blocks future synchronization requests from that device. It does not erase data that
the device already downloaded.

## Create a readable export

A readable export contains decrypted personal information. Save it only to a trusted encrypted
location.

1. Open **Settings → Data Health → Portable export**.
2. Choose whether to include accepted or edited AI results.
3. Select **Create portable export**.
4. Read and confirm the warning.
5. Wait for validation to complete.
6. Select **Save or share export**.
7. Select **Done** after saving the destination copy.

The export contains standard data files, original Sources and images, local readable text copies
for supported Source types, readable YouTube reference files, original Pencil data, and
checksums. Accepted transcript data is included only when derived AI records are selected.
Transcript corrections and timestamped Evidence are included as owner records in the knowledge
file.

## Import a readable export

Import requires an empty notebook and a version 8 export. It does not merge with or
replace existing data.

1. Open **Settings → Data Health → Portable export**.
2. Select **Import into empty notebook**.
3. Choose the ZIP or unpacked `epistoria-export` directory.
4. Review the export date, source account suffix, package size, and content counts.
5. Select **Import into this notebook**.
6. Wait for the completion screen before closing Epistoria.
7. Open representative notes, Sources, original files, cards, tests, and conflict records.

Epistoria validates the package before it changes the notebook. It preserves stable record IDs
and re-encrypts every original file for the target notebook. Keep the source export until you have
checked the imported copy. Versions 1 through 4 can be read and validated but cannot be imported.

## Restore on another iPad

Use a spare device for the first recovery test. Do not erase the primary iPad.

1. Install the same compatible Epistoria build.
2. Select **Restore with 24 words**.
3. Enter the account ID and recovery words.
4. Connect to the same private sync service, if configured.
5. Wait for synchronization to finish.
6. Open known notes, images, PDFs, annotations, and sessions.
7. Reopen downloaded files in Airplane Mode.

The recovery words reconstruct access to encrypted data. They do not contain a copy of the notes
or files.

If the iPad already has a different configured account, recovery stops without replacing it.
