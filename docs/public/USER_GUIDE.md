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
- **Add Source** imports PDFs, images, plain text, Markdown, or HTML.
- **Recent** opens recently used notes and resources.

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

Use the persistent tool rail:

- Select the page counter to jump to an existing page.
- Select **Add page** to append a blank page and scroll to it.
- Use Command-Shift-N with a keyboard to append a page.

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
- Select **Size** to choose a Pen or Marker stroke width.
- Select **Text** to add typed text at the current view center.
- Select **Image** to add an image.
- Select **Shape**, then tap the page to place the current shape. Tap the selected Shape tool
  again to choose rectangle, rounded rectangle, ellipse, triangle, diamond, line, or arrow and
  set its outline, fill, and line width. The preview updates before placement.
- Select **Symbol**, then tap the page to place the current math symbol. Tap the selected Symbol
  tool again to choose from algebra, calculus, Greek, set, logic, and comparison symbols. The
  selected symbol appears in the preview.
- Select **Select** to move, resize, rotate, or reorder text, images, shapes, and symbols.
- Use the notebook actions to bring an item forward or send it backward.
- Select **Undo** or **Redo** in the rail for current-page ink changes.

Pencil writing stays separate from the text or image below it. Removing an item requires
confirmation and provides temporary undo while the note remains open.

Shapes and symbols are stored as notebook items. Switch to **Select** to move, resize, rotate, or
remove them. Select a symbol again in Select mode to edit it as text.

## Export one note as a PDF

A note PDF is readable and contains decrypted personal information. Save it only to a trusted
location.

1. Open the note.
2. Open **Notebook actions**.
3. Select **Export note as PDF…**.
4. Read the warning and select **Create readable PDF**.
5. Select **Save or share PDF**.
6. Select **Done** after saving the destination copy.

Fixed-paper notes keep their A4 or US Letter page size and orientation. Each notebook sheet
becomes one PDF page. An infinite note becomes one custom-size PDF page that contains the used
area. The PDF includes paper appearance, typed text, math symbols, vector shapes, images, and
Pencil ink. It is for reading, printing, or sharing. It is not an Epistoria backup and cannot be
imported into the app.

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
estimate before approving a paid request.

When generated cards, questions, or Concepts return:

1. Review every item and its citation count.
2. Clear an item to exclude it, or select **Edit** to change its prompt, answer, rubric,
   objectives, or description.
3. Keep citations fixed during review. Exclude an item when its evidence does not support it.
4. Select **Accept selected**. Only selected items become cards, test questions, or Concepts.

The original generated response remains available for provenance. The reviewed selection is
encrypted and remains available after relaunch. Acceptance cannot be repeated to create duplicates.

## Use Study

Study contains Study Next, Sessions, Flashcards, Tests, and History.

- Study Next runs on the iPad and explains why an item is recommended.
- Flashcard reviews remain available offline. Each rating adds a history event and updates the
  versioned schedule.
- Tests start from an objective list. Enter manual questions as `question | correct answer`.
- Starting a test freezes the question, correct answer, rubric, and scope for that attempt.
- Responses autosave. Add a confidence level before moving to the next question.
- After submission, filter the review by All, Incorrect, Skipped, or Low Confidence.
- Use **Retake full test** or **Retake missed objectives** from the test detail. The new attempt
  keeps a link to the earlier result.
- Use **Override score** after submission to store a separate corrected score and required reason.

Only one session can have an active timer. Other sessions can remain Planned or Paused. Ending or
abandoning a session preserves its notes, Sources, and activity history. Removing an activity row
does not delete the underlying item.

## Read and annotate Sources

Library contains Inbox, All Sources, Recent, type filters, and Topic filters. Inbox contains
Sources that do not yet have a Topic.

Use **Archived** to review and restore archived Sources. Open a Source and select **Edit Source**
to change its title, primary Topic, related Topics, Lists, or archive state. These changes do not
rewrite Source Versions or existing citations.

- Use the page controls to navigate.
- Open the inspector for extraction and annotation details.
- Add or edit an annotation without changing the original PDF.
- A saved annotation also creates reusable Evidence linked to the current Source Version.
- Select **Refresh Source** to import a replacement file as a new immutable version. Existing
  citations, cards, tests, and attempts continue to use the earlier version.
- Use temporary undo before leaving the PDF.

If a restored PDF is not yet on the iPad, the app needs a connection the first time you open it.
After a successful download, the encrypted local copy opens offline.

## Manage learning records

Open **Study**, then select **Manage learning records** in the toolbar.

- Edit goals and set them to Active, Completed, or Archived.
- Edit unresolved questions, record a resolution, or reopen them.
- Create, rename, archive, and restore flashcard decks.
- Edit card content, type, and deck. Each content edit creates a new revision. Earlier reviews
  remain linked to the revision used during that review.
- Suspend a card to remove it from due reviews without deleting it. Archive it to remove it from
  active card lists.
- Edit and archive Concepts and tests. Test attempts remain available after a test is archived.

In Notebook, use **Archived Lists** to restore a List. Open a List and select **Edit List** to
rename it, move it under another List, or archive it. Linked notes and Sources are not deleted.

## Search

1. Open **Search**.
2. Choose All, Notes, Resources, or Sessions.
3. Enter the search text.
4. Open a result.

Search happens on the unlocked iPad. A precise result opens the matching note item or PDF page.

## Ask about part of a note

This optional feature requires a paired Mac and configured AI provider.

1. Open a note.
2. Select **Select region**.
3. Draw around the relevant text, handwriting, or images.
4. Select **Ask**.
5. Enter the question.
6. Select **Preview what leaves your Mac**.
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

The export contains standard data files, original PDFs and images, original Pencil data, and
checksums. The current app cannot import this export.

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
