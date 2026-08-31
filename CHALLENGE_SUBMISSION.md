# IBM AI Builders Challenge submission

Last reviewed: August 31, 2026

Epistoria is being prepared for the IBM AI Builders Challenge with IBM Bob. The selected route is
the Wildcard Challenge, **Build Intelligent Systems for the Future of Work**.

## Challenge fit

Epistoria supports individual knowledge work. It helps a person collect source material, write and
organize notes, retrieve prior work, decide what to study next, and assess understanding. The AI
features use notebook evidence and preserve citations. AI output remains separate from original
notes until the owner reviews it.

The app remains useful without AI. AI is a decision-support layer for planning and executing
learning rather than a requirement for basic notebook work.

## Repository requirements

| Official requirement | Epistoria evidence | Status |
|---|---|---|
| Use IBM Bob as a core project component | The root README describes Bob's role in requirements, planning, implementation, review, troubleshooting, tests, and documentation. | Documented |
| Public GitHub repository | [BrunoSaPa/Epistoria](https://github.com/BrunoSaPa/Epistoria) is public. The current secret scan passes. | Complete; final local changes are not pushed |
| Functioning prototype or proof of concept | The native iPad app builds. Automated Core and UI journeys exercise notebook creation, pages, search, export, Trash, and restoration. Physical-device and TestFlight gates remain listed in Known Limitations. | In progress |
| Clear English README | The root README includes the problem, solution, AI and technical approach, selected theme, challenge fit, and use of IBM Bob. | Complete |
| Required IBM SkillsBuild learning activity | Every team member must complete at least one required IBM Bob learning activity. IBM SkillsBuild currently lists “How IBM Bob and AI Tools Are Changing the Way Solutions Are Built.” | Owner action required |
| Event Platform project and team details | Enter the final project and eligible team-member details on the Event Platform. | Owner action required |
| Repository link | Add the public repository URL to the Event Platform submission. | Owner action required |
| Solution presentation video | Record and submit a demonstration of no more than three minutes. | Owner action required |

## Judging criteria

### Technical execution

- Native SwiftUI and PencilKit notebook.
- SQLCipher local database with local save and sync outbox in one transaction.
- Opaque encrypted synchronization.
- Source-grounded AI artifacts with exact citations and review boundaries.
- Direct provider routing from the iPad and optional Compute Node acceleration.
- Automated Core, application, UI, API, contract, export, and documentation checks.

### Innovation

Epistoria combines a normal spatial notebook with durable learning history. AI suggestions can use
accepted evidence, prior mistakes, confidence, tests, and flashcards without replacing source
material or original handwriting.

### Challenge fit

The product helps an individual plan, decide, and execute learning and research work. Study Next,
the Adaptive Tutor, cited search, and review history provide decision support based on the owner's
notebook.

### Implementation and feasibility

Basic writing, organization, search, and export run on the iPad. Hosted AI is optional. The Mac
Compute Node accelerates selected work but is not required. Current release gaps are stated in
[Known Limitations](docs/public/KNOWN_LIMITATIONS.md).

### Real-world impact

The project addresses a personal need: studying any subject without splitting notes, source
material, retrieval practice, and AI context across separate products. Local-first storage and
readable export reduce dependence on network access and service availability.

## Submission actions

Before submission, the owner must:

1. Confirm eligibility and registration under the official rules.
2. Confirm that the team did not submit a Wildcard project in July. The Wildcard route may be used
   only once across the July and August competitions.
3. Complete the required IBM SkillsBuild IBM Bob activity for every team member. The current
   catalog includes [How IBM Bob and AI Tools Are Changing the Way Solutions Are Built](https://skillsbuild.org/?lnk=hpii6de).
4. Confirm that the README's IBM Bob description matches the actual development work. Retain
   non-sensitive Bob session evidence that can support the claim that Bob was a core component.
5. Review, commit, and push the final submission changes. The repository is already public and the
   current secret scan passes.
6. Record a demonstration of no more than three minutes.
7. Add the team details, public repository URL, and video to the Event Platform.
8. Submit before 11:59 PM Eastern Time on August 31, 2026.

## Three-minute demonstration outline

Use one synthetic Topic and do not show recovery words, keys, private files, or personal notes.

| Time | Demonstration |
|---|---|
| 0:00–0:25 | State the problem: notes, source material, and AI study context are split across products. |
| 0:25–1:05 | Open Epistoria offline, create a note, write with Pencil, add a page, and open an imported Source. |
| 1:05–1:35 | Search typed and recognized content and return to the exact note or Source region. |
| 1:35–2:15 | Show one cited Tutor response or Study Next recommendation and explain that generated output requires review. |
| 2:15–2:40 | Show durable flashcard or test history and the evidence behind it. |
| 2:40–3:00 | Show provider and Compute Node controls, state that the Mac is optional, and close with the Wildcard challenge fit. |

Record a backup take. Verify the final file is no longer than three minutes and every on-screen
claim matches the submitted build.

Official references:

- [AI Builders Challenge with IBM Bob](https://aibuilderschallenge-bobhub.bemyapp.com/)
- [Official rules](https://res.cloudinary.com/ideation/image/upload/q_100,f_pdf,dpr_auto/id-ibm-skillsbuil-3eec69/pkqvg8j3q3a4teedy1kd.pdf)
