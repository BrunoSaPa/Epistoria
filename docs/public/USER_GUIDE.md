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

Then choose Plain, Ruled, Grid, or Dotted paper.

Changing the format does not delete or resize content. Material outside a fixed page remains
available around the page.

## Write and arrange content

- Select **Pen** to write with Apple Pencil.
- Select **Text** to add typed text at the current view center.
- Select **Image** to add an image.
- Select **Select** to move, resize, rotate, or reorder text and images.
- Use the notebook actions to bring an item forward or send it backward.

Pencil writing stays separate from the text or image below it. Removing an item requires
confirmation and provides temporary undo while the note remains open.

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
