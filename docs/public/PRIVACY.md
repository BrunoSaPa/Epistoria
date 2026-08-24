# Privacy

Epistoria is designed to keep normal notebook work on trusted devices and make optional data
disclosures explicit.

## Data on the iPad

The iPad stores notes, handwriting, images, PDFs, annotations, sessions, organization data, and
search information in protected local storage. You can create, edit, read, and search downloaded
material without a network connection.

The account key is protected separately by the iPad. The app asks for user presence when it opens
the private notebook.

## Optional private synchronization

Private synchronization sends encrypted content to a configured service. The service handles the
information required to identify devices, order changes, store encrypted files, and detect
concurrent versions.

The service is not intended to receive readable note titles, note text, annotations, filenames,
PDF text, questions, or generated answers.

Synchronization can reveal operational information such as approximate sizes, timing, record
types, and relationship shape. Encryption does not hide all traffic information.

## Optional trusted Mac processing

A paired Mac is used for PDF text extraction and optional AI features. The Mac can read the
material needed for an approved task while it is processing that task.

PDF extraction runs locally on the Mac and does not require an AI provider.

## Optional AI processing

AI features are disabled when no provider key is configured. Before a note question is queued,
the app shows a summary of the selected sources, additional context, visual input, and approximate
size.

An approved AI request sends selected readable material to the configured provider for
processing. This is a separate privacy boundary from encrypted synchronization. Provider data
handling and retention policies can apply.

PDF Source analysis requires separate approval. The paired Mac decrypts the selected Source
Version in memory, selects bounded text passages, and can render bounded figure images. The
configured provider receives those selected passages and images. The returned summary,
translation, answer, and citations are encrypted before synchronization. The original PDF does
not change.

Provider keys are stored separately in secure storage on the iPad and paired Mac. Saving a
provider connection sends the key to the trusted Mac through the same private encrypted channel.
The synchronization service is not intended to receive a readable key, destination, or model.
Provider keys and connections are not included in readable notebook exports.

When you approve an AI request, Epistoria records the selected provider connection, destination,
model, and declared capabilities inside the encrypted request. Changing the active provider does
not redirect already approved work. The trusted Mac stops the request if the approved connection
was edited or removed. The recorded route does not contain the provider key.

The official Responses, Anthropic, and Gemini connections use fixed official HTTPS destinations.
A custom destination is available only for a compatible connection. Epistoria does not include a
provider error response body in its saved error message or logs. The selected provider can still
retain or review submitted content under its own account settings and policies.

A local provider can avoid sending approved content to a hosted provider. The local service still
receives readable approved content. Its software, host computer, and local network must be
trusted.

Generated results remain separate from original notebook content until you choose to insert or
otherwise use them.

## Recovery information

The account ID and 24 recovery words can restore access to encrypted data. They do not contain a
copy of the notebook. Keep them offline and do not share them.

Anyone with the required recovery information and access to the encrypted account data can read a
recovered copy.

## Readable exports

A readable export is decrypted. After you save or share it, its protection depends on the chosen
destination. Store exports on an encrypted device or another trusted location. Do not attach them
to issues, support requests, public messages, or test reports.

The app can import a version 5 export into an empty notebook. Import copies the readable package
into protected temporary storage, validates it, and re-encrypts original files for the target
notebook. Delete the readable package from temporary and shared locations after verification.

## Device revocation

Revoking a device prevents future requests from its existing credentials. It does not remotely
erase notes, cached files, recovery information, or exports already stored on that device.

## Beta status

The product remains in personal beta. Physical-device, multi-device, and full recovery testing is
still in progress. Keep independent copies of important original material.
