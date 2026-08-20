# User guide

This guide describes the product workflow in the current personal beta.

## Use one connected notebook

Epistoria keeps subjects, courses, sources, notes, and study history in one private notebook. Use
collections and courses to organize different areas of knowledge.

If the iPad already has a configured notebook, Epistoria opens or recovers that notebook instead
of creating another one. Save its account ID and 24 recovery words offline.

## Use Today

Today provides the main actions and recent work:

- **Quick note** creates and opens a note.
- **Start a session** starts a focused study session.
- **Continue session** returns to an active session.
- **Import PDF** adds one or more PDFs.
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

- **Notes** for active notes.
- **Collections** for flexible groups.
- **Archived** for notes that can be restored.

Archiving a note does not erase it. A note linked to a collection can remain visible in that
collection after archive.

University organizes study material by institution, academic term, and course. A course can link
notes, PDFs, and sessions. Archiving a course preserves its linked material.

## Read and annotate PDFs

- Use the page controls to navigate.
- Open the inspector for extraction and annotation details.
- Add or edit an annotation without changing the original PDF.
- Use temporary undo before leaving the PDF.

If a restored PDF is not yet on the iPad, the app needs a connection the first time you open it.
After a successful download, the encrypted local copy opens offline.

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

Open **Data Health → Review preserved versions**.

- **Keep synced version** retains the current synchronized version.
- **Preserve both** creates a separate copy from the other version.

Conflict resolution requires a connection. If resolution fails, the alternate version remains
available for later review.

## Review devices

Open **Data Health → Trusted devices** to review paired iPads and Macs. You can revoke a device
other than the current iPad.

Revocation blocks future synchronization requests from that device. It does not erase data that
the device already downloaded.

## Create a readable export

A readable export contains decrypted personal information. Save it only to a trusted encrypted
location.

1. Open **Data Health → Portable export**.
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
